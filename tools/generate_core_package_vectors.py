#!/usr/bin/env python3
"""Independent Core public-manifest CBOR and courier SHA-256 fixtures."""
import argparse
import hashlib
from pathlib import Path


def encode(value):
    if value is None:
        return b"\xf6"
    if isinstance(value, bool):
        return b"\xf5" if value else b"\xf4"
    if isinstance(value, int) and 0 <= value < 24:
        return bytes([value])
    if isinstance(value, str):
        raw = value.encode("utf-8")
        if len(raw) >= 256:
            raise ValueError("text outside independent fixture subset")
        prefix = bytes([0x60 + len(raw)]) if len(raw) < 24 else bytes([0x78, len(raw)])
        return prefix + raw
    if isinstance(value, bytes) and len(value) < 65536:
        prefix = (bytes([0x40 + len(value)]) if len(value) < 24 else
                  bytes([0x58, len(value)]) if len(value) < 256 else
                  b"\x59" + len(value).to_bytes(2, "big"))
        return prefix + value
    if isinstance(value, list) and len(value) < 24:
        return bytes([0x80 + len(value)]) + b"".join(map(encode, value))
    raise ValueError("value outside independent fixture subset")


def decode_courier(raw, offset=0):
    tag = raw[offset]
    offset += 1
    major, arg = tag >> 5, tag & 31
    if arg >= 24:
        width = {24: 1, 25: 2, 26: 4, 27: 8}[arg]
        arg = int.from_bytes(raw[offset:offset + width], "big")
        offset += width
    if major == 0:
        return arg, offset
    if major in (2, 3):
        value = raw[offset:offset + arg]
        return (value if major == 2 else value.decode("utf-8")), offset + arg
    if major == 4:
        values = []
        for _ in range(arg):
            value, offset = decode_courier(raw, offset)
            values.append(value)
        return values, offset
    raise ValueError("unexpected independent courier fixture type")


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
    courier = bytes.fromhex((directory.parent / "v1/transport-publication-v1.cbor.hex").read_text().strip())
    vectors["outbound-state.hex"] = encode([2, [], [["origin",
        hashlib.sha256(b"https://relay.invalid").hexdigest(), b"manifest", courier, False]]])
    decoded, end = decode_courier(courier)
    fields, signature = decoded
    assert end == len(courier) and fields[0] == 1 and len(signature) == 64
    endpoint = hashlib.sha256(b"https://relay.invalid").hexdigest()
    reference = [hashlib.sha256(courier).hexdigest(), fields[2], fields[3]]
    remote = ["origin", None, [reference], [hashlib.sha256(b"manifest").hexdigest()], [], []]
    vectors["courier-state.hex"] = encode([3, [remote],
        [["origin", endpoint, b"manifest", courier, True]],
        [["origin", endpoint, b"manifest", courier]]])
    for name, value in vectors.items():
        path = directory / name
        expected = value.hex() + "\n"
        if options.write:
            directory.mkdir(parents=True, exist_ok=True)
            path.write_text(expected)
        elif path.read_text() != expected:
            raise SystemExit("Core public-package fixture differs: " + name)
    print("independent Core public-package/hash/courier vectors verified (5)")


if __name__ == "__main__":
    main()
