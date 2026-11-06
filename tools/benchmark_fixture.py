#!/usr/bin/env python3
"""Versioned deterministic benchmark fixtures; standard library only."""
import argparse
import binascii
import struct
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

VERSION = 1
TIERS = {
    'source': [(10 * 2**20, 1000), (100 * 2**20, 10000), (2**30, 100000)],
    'monorepo': [(2**30, 100000), (10 * 2**30, 500000), (50 * 2**30, 1000000)],
    'asset': [(2**30, 1000), (10 * 2**30, 10000), (50 * 2**30, 50000)],
}


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def digest(value):
    return hashlib.sha256(encoded(value)).hexdigest()


def file_hash(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def inventory(root):
    """Record all paths, bytes, executable bits and link targets; exclude runtime metadata."""
    entries = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        if Path(directory) == root:
            dirs[:] = [name for name in dirs if name != '.yeokcham']
        for name in sorted(dirs + files):
            path = Path(directory) / name
            info = path.lstat()
            entry = {'path': path.relative_to(root).as_posix()}
            if stat.S_ISLNK(info.st_mode):
                entry.update(kind='symlink', target=os.readlink(path))
            elif stat.S_ISDIR(info.st_mode):
                entry.update(kind='directory')
            elif stat.S_ISREG(info.st_mode):
                entry.update(kind='file', bytes=info.st_size,
                             executable=bool(info.st_mode & 0o111), sha256=file_hash(path))
            else:
                raise ValueError(f'unsupported fixture entry: {path}')
            entries.append(entry)
    return sorted(entries, key=lambda entry: entry['path'])


def verify(root, manifest):
    actual = inventory(root)
    if actual != manifest['entries']:
        expected = {e['path']: e for e in manifest['entries']}
        observed = {e['path']: e for e in actual}
        changed = [p for p in sorted(expected.keys() | observed.keys())
                   if expected.get(p) != observed.get(p)]
        raise ValueError(f'fixture fidelity failure ({len(changed)} paths): {changed[:5]}')
    if digest(actual) != manifest['tree_sha256']:
        raise ValueError('manifest tree hash mismatch')
    return manifest['tree_sha256']


def gzip_member(payload):
    # One stored DEFLATE block: valid high-entropy gzip, stable across zlib/OS versions.
    size = len(payload)
    return (bytes.fromhex('1f8b08000000000000ff') + b'\x01'
            + struct.pack('<HH', size, size ^ 0xffff) + payload
            + struct.pack('<II', binascii.crc32(payload), size))


def block(seed, index, kind, offset):
    entropy = hashlib.shake_256(f'yeokcham-fixture-v{VERSION}:{seed}:{index}:{offset}'.encode()).digest(32768)
    if kind == 'opaque':
        return entropy
    token = entropy[:24].hex()
    if kind == 'reusable':
        token = f'{index % 16:048x}'
    return (f'// fixture {index} block {offset} token {token}\n'
            f'export function value_{index}() {{ return "{token}"; }}\n'
            '# documentation config test data: deterministic synthetic source\n').encode() * 32


def generate(root, total_bytes, files, suite='source', seed=1, depth=3, fanout=8,
             large_file_bytes=0, attributes=False):
    if suite not in TIERS or files < 1 or total_bytes < files or depth < 0 or fanout < 1:
        raise ValueError('require known suite, bytes >= files >= 1, depth >= 0, fanout >= 1')
    if large_file_bytes < 0 or large_file_bytes > total_bytes - (files - 1):
        raise ValueError('large-file bytes must leave at least one byte per other file')
    if files == 1 and large_file_bytes not in (0, total_bytes):
        raise ValueError('single file must contain the complete requested size')
    root.mkdir(parents=True, exist_ok=False)
    remainder_files = files - bool(large_file_bytes)
    remaining = total_bytes - large_file_bytes
    base, remainder = divmod(remaining, remainder_files) if remainder_files else (0, 0)
    for index in range(files):
        size = large_file_bytes if large_file_bytes and index == 0 else base + (index - bool(large_file_bytes) < remainder)
        parts = [f'd{level}-{(index // fanout**level) % fanout:03d}' for level in range(depth)]
        if suite == 'monorepo':
            parts.insert(0, f'packages/pkg-{index % 100:03d}')
        kind = ('source' if index % 3 else 'reusable') if suite == 'source' else ['source', 'reusable', 'opaque', 'compressed'][index % 4]
        if suite == 'asset' and large_file_bytes and index == 0:
            kind = 'opaque'
        suffix = ['.ts', '.ml', '.json', '.md', '.test.txt'][index % 5] if kind in ('source', 'reusable') else ('.gz' if kind == 'compressed' else '.bin')
        path = root.joinpath(*parts, f'file-{index:07d}{suffix}')
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('wb') as stream:
            offset = 0
            while size:
                if kind == 'compressed' and size >= 64:
                    payload = hashlib.shake_256(f'gzip:{seed}:{index}:{offset}'.encode()).digest(min(32768, size - 32))
                    content = gzip_member(payload)
                elif kind == 'compressed':
                    content = bytes(size)  # gzip permits zero padding after the last member
                else:
                    content = block(seed, index, kind, offset)[:size]
                stream.write(content)
                size -= len(content)
                offset += 1
        path.chmod(0o755 if attributes and index == 0 else 0o644)
    if attributes:
        (root / 'empty-directory').mkdir()
        first = next(e['path'] for e in inventory(root) if e['kind'] == 'file')
        (root / 'fixture-link').symlink_to(first)
    entries = inventory(root)
    manifest = {
        'schema': 'yeokcham-benchmark-fixture-v1', 'generator_version': VERSION,
        'config': dict(total_bytes=total_bytes, files=files, suite=suite, seed=seed,
                       depth=depth, fanout=fanout, large_file_bytes=large_file_bytes,
                       attributes=attributes),
        'entries': entries, 'tree_sha256': digest(entries),
    }
    verify(root, manifest)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--suite', choices=TIERS, default='source')
    parser.add_argument('--bytes', type=int, default=10 * 2**20)
    parser.add_argument('--files', type=int, default=1000)
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--depth', type=int, default=3)
    parser.add_argument('--fanout', type=int, default=8)
    parser.add_argument('--large-file-bytes', type=int, default=0)
    parser.add_argument('--attributes', action='store_true')
    args = parser.parse_args()
    if args.verify:
        print(verify(args.root, json.loads(args.manifest.read_text())))
    else:
        if args.manifest.resolve().is_relative_to(args.root.resolve()):
            raise ValueError('manifest must be outside the fixture')
        manifest = generate(args.root, args.bytes, args.files, args.suite, args.seed,
                            args.depth, args.fanout, args.large_file_bytes, args.attributes)
        args.manifest.write_text(json.dumps(manifest, indent=2) + '\n')
        print(manifest['tree_sha256'])


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        print(json.dumps({'status': 'error', 'error': str(error)}), file=sys.stderr)
        sys.exit(1)
