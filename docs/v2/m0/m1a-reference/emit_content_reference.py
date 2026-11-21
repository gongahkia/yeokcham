#!/usr/bin/env python3
"""Fixture emitter A, not production code. Writes only a NEW external directory.

No repository implementation imports, database, filesystem capture, signing or
public-control support. Its output must pass the separately written verifier.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct


MASK = (1 << 64) - 1


def head(kind, n):
    for limit, width, tag in [(24, 0, 0), (256, 1, 24), (65536, 2, 25),
                              (1 << 32, 4, 26), (1 << 64, 8, 27)]:
        if n < limit:
            return bytes([kind * 32 + (n if width == 0 else tag)]) + (
                n.to_bytes(width, 'big') if width else b'')
    raise ValueError('fixture integer overflow')


def encode(value):
    if value is None:
        return b'\xf6'
    if type(value) is bool:
        return b'\xf5' if value else b'\xf4'
    if type(value) is int:
        return head(0 if value >= 0 else 1, value if value >= 0 else -1-value)
    if type(value) is bytes:
        return head(2, len(value)) + value
    if type(value) is str:
        raw = value.encode('utf-8')
        return head(3, len(raw)) + raw
    if type(value) is list:
        return head(4, len(value)) + b''.join(encode(v) for v in value)
    if type(value) is dict:
        return head(5, len(value)) + b''.join(encode(k)+encode(value[k]) for k in sorted(value))
    raise TypeError(type(value))


def envelope(kind, payload):
    prefix = b'YEOK' + struct.pack('>BBHQBQ', 1, kind, 1, 0, 1, len(payload))
    return prefix + hashlib.sha256(prefix + payload).digest() + payload


def pattern(n):
    return bytes(((i * 17) + (i // 256)) % 256 for i in range(n))


def fixture_bytes(recipe):
    if recipe[0] == 'hex':
        return bytes.fromhex(recipe[1])
    if recipe[0] == 'P':
        return pattern(recipe[1])
    if recipe[0] == 'repeat':
        return bytes([recipe[1]]) * recipe[2]
    if recipe[0] == 'noise':
        seed = b'yeokcham-reference-noise-v1'
        return b''.join(hashlib.sha256(seed+i.to_bytes(8, 'big')).digest()
                        for i in range((recipe[1]+31)//32))[:recipe[1]]
    raise ValueError(recipe)


TABLE = []
state = 0x6a09e667f3bcc909
for _ in range(256):
    state = (state * 6364136223846793005 + 1442695040888963407) & MASK
    TABLE.append(state)


def cuts(data, feed_size):
    ring = bytearray(64)
    seen = rolling = length = 0
    boundaries = []
    for start in range(0, len(data), feed_size):
        for b in data[start:start+feed_size]:
            outgoing = ring[seen % 64] if seen >= 64 else None
            rolling = (((rolling << 1) | (rolling >> 63)) & MASK) ^ TABLE[b]
            if outgoing is not None:
                rolling ^= TABLE[outgoing]
            ring[seen % 64] = b
            seen += 1
            length += 1
            if length >= 131072 or (length >= 16384 and rolling & 65535 == 0):
                boundaries.append(seen)
                length = 0
    if length:
        boundaries.append(seen)
    return boundaries


def emit(output):
    objects = {}
    raw_objects = {}
    out = {'format': 'yeokcham-m1a-content-reference-1', 'files': [],
           'trees': [], 'negative': [], 'identity_checks': [], 'objects': objects}
    (output/'objects').mkdir()
    (output/'inputs').mkdir()
    (output/'payloads').mkdir()

    def put(kind, value=None, raw_payload=None):
        payload = encode(value) if raw_payload is None else raw_payload
        raw = envelope(kind, payload)
        identity = hashlib.sha256(b'yeokcham:object:v1\0' + raw).hexdigest()
        if identity not in objects:
            record = {'kind': kind, 'envelope_length': len(raw),
                      'payload_sha256': hashlib.sha256(payload).hexdigest(),
                      'envelope_sha256': hashlib.sha256(raw).hexdigest()}
            if len(payload) <= 512:
                record['payload_hex'] = payload.hex()
            objects[identity] = record
            raw_objects[identity] = raw
            (output/'objects'/f'{identity}.bin').write_bytes(raw)
            (output/'payloads'/f'{identity}.bin').write_bytes(payload)
        return identity

    def refs_for(data, boundaries):
        refs = []
        previous = 0
        for end in boundaries:
            chunk = data[previous:end]
            refs.append([bytes.fromhex(put(13, [1, chunk])), len(chunk)])
            previous = end
        return refs

    def manifest(data, refs, **changes):
        values = [1, len(data), 1, 64, 16384, 65536, 131072,
                  hashlib.sha256(b'yeokcham:content:v1\0'+data).digest(), refs]
        for index, value in changes.items():
            values[int(index)] = value
        return put(14, values)

    definitions = [('RC01-empty', ['hex', '']), ('RC01-one', ['hex', '00'])]
    definitions += [(f'RC01-P{n}', ['P', n]) for n in [65535, 65536, 65537]]
    definitions += [('RC02-P200000', ['P', 200000]),
                    ('RC02-P1048589', ['P', 1048589]),
                    ('RC02-zero262145', ['repeat', 0, 262145]),
                    ('SUP-repeat1-262145', ['repeat', 1, 262145]),
                    ('SUP-noise262145', ['noise', 262145]),
                    ('SUP-crlf', ['hex', b'a\r\nb'.hex()]),
                    ('SUP-lf', ['hex', b'a\nb'.hex()]),
                    ('SUP-final-lf', ['hex', b'a\nb\n'.hex()]),
                    ('SUP-binary', ['hex', '00ff'])]
    records = {}
    for name, recipe in definitions:
        data = fixture_bytes(recipe)
        cut = cuts(data, max(1, len(data)))
        feed_sizes = [1, 63, 64, 65, 16384, 65536, max(1, len(data))]
        if name.startswith('RC02'):
            assert all(cuts(data, size) == cut for size in feed_sizes)
        refs = refs_for(data, cut) if len(data) > 65536 else []
        content = (put(1, [1, data]) if len(data) <= 65536 else manifest(data, refs))
        tree = put(2, [1, [[0, b'file', 0, bytes.fromhex(content)]]])
        snapshot = put(3, [1, bytes.fromhex(tree)])
        record = {'name': name, 'recipe': recipe, 'length': len(data),
                  'representation': 'inline' if len(data) <= 65536 else 'manifest',
                  'full_content_id': hashlib.sha256(b'yeokcham:content:v1\0'+data).hexdigest(),
                  'content_object': content, 'tree': tree, 'snapshot': snapshot,
                  'chunk_ends': cut if refs else [],
                  'feed_sizes_checked': feed_sizes if name.startswith('RC02') else []}
        out['files'].append(record)
        records[name] = (data, refs, record)
        (output/'inputs'/f'{name}.bin').write_bytes(data)

    empty = put(2, [1, []])
    leaves = [(b'A', 0, b'a\r\nb'), (b'bad-\xff', 0, b'\0\xff'),
              (b'link', 2, b'missing/target'), (b'run', 1, b'#!/bin/sh\nexit 0\n')]
    entries = [[0, name, mode, bytes.fromhex(put(1, [1, data]))] for name, mode, data in leaves]
    note = put(1, [1, b'end\n'])
    nested = put(2, [1, [[0, b'note', 0, bytes.fromhex(note)]]])
    entries += [[1, b'empty', bytes.fromhex(empty)], [1, b'nested', bytes.fromhex(nested)]]
    entries.sort(key=lambda x: x[1])
    mixed = put(2, [1, entries])
    out['trees'].append({'name': 'RC03-mixed', 'tree': mixed,
                         'snapshot': put(3, [1, bytes.fromhex(mixed)]),
                         'entry_names_hex': [x[1].hex() for x in entries]})

    same = put(1, [1, b'same\n'])
    pairs = []
    for label, entry_values in [('one', [[0, b'a', 0, bytes.fromhex(same)]]),
                                ('two', [[0, b'b', 0, bytes.fromhex(same)]]),
                                ('exec', [[0, b'a', 1, bytes.fromhex(same)]]),
                                ('both', [[0, b'a', 0, bytes.fromhex(same)],
                                          [0, b'b', 0, bytes.fromhex(same)]])]:
        tree = put(2, [1, entry_values]);snapshot = put(3, [1, bytes.fromhex(tree)])
        pairs.append({'label': label, 'tree': tree, 'snapshot': snapshot})
    out['identity_checks'] = {'name': 'RC04', 'content': same,
                             'chunk_same_payload': put(13, [1, b'same\n']),
                             'positions': pairs,
                             'history_pairs_hex': [encode([b'w'*16, i]).hex() for i in [7, 8]],
                             'history_snapshot': pairs[0]['snapshot']}

    def negative(name, expected, root=None, **extra):
        out['negative'].append({'name': name, 'expected': expected, 'root': root, **extra})

    data, refs, record = records['RC02-P200000']
    root = record['content_object']
    negative('RC05-missing-chunk', 'Unavailable', root, resolver='omit-first')
    negative('RC05-corrupt-chunk', 'IntegrityFailure', root, resolver='corrupt-first')
    negative('RC05-total-sum', 'InvalidContent', manifest(data, refs, **{'1': len(data)+1}))
    wrong = [[i, n+1 if k == 0 else n] for k, (i, n) in enumerate(refs)]
    negative('RC05-chunk-length', 'IntegrityFailure', manifest(data, wrong, **{'1': len(data)+1}))
    negative('RC05-full-id', 'IntegrityFailure', manifest(data, refs, **{'7': b'z'*32}))
    short = b'one'
    negative('RC05-short-manifest', 'NoncanonicalRepresentation',
             manifest(short, refs_for(short, [len(short)])))
    bad_refs = refs_for(data, [1, len(data)])
    negative('RC05-boundaries', 'NoncanonicalRepresentation', manifest(data, bad_refs))
    negative('RC05-parameters', 'UnsupportedFormat', manifest(data, refs, **{'3': 63}))
    negative('RC05-algorithm', 'UnsupportedFormat', manifest(data, refs, **{'2': 2}))
    bad_kind = [[bytes.fromhex(put(1, [1, data[:refs[0][1]]])), refs[0][1]]] + refs[1:]
    negative('RC05-wrong-kind', 'InvalidContent', manifest(data, bad_kind))
    negative('RC05-zero-chunk', 'InvalidContent', manifest(data, [[refs[0][0], 0]]+refs[1:]))
    negative('RC05-manifest-false-total-type', 'InvalidContent',
             manifest(data, refs, **{'1': True}))
    negative('RC05-native-total-overflow', 'InvalidContent', manifest(data, refs, **{'1': 1 << 62}))
    negative('RC05-native-chunk-overflow', 'InvalidContent', manifest(data, [[refs[0][0], 1 << 62]]+refs[1:]))
    for label, name in [('empty', b''), ('dot', b'.'), ('dotdot', b'..'),
                        ('slash', b'a/b'), ('nul', b'a\0b')]:
        negative('RC06-name-'+label, 'InvalidContent',
                 put(2, [1, [[0, name, 0, bytes.fromhex(same)]]]))
    negative('RC06-duplicate-name', 'InvalidContent', put(2, [1, [[0, b'a', 0, bytes.fromhex(same)]]*2]))
    negative('RC06-unordered-name', 'InvalidContent', put(2, [1, [[0, b'z', 0, bytes.fromhex(same)], [0, b'a', 0, bytes.fromhex(same)]]]))
    negative('RC06-mode', 'InvalidContent', put(2, [1, [[0, b'a', 3, bytes.fromhex(same)]]]))
    negative('RC06-bool-mode', 'InvalidContent', put(2, [1, [[0, b'a', True, bytes.fromhex(same)]]]))
    negative('RC06-text-name', 'InvalidContent', put(2, [1, [[0, 'a', 0, bytes.fromhex(same)]]]))
    negative('RC06-short-snapshot-id', 'InvalidContent', put(3, [1, b'x'*31]))
    negative('RC06-bool-version', 'InvalidContent', put(1, [True, b'']))
    negative('RC06-content-schema', 'UnsupportedFormat', put(1, [2, b'']))
    negative('RC06-content-not-bytes', 'InvalidContent', put(1, [1, 'x']))
    for label, raw in [('nonminimal', b'\x82\x18\x01\x40'),
                       ('trailing', b'\x82\x01\x40\x00'),
                       ('truncated', b'\x82\x01\x42x')]:
        negative('RC06-payload-'+label, 'InvalidEncoding', put(1, raw_payload=raw))
    cbor_bad = [('indefinite', '9fff', 'InvalidEncoding'), ('tag', 'c000', 'InvalidEncoding'),
                ('float', 'fa00000000', 'InvalidEncoding'), ('utf8', '61ff', 'InvalidEncoding'),
                ('duplicate-map', 'a200000001', 'InvalidEncoding'),
                ('unordered-map', 'a201000000', 'InvalidEncoding'),
                ('negative-map-key', 'a12000', 'InvalidEncoding'),
                ('int-overflow', '1b8000000000000000', 'InvalidEncoding'),
                ('depth65', ('81'*65)+'00', 'ResourceLimit'),
                ('declared-array-bomb', '9affffffff', 'InvalidEncoding')]
    for label, raw, expected in cbor_bad:
        negative('RC06-cbor-'+label, expected, layer='cbor', raw_hex=raw)
    negative('RC06-cbor-item-budget', 'ResourceLimit', layer='cbor', raw_recipe=['zero-array', 131200])
    raw = raw_objects[same]
    for n in range(57):
        negative(f'RC06-header-prefix-{n}', 'InvalidEncoding', layer='envelope', raw_hex=raw[:n].hex())
    for label, offset, replacement, expected in [
            ('magic', 0, 0, 'InvalidEncoding'), ('version', 4, 2, 'UnsupportedFormat'),
            ('length', 24, raw[24]+1, 'InvalidEncoding'), ('checksum', 25, raw[25]^1, 'IntegrityFailure')]:
        changed = bytearray(raw);changed[offset] = replacement
        negative('RC06-envelope-'+label, expected, layer='envelope', raw_hex=changed.hex())
    for label, offset, replacement in [('kind', 5, 255), ('format', 7, 2), ('feature', 15, 1), ('checksum-kind', 16, 2)]:
        changed = bytearray(raw);changed[offset] = replacement
        changed[25:57] = hashlib.sha256(changed[:25]+changed[57:]).digest()
        negative('RC06-envelope-'+label, 'UnsupportedFormat', layer='envelope', raw_hex=changed.hex())
    huge = bytearray(raw[:57]);huge[17:25] = (128*1024*1024-56).to_bytes(8, 'big')
    negative('RC06-envelope-declared-over-budget', 'ResourceLimit', layer='envelope', raw_hex=huge.hex())
    signed_overflow = bytearray(raw[:57]);signed_overflow[17:25] = (1 << 63).to_bytes(8, 'big')
    negative('RC06-envelope-length-int64-overflow', 'InvalidEncoding', layer='envelope', raw_hex=signed_overflow.hex())
    legacy = put(1, [1, pattern(65537)])
    out['legacy'] = {'name': 'RC07', 'recipe': ['P', 65537], 'root': legacy,
                     'inspection': 'LegacyReadableNoncanonical',
                     'canonical_admission': 'NoncanonicalRepresentation',
                     'canonical_equivalent': records['RC01-P65537'][2]['content_object']}
    out['generic_cbor_positive'] = [{'raw_hex': 'a200000200', 'value': 'sparse integer map'},
                                     {'raw_hex': ('81'*64)+'00', 'value': 'depth64'},
                                     {'raw_recipe': ['zero-array', 131199], 'value': '131200 total items'}]
    out['generic_cbor_positive'] += [
        {'raw_hex': encode(v).hex(), 'value': repr(v)}
        for v in [0, 1, 23, 24, 255, 256, 65535, 65536, (1 << 32)-1,
                  1 << 32, (1 << 63)-1, -1, -(1 << 63), True, False, None]]
    out['table_sha256_be64'] = hashlib.sha256(b''.join(x.to_bytes(8, 'big') for x in TABLE)).hexdigest()
    (output/'corpus.json').write_text(json.dumps(out, indent=2, sort_keys=True)+'\n')
    print(json.dumps({'files': len(out['files']), 'objects': len(objects),
                      'negatives': len(out['negative']), 'output': str(output)}))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out', required=True, type=Path)
    destination = p.parse_args().out.resolve()
    checkout = Path(__file__).resolve().parents[4]
    if destination == checkout or checkout in destination.parents:
        p.error('output must be outside the source checkout')
    destination.mkdir(parents=True, exist_ok=False)
    emit(destination)
