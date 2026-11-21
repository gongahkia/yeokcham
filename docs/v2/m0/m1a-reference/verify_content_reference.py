#!/usr/bin/env python3
"""Independent fixture verifier B; never imports emitter A or product modules.

Reads only the explicitly supplied external emission and frozen manifest. This
limited reference checker is not a production parser/store or public admission API.
"""
import argparse
from collections import deque
import hashlib
import json
from pathlib import Path


class Refusal(Exception):
    def __init__(self, code):
        self.code = code


def need(condition, code):
    if not condition:
        raise Refusal(code)


class Reader:
    def __init__(self, raw):
        self.raw = memoryview(raw)
        self.at = 0
        self.remaining = 131200

    def take(self, n):
        need(0 <= n <= len(self.raw)-self.at, 'InvalidEncoding')
        data = self.raw[self.at:self.at+n]
        self.at += n
        return data

    def value(self, depth=0):
        need(self.remaining > 0, 'ResourceLimit')
        self.remaining -= 1
        tag = int.from_bytes(self.take(1), 'big')
        major, info = divmod(tag, 32)
        if major == 7:
            need(info in (20, 21, 22), 'InvalidEncoding')
            return {20: False, 21: True, 22: None}[info]
        need(major <= 5, 'InvalidEncoding')
        if info < 24:
            size = info
        else:
            need(info in (24, 25, 26, 27), 'InvalidEncoding')
            width = 1 << (info-24)
            size = int.from_bytes(self.take(width), 'big')
            need(size >= {1: 24, 2: 256, 4: 65536, 8: 1 << 32}[width], 'InvalidEncoding')
        if major < 2:
            need(size < 1 << 63, 'InvalidEncoding')
            return size if major == 0 else -1-size
        if major in (2, 3):
            data = bytes(self.take(size))
            if major == 2:
                return data
            try:
                return data.decode('utf-8', errors='strict')
            except UnicodeDecodeError:
                raise Refusal('InvalidEncoding') from None
        need(depth < 64, 'ResourceLimit')
        count = size * (2 if major == 5 else 1)
        need(count <= len(self.raw)-self.at, 'InvalidEncoding')
        need(count <= self.remaining, 'ResourceLimit')
        if major == 4:
            return [self.value(depth+1) for _ in range(size)]
        output = {}
        previous = -1
        for _ in range(size):
            key = self.value(depth+1)
            need(type(key) is int and key >= 0 and key > previous, 'InvalidEncoding')
            previous = key
            output[key] = self.value(depth+1)
        return output


def parse(raw):
    r = Reader(raw)
    value = r.value()
    need(r.at == len(raw), 'InvalidEncoding')
    return value


def serialize(value):
    """Independent stack emitter for decoded values, used to check exact bytes."""
    stack = [value]
    pieces = []
    while stack:
        item = stack.pop()
        if isinstance(item, tuple) and item[0] == 'raw':
            pieces.append(item[1]);continue
        if item is None or type(item) is bool:
            pieces.append(b'\xf6' if item is None else b'\xf5' if item else b'\xf4');continue
        if type(item) is int:
            major, n = (0, item) if item >= 0 else (1, ~item)
        elif type(item) in (bytes, str):
            raw = item if type(item) is bytes else item.encode('utf-8')
            major, n = (2 if type(item) is bytes else 3), len(raw)
            stack.append(('raw', raw))
        elif type(item) is list:
            major, n = 4, len(item)
            stack.extend(reversed(item))
        elif type(item) is dict:
            major, n = 5, len(item)
            flat = [v for k in sorted(item) for v in (k, item[k])]
            stack.extend(reversed(flat))
        else:
            raise TypeError(type(item))
        if n < 24:
            pieces.append(bytes([(major << 5) | n]));continue
        width = next(w for w in (1, 2, 4, 8) if n < (1 << (w*8)))
        pieces.append(bytes([(major << 5) | {1: 24, 2: 25, 4: 26, 8: 27}[width]]) + n.to_bytes(width, 'big'))
    return b''.join(pieces)


