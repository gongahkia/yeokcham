"""Regenerate P1 vectors independently with Python CBOR and OpenSSL Ed25519.

Run from the repository root with Python 3 and OpenSSL on PATH. The fixed seed
is public test material. No Yeokcham implementation is imported or executed.
"""

import hashlib
from pathlib import Path
import struct
import subprocess
import tempfile


def head(major, n):
    for bound, tag, fmt in [(24, None, None), (256, 24, ">B"),
                            (65536, 25, ">H"), (2**32, 26, ">I"),
                            (2**64, 27, ">Q")]:
        if n < bound:
            return bytes([(major << 5) | (n if tag is None else tag)]) + (
                b"" if tag is None else struct.pack(fmt, n))
    raise ValueError("integer out of range")


def cbor(value):
    if value is None:
        return b"\xf6"
    if isinstance(value, int):
        return head(0, value) if value >= 0 else head(1, -1 - value)
    if isinstance(value, bytes):
        return head(2, len(value)) + value
    if isinstance(value, str):
        raw = value.encode("utf-8")
        return head(3, len(raw)) + raw
    if isinstance(value, list):
        return head(4, len(value)) + b"".join(map(cbor, value))
    if isinstance(value, dict):
        return head(5, len(value)) + b"".join(
            cbor(k) + cbor(v) for k, v in sorted(value.items()))
    raise TypeError(type(value))


def main():
    destination = Path(__file__).resolve().parent / "golden" / "core"
    destination.mkdir(exist_ok=True)

    def save(name, raw):
        (destination / (name + ".hex")).write_text(raw.hex() + "\n")

    records = [
        ("shared-revision", 41, [b"p" * 32],
         [b"c" * 16, [b"p" * 32], b"b" * 32, b"r" * 32, b"s" * 32,
          [b"d" * 32, b"e" * 32]]),
        ("accepted-version", 42, [b"a" * 32, b"b" * 32],
         [b"m" * 16, [b"a" * 32, b"b" * 32], [b"r" * 32], [],
          b"z" * 32, "line-hunks-v1", [], []]),
        ("branch-event", 43, [b"a" * 32, b"b" * 32],
         [b"m" * 16, [b"a" * 32, b"b" * 32], 3, [b"v" * 32], None]),
    ]
    with tempfile.TemporaryDirectory(prefix="yeokcham-core-vectors-") as tmp:
        tmp = Path(tmp)
        key, message, signature = [tmp / p for p in ["key.der", "message", "signature"]]
        key.write_bytes(bytes.fromhex("302e020100300506032b657004220420") + b"a" * 32)
        key.chmod(0o600)
        for kind, code, parents, fields in records:
            body = cbor([kind, 1, b"q" * 32, parents, b"c" * 32,
                         [b"h" * 32, b"i" * 32], dict(enumerate(fields)), 1234])
            signing = ("yeokcham/record/" + kind + "/v1").encode() + body
            message.write_bytes(signing)
            subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-keyform", "DER",
                            "-inkey", str(key), "-in", str(message), "-out", str(signature)],
                           check=True)
            # The body is an embedded tuple, not a byte string.
            payload = b"\x82" + body + cbor(signature.read_bytes())
            prefix = b"YEOK" + bytes([1, code]) + struct.pack(">HQBQ", 1, 0, 1, len(payload))
            envelope = prefix + hashlib.sha256(prefix + payload).digest() + payload
            for suffix, raw in [("body", body), ("signing-input", signing),
                                ("envelope", envelope), ("id", hashlib.sha256(envelope).digest())]:
                save(kind + "-" + suffix, raw)
    save("history-id", cbor([bytes(range(16)), 2**63 - 1]))


if __name__ == "__main__":
    main()
