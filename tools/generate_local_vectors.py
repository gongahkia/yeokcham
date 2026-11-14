#!/usr/bin/env python3
"""Independent canonical CBOR fixture for the local copy-out journal scope."""
import argparse
from pathlib import Path


def head(major, size):
    if size < 24:
        return bytes([major * 32 + size])
    if size < 256:
        return bytes([major * 32 + 24, size])
    if size < 65536:
        return bytes([major * 32 + 25]) + size.to_bytes(2, "big")
    raise ValueError("fixture argument exceeds supported bound")


def encode(value):
    if value is None:
        return b"\xf6"
    if isinstance(value, int):
        return head(0, value)
    if isinstance(value, bytes):
        return head(2, len(value)) + value
    if isinstance(value, str):
        data = value.encode("utf-8")
        return head(3, len(data)) + data
    if isinstance(value, list):
        return head(4, len(value)) + b"".join(map(encode, value))
    raise TypeError(type(value))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true", help="replace the owned golden fixture")
    arguments = parser.parse_args()
    records = {
        "restore-copyout-v4.cbor.hex": [4, "a" * 64, "snapshot-target", "snapshot-target", 0, 0,
                                        None, b"p" * 32, None, b"/fixture/copy"],
        "restore-selection-v5.cbor.hex": [5, "a" * 64, "snapshot-target", "snapshot-target", 0, 0,
                                          2, b"p" * 32, None, b"s" * 32],
    }
    directory = Path(__file__).resolve().parents[1] / "test/golden/local"
    for name, record in records.items():
        expected = encode(record).hex() + "\n"
        path = directory / name
        if arguments.write:
            path.write_text(expected)
        elif path.read_text() != expected:
            raise SystemExit(f"local journal golden differs from independent encoding: {name}")
    print(f"local journal vectors verified ({len(records)})")