def unpack(raw, expected_id=None):
    need(len(raw) <= 128*1024*1024, 'ResourceLimit')
    need(len(raw) >= 57 and raw[:4] == b'YEOK', 'InvalidEncoding')
    need(raw[4] == 1 and raw[16] == 1, 'UnsupportedFormat')
    length = int.from_bytes(raw[17:25], 'big')
    need(length < 1 << 63, 'InvalidEncoding')
    need(length <= 128*1024*1024-57, 'ResourceLimit')
    need(length < 1 << 63 and length == len(raw)-57, 'InvalidEncoding')
    need(hashlib.sha256(raw[:25]+raw[57:]).digest() == raw[25:57], 'IntegrityFailure')
    need(raw[5] in (1, 2, 3, 13, 14) and raw[6:8] == b'\0\1' and raw[8:16] == bytes(8), 'UnsupportedFormat')
    if expected_id is not None:
        need(hashlib.sha256(b'yeokcham:object:v1\0'+raw).hexdigest() == expected_id, 'IntegrityFailure')
    return raw[5], raw[57:]


def source_bytes(recipe):
    kind = recipe[0]
    if kind == 'hex':
        return bytes.fromhex(recipe[1])
    if kind == 'repeat':
        return bytes([recipe[1]]) * recipe[2]
    if kind == 'P':
        # Quotient/remainder form instead of emitter A's index expression.
        q, r = divmod(recipe[1], 256)
        blocks = [bytes((17*j+k) & 255 for j in range(256)) for k in range(q)]
        blocks.append(bytes((17*j+q) & 255 for j in range(r)))
        return b''.join(blocks)
    if kind == 'noise':
        out = bytearray()
        counter = 0
        while len(out) < recipe[1]:
            out.extend(hashlib.sha256(b'yeokcham-reference-noise-v1'+counter.to_bytes(8, 'big')).digest())
            counter += 1
        return bytes(out[:recipe[1]])
    raise ValueError(recipe)


def table():
    entries = []
    number = 7640891576956012809  # decimal representation of the specified seed
    for _ in range(256):
        number = (6364136223846793005*number + 1442695040888963407) % (2**64)
        entries.append(number)
    return entries


T = table()


def boundaries(data):
    """Prefix recurrence: window hash at n>=64 is prefix[n] XOR prefix[n-64].

    The window is exactly 64, so rotating an outgoing prefix by 64 is identity.
    No emitter ring buffer, cut function or chunker import is used.
    """
    prefixes = deque([0])
    prefix = 0
    last_cut = 0
    ends = []
    for position, b in enumerate(data, 1):
        prefix = ((prefix * 2) % (2**64) + (prefix >> 63)) ^ T[b]
        window = prefix ^ prefixes[0] if position >= 64 else prefix
        prefixes.append(prefix)
        if len(prefixes) > 64:
            prefixes.popleft()
        current = position-last_cut
        if current == 131072 or (current >= 16384 and window % 65536 == 0):
            ends.append(position);last_cut = position
    if last_cut != len(data):
        ends.append(len(data))
    return ends


def exact_fields(value, count):
    need(type(value) is list and len(value) == count, 'InvalidContent')


def integer(value):
    need(type(value) is int, 'InvalidContent')
    return value


