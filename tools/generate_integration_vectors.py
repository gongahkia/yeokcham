#!/usr/bin/env python3
"""Independent CBOR/envelope/SHA-256 vectors for both private plan schemas."""
import argparse
import hashlib
from pathlib import Path
import struct

from generate_core_package_vectors import encode


def vectors():
    request = [b"q" * 32, b"b" * 16, [b"e" * 32], [b"a" * 32],
               [b"r" * 32], [b"z" * 32], [b"h" * 32], [], [],
               [b"w" * 16, 7, b"a" * 32, b"v" * 32, b"o" * 32, b"p" * 32],
               "line-hunks-v1"]
    fields = [request, b"s" * 32, b"d" * 32, b"k" * 32, b"v" * 32,
              [0, b"v" * 32, b"t" * 32], False]
    for schema in [1, 2]:
        control = [schema] + fields
        if schema == 2:
            control.append([[[b"note.txt"], b"x" * 32]])
        payload = encode(control)
        prefix = b"YEOK" + bytes([1, 46]) + struct.pack(">HQBQ", 1, 0, 1, len(payload))
        envelope = prefix + hashlib.sha256(prefix + payload).digest() + payload
        yield f"plan-v{schema}.hex", envelope
        yield f"plan-v{schema}-id.hex", hashlib.sha256(envelope).digest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    options = parser.parse_args()
    directory = Path(__file__).resolve().parents[1] / "test/golden/integration"
    if options.write:
        directory.mkdir(exist_ok=True)
    for name, raw in vectors():
        path = directory / name
        expected = raw.hex() + "\n"
        if options.write:
            path.write_text(expected)
        elif path.read_text() != expected:
            raise SystemExit(f"independent integration control differs: {name}")
    print("integration plan vectors verified (4)")


if __name__ == "__main__":
    main()
