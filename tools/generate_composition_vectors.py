#!/usr/bin/env python3
"""Independent scope-page envelope and store identity; no OCaml imports."""
import argparse
import hashlib
from pathlib import Path
import struct


def cbor(value):
    if isinstance(value, int):
        return bytes([value])
    if isinstance(value, list):
        return bytes([0x80 + len(value)]) + b"".join(map(cbor, value))
    if isinstance(value, bytes) and len(value) < 24:
        return bytes([0x40 + len(value)]) + value
    raise ValueError("fixture value outside explicit CBOR subset")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    payload = cbor([1, 0, [[b"a", b"b"], [b"bad-\xff"], [b"z"]]])
    prefix = b"YEOK" + bytes([1, 44]) + struct.pack(">HQBQ", 1, 0, 1, len(payload))
    envelope = prefix + hashlib.sha256(prefix + payload).digest() + payload
    identity = hashlib.sha256(b"yeokcham:object:v1\0" + envelope).digest()
    directory = Path(__file__).resolve().parents[1] / "test/golden/composition"
    for name, data in [("edit-scope-envelope.hex", envelope), ("edit-scope-id.hex", identity)]:
        path = directory / name
        expected = data.hex() + "\n"
        if args.write:
            path.write_text(expected)
        elif path.read_text() != expected:
            raise SystemExit("composition golden differs: " + name)
    print("independent composition scope vectors verified (2)")


if __name__ == "__main__":
    main()
