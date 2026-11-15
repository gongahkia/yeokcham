#!/usr/bin/env python3
"""Independent Core public-manifest CBOR and courier SHA-256 fixtures."""
import argparse
import hashlib
from pathlib import Path


def encode(value):
    if isinstance(value, int) and 0 <= value < 24:
        return bytes([value])
    if isinstance(value, bytes) and len(value) < 256:
        prefix = bytes([0x40 + len(value)]) if len(value) < 24 else bytes([0x58, len(value)])
        return prefix + value
    if isinstance(value, list) and len(value) < 24:
        return bytes([0x80 + len(value)]) + b"".join(map(encode, value))
    raise ValueError("value outside independent fixture subset")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    options = parser.parse_args()
    manifest = encode([2, b"a" * 32, b"b" * 16, b"r" * 32,
                       b"u" * 32, b"t" * 32, b"o" * 32])
    directory = Path(__file__).resolve().parents[1] / "test/golden/core-package"
    stream = bytes(i % 251 for i in range(1024 * 1024 + 7))
    vectors = {"manifest.hex": manifest, "courier-manifest-id.hex": hashlib.sha256(manifest).digest(),
               "hash-stream-id.hex": hashlib.sha256(stream).digest()}
    for name, value in vectors.items():
        path = directory / name
        expected = value.hex() + "\n"
        if options.write:
            directory.mkdir(parents=True, exist_ok=True)
            path.write_text(expected)
        elif path.read_text() != expected:
            raise SystemExit("Core public-package fixture differs: " + name)
    print("independent Core public-package/hash vectors verified (3)")


if __name__ == "__main__":
    main()