class CorpusReader:
    def __init__(self, directory, resolver=None, root=None):
        self.directory = directory
        self.resolver = resolver
        self.first = None
        if resolver:
            _, payload = unpack((directory/f'{root}.bin').read_bytes(), root)
            self.first = parse(payload)[8][0][0].hex()

    def get(self, identity):
        need(type(identity) is str and len(identity) == 64, 'InvalidContent')
        if self.resolver == 'omit-first' and identity == self.first:
            raise Refusal('Unavailable')
        path = self.directory/f'{identity}.bin'
        need(path.is_file(), 'Unavailable')
        raw = path.read_bytes()
        if self.resolver == 'corrupt-first' and identity == self.first:
            raw = raw[:-1]+bytes([raw[-1] ^ 1])
        kind, payload = unpack(raw, identity)
        value = parse(payload)
        need(serialize(value) == payload, 'InvalidEncoding')
        return kind, value

    def content(self, identity, inspect=False):
        kind, value = self.get(identity)
        need(kind in (1, 14), 'InvalidContent')
        if kind == 1:
            exact_fields(value, 2)
            version, data = value
            need(type(version) is int, 'InvalidContent')
            need(version == 1, 'UnsupportedFormat')
            need(type(data) is bytes, 'InvalidContent')
            if len(data) > 65536:
                if not inspect:
                    raise Refusal('NoncanonicalRepresentation')
                return data, 'LegacyReadableNoncanonical'
            return data, 'Canonical'
        exact_fields(value, 9)
        version, total, algorithm, window, minimum, average, maximum, full, refs = value
        need(type(version) is int and all(type(x) is int for x in (total, algorithm, window, minimum, average, maximum)), 'InvalidContent')
        need(version == 1, 'UnsupportedFormat')
        need((algorithm, window, minimum, average, maximum) == (1, 64, 16384, 65536, 131072), 'UnsupportedFormat')
        need(total > 0 and total <= (1 << 62)-1 and type(refs) is list and len(refs) > 0, 'InvalidContent')
        need(total > 65536, 'NoncanonicalRepresentation')
        need(type(full) is bytes and len(full) == 32, 'InvalidContent')
        lengths = []
        chunks = []
        for ref in refs:
            exact_fields(ref, 2)
            identity, n = ref
            need(type(identity) is bytes and len(identity) == 32 and type(n) is int and 0 < n <= (1 << 62)-1, 'InvalidContent')
            lengths.append(n)
        need(sum(lengths) == total, 'InvalidContent')
        for (identity, n) in refs:
            kind, chunk = self.get(identity.hex())
            need(kind == 13, 'InvalidContent')
            exact_fields(chunk, 2)
            need(type(chunk[0]) is int and type(chunk[1]) is bytes, 'InvalidContent')
            need(chunk[0] == 1, 'UnsupportedFormat')
            need(len(chunk[1]) == n, 'IntegrityFailure')
            chunks.append(chunk[1])
        data = b''.join(chunks)  # corpus <=1,048,589 bytes, not a streaming product API
        positions = []
        running = 0
        for n in lengths:
            running += n;positions.append(running)
        need(positions == boundaries(data), 'NoncanonicalRepresentation')
        need(hashlib.sha256(b'yeokcham:content:v1\0'+data).digest() == full, 'IntegrityFailure')
        return data, 'Canonical'

    def tree(self, identity, ancestors=()):
        need(identity not in ancestors, 'InvalidContent')
        kind, value = self.get(identity)
        need(kind == 2, 'InvalidContent');exact_fields(value, 2)
        need(type(value[0]) is int, 'InvalidContent');need(value[0] == 1, 'UnsupportedFormat')
        need(type(value[1]) is list, 'InvalidContent')
        result = {};previous = None
        for entry in value[1]:
            need(type(entry) is list and len(entry) in (3, 4), 'InvalidContent')
            tag, name = entry[:2]
            need(type(tag) is int and tag in (0, 1) and len(entry) == (4 if tag == 0 else 3), 'InvalidContent')
            need(type(name) is bytes and name not in (b'', b'.', b'..') and b'/' not in name and b'\0' not in name, 'InvalidContent')
            need(previous is None or previous < name, 'InvalidContent');previous = name
            reference = entry[-1]
            need(type(reference) is bytes and len(reference) == 32, 'InvalidContent')
            if tag == 0:
                mode = entry[2]
                need(type(mode) is int and mode in (0, 1, 2), 'InvalidContent')
                data, _ = self.content(reference.hex())
                result[(name,)] = ('file', mode, data)
            else:
                result[(name,)] = ('directory',)
                result.update({(name,)+p: v for p, v in self.tree(reference.hex(), ancestors+(identity,)).items()})
        return result

    def snapshot(self, identity):
        kind, value = self.get(identity)
        need(kind == 3, 'InvalidContent');exact_fields(value, 2)
        need(type(value[0]) is int, 'InvalidContent');need(value[0] == 1, 'UnsupportedFormat')
        need(type(value[1]) is bytes and len(value[1]) == 32, 'InvalidContent')
        return self.tree(value[1].hex())


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--emission', required=True, type=Path)
    p.add_argument('--manifest', required=True, type=Path)
    args = p.parse_args()
    manifest = json.loads(args.manifest.read_text())
    need(manifest['format'] == 'yeokcham-m1a-content-reference-1', 'UnsupportedFormat')
    local = json.loads((args.emission/'corpus.json').read_text())
    assert local == manifest, 'emitted output differs from frozen manifest'
    objects = args.emission/'objects'
    for identity, info in manifest['objects'].items():
        raw = (objects/f'{identity}.bin').read_bytes();kind, payload = unpack(raw, identity)
        assert kind == info['kind'] and len(raw) == info['envelope_length']
        assert hashlib.sha256(payload).hexdigest() == info['payload_sha256']
        assert hashlib.sha256(raw).hexdigest() == info['envelope_sha256']
        if 'payload_hex' in info:
            assert payload.hex() == info['payload_hex']
    reader = CorpusReader(objects)
    def raw_input(case):
        if 'raw_hex' in case:
            return bytes.fromhex(case['raw_hex'])
        kind, count = case['raw_recipe']
        assert kind == 'zero-array'
        return b'\x9a'+count.to_bytes(4, 'big')+bytes(count)
    for case in manifest['files']:
        data = source_bytes(case['recipe'])
        actual, classification = reader.content(case['content_object'])
        assert actual == data and classification == 'Canonical'
        assert len(data) == case['length']
        assert hashlib.sha256(b'yeokcham:content:v1\0'+data).hexdigest() == case['full_content_id']
        if len(data) > 65536:
            assert case['chunk_ends'] == boundaries(data)
        assert reader.snapshot(case['snapshot']) == {(b'file',): ('file', 0, data)}
    mixed = reader.snapshot(manifest['trees'][0]['snapshot'])
    expected = {(b'A',): ('file', 0, b'a\r\nb'), (b'bad-\xff',): ('file', 0, b'\0\xff'),
                (b'empty',): ('directory',), (b'link',): ('file', 2, b'missing/target'),
                (b'nested',): ('directory',), (b'nested', b'note'): ('file', 0, b'end\n'),
                (b'run',): ('file', 1, b'#!/bin/sh\nexit 0\n')}
    assert mixed == expected
    identity = manifest['identity_checks']
    assert identity['content'] != identity['chunk_same_payload']
    assert len({r['snapshot'] for r in identity['positions']}) == 4
    for pair, sequence in zip(identity['history_pairs_hex'], [7, 8]):
        assert parse(bytes.fromhex(pair)) == [b'w'*16, sequence]
    assert identity['history_pairs_hex'][0] != identity['history_pairs_hex'][1]
    for case in manifest['negative']:
        try:
            if case.get('layer') == 'cbor':
                parse(raw_input(case))
            elif case.get('layer') == 'envelope':
                unpack(bytes.fromhex(case['raw_hex']))
            else:
                current = CorpusReader(objects, case.get('resolver'), case['root'])
                kind, _ = current.get(case['root'])
                if kind == 2:current.tree(case['root'])
                elif kind == 3:current.snapshot(case['root'])
                else:current.content(case['root'])
            observed = 'Accepted'
        except Refusal as error:
            observed = error.code
        assert observed == case['expected'], (case['name'], observed, case['expected'])
    legacy, state = reader.content(manifest['legacy']['root'], inspect=True)
    assert legacy == source_bytes(['P', 65537]) and state == 'LegacyReadableNoncanonical'
    try:
        reader.content(manifest['legacy']['root'])
        raise AssertionError('legacy inline admitted canonically')
    except Refusal as error:
        assert error.code == 'NoncanonicalRepresentation'
    for case in manifest['generic_cbor_positive']:
        raw = raw_input(case);assert serialize(parse(raw)) == raw
    table_hash = hashlib.sha256(b''.join(n.to_bytes(8, 'big') for n in T)).hexdigest()
    assert table_hash == manifest['table_sha256_be64']
    print(json.dumps({'files': len(manifest['files']), 'objects': len(manifest['objects']),
                      'negative': len(manifest['negative']), 'mixed_tree': True,
                      'identity_case': True, 'legacy_modes': 2,
                      'generic_positive': len(manifest['generic_cbor_positive']),
                      'table_sha256_be64': table_hash}))


if __name__ == '__main__':
    main()
