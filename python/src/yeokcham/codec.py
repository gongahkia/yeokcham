"""Bounded retained CBOR and Envelope-1; deliberately excludes public controls."""

import hashlib
import struct
from dataclasses import dataclass
from typing import BinaryIO, TypeAlias

from .errors import Code as C
from .errors import require
from .identities import StoredObjectId

Value: TypeAlias = int | bool | None | bytes | str | list["Value"] | dict[int, "Value"]
MAX_OBJECT = 128 * 1024 * 1024


def decode(
    raw: bytes,
    *,
    max_bytes: int = MAX_OBJECT,
    max_items: int = 131200,
    max_depth: int = 64,
) -> Value:
    if any(
        type(n) is not int or not 0 <= n <= cap
        for n, cap in ((max_bytes, MAX_OBJECT), (max_items, 131200), (max_depth, 64))
    ):
        raise ValueError("parser limits may only reduce qualified bounds")
    if type(raw) is not bytes:
        raise TypeError("CBOR input must be bytes")
    require(len(raw) <= max_bytes, C.RESOURCE_LIMIT, "CBOR byte budget")
    at = 0
    remaining = max_items

    def take(n: int) -> bytes:
        nonlocal at
        require(0 <= n <= len(raw) - at, C.INVALID_ENCODING, "truncated CBOR")
        out = raw[at : at + n]
        at += n
        return out

    def read(depth: int) -> Value:
        nonlocal remaining
        require(remaining > 0, C.RESOURCE_LIMIT, "CBOR item budget")
        remaining -= 1
        tag = take(1)[0]
        major, arg = tag >> 5, tag & 31
        if major == 7:
            require(arg in (20, 21, 22), C.INVALID_ENCODING, "unsupported simple value")
            return {20: False, 21: True, 22: None}[arg]
        require(major <= 5, C.INVALID_ENCODING, "unsupported CBOR major type")
        if arg >= 24:
            require(arg <= 27, C.INVALID_ENCODING, "indefinite/reserved argument")
            width = 1 << (arg - 24)
            n = int.from_bytes(take(width), "big")
            require(
                n >= {1: 24, 2: 256, 4: 65536, 8: 2**32}[width],
                C.INVALID_ENCODING,
                "nonminimal argument",
            )
        else:
            n = arg
        if major <= 1:
            require(n < 2**63, C.INVALID_ENCODING, "integer outside int64")
            return n if major == 0 else -1 - n
        if major in (2, 3):
            data = take(n)
            if major == 2:
                return data
            try:
                return data.decode("utf-8", errors="strict")
            except UnicodeDecodeError:
                require(False, C.INVALID_ENCODING, "invalid UTF-8")
        require(depth < max_depth, C.RESOURCE_LIMIT, "CBOR depth budget")
        count = n * (2 if major == 5 else 1)
        require(
            count <= len(raw) - at, C.INVALID_ENCODING, "impossible container arity"
        )
        require(count <= remaining, C.RESOURCE_LIMIT, "CBOR container item budget")
        if major == 4:
            return [read(depth + 1) for _ in range(n)]
        result: dict[int, Value] = {}
        previous = -1
        for _ in range(n):
            key = read(depth + 1)
            require(
                type(key) is int and key > previous,
                C.INVALID_ENCODING,
                "map key order/type",
            )
            assert type(key) is int
            previous = key
            result[key] = read(depth + 1)
        return result

    result = read(0)
    require(at == len(raw), C.INVALID_ENCODING, "trailing CBOR")
    return result


def encode(value: Value) -> bytes:
    output = bytearray()
    remaining = 131200

    def head(major: int, n: int) -> None:
        if n < 24:
            output.append((major << 5) | n)
        else:
            width = next(w for w in (1, 2, 4, 8) if n < 1 << (w * 8))
            output.append((major << 5) | {1: 24, 2: 25, 4: 26, 8: 27}[width])
            output.extend(n.to_bytes(width, "big"))

    def write(item: Value, depth: int) -> None:
        nonlocal remaining
        require(remaining > 0, C.RESOURCE_LIMIT, "encoder item budget")
        remaining -= 1
        if item is None:
            output.append(246)
        elif type(item) is bool:
            output.append(245 if item else 244)
        elif type(item) is int:
            require(
                -(2**63) <= item < 2**63, C.INVALID_ENCODING, "integer outside int64"
            )
            head(0 if item >= 0 else 1, item if item >= 0 else -1 - item)
        elif isinstance(item, (bytes, str)):
            try:
                data = item.encode("utf-8") if isinstance(item, str) else item
            except UnicodeEncodeError:
                require(False, C.INVALID_ENCODING, "invalid Unicode scalar")
                return
            require(
                len(output) + len(data) + 9 <= MAX_OBJECT,
                C.RESOURCE_LIMIT,
                "encoder byte budget",
            )
            head(3 if isinstance(item, str) else 2, len(data))
            output.extend(data)
        elif isinstance(item, (list, dict)):
            require(depth < 64, C.RESOURCE_LIMIT, "encoder depth budget")
            require(
                len(item) * (2 if isinstance(item, dict) else 1) <= remaining,
                C.RESOURCE_LIMIT,
                "encoder arity budget",
            )
            if isinstance(item, dict):
                require(
                    all(type(k) is int and 0 <= k < 2**63 for k in item),
                    C.INVALID_ENCODING,
                    "map key type",
                )
                head(5, len(item))
                for k in sorted(item):
                    write(k, depth + 1)
                    write(item[k], depth + 1)
            else:
                head(4, len(item))
                for child in item:
                    write(child, depth + 1)
        else:
            raise TypeError("unsupported CBOR value")
        require(len(output) <= MAX_OBJECT, C.RESOURCE_LIMIT, "encoder byte budget")

    write(value, 0)
    return bytes(output)


@dataclass(frozen=True)
class Envelope:
    kind: int
    payload: bytes


def object_id(raw: bytes) -> StoredObjectId:
    if type(raw) is not bytes:
        raise TypeError("hash requires bytes")
    return StoredObjectId(hashlib.sha256(b"yeokcham:object:v1\0" + raw).digest())


def pack(kind: int, payload: bytes) -> bytes:
    require(
        type(kind) is int and kind in (1, 2, 3, 13, 14),
        C.UNSUPPORTED,
        "unsupported object kind",
    )
    require(type(payload) is bytes, C.INVALID_ENCODING, "payload must be bytes")
    require(len(payload) <= MAX_OBJECT - 57, C.RESOURCE_LIMIT, "object byte budget")
    prefix = b"YEOK" + struct.pack(">BBHQBQ", 1, kind, 1, 0, 1, len(payload))
    return prefix + hashlib.sha256(prefix + payload).digest() + payload


def unpack(
    raw: bytes, expected: StoredObjectId | None = None, *, max_bytes: int = MAX_OBJECT
) -> Envelope:
    if type(raw) is not bytes or (
        expected is not None and type(expected) is not StoredObjectId
    ):
        raise TypeError("envelope requires bytes and StoredObjectId")
    require(
        len(raw) <= min(max_bytes, MAX_OBJECT), C.RESOURCE_LIMIT, "object byte budget"
    )
    require(
        len(raw) >= 57 and raw[:4] == b"YEOK",
        C.INVALID_ENCODING,
        "truncated/bad header",
    )
    require(raw[4] == 1 and raw[16] == 1, C.UNSUPPORTED, "envelope/profile version")
    length = int.from_bytes(raw[17:25], "big")
    require(length < 2**63, C.INVALID_ENCODING, "envelope length overflow")
    require(
        length <= min(max_bytes, MAX_OBJECT) - 57,
        C.RESOURCE_LIMIT,
        "declared object byte budget",
    )
    require(
        length == len(raw) - 57, C.INVALID_ENCODING, "declared length/trailing bytes"
    )
    require(
        hashlib.sha256(raw[:25] + raw[57:]).digest() == raw[25:57],
        C.INTEGRITY,
        "envelope checksum",
    )
    if expected is not None:
        require(object_id(raw) == expected, C.INTEGRITY, "stored object identity")
    require(
        raw[5] in (1, 2, 3, 13, 14) and raw[6:8] == b"\0\1" and raw[8:16] == bytes(8),
        C.UNSUPPORTED,
        "object kind/format/features",
    )
    return Envelope(raw[5], raw[57:])


def read_envelope(
    source: BinaryIO,
    expected: StoredObjectId | None = None,
    *,
    max_bytes: int = MAX_OBJECT,
) -> Envelope:
    """Read one bounded frame, refusing a declared oversize before payload IO.

    The injected stream must honor read(n). No filesystem is opened here.
    """
    if type(max_bytes) is not int or not 57 <= max_bytes <= MAX_OBJECT:
        raise ValueError("invalid envelope byte budget")

    def take(count: int) -> bytes:
        result = bytearray()
        while len(result) < count:
            wanted = min(65536, count - len(result))
            part = source.read(wanted)
            require(
                type(part) is bytes and 0 < len(part) <= wanted,
                C.INVALID_ENCODING,
                "short or invalid stream read",
            )
            result.extend(part)
        return bytes(result)

    header = take(57)
    require(header[:4] == b"YEOK", C.INVALID_ENCODING, "bad stream header")
    require(
        header[4] == 1 and header[16] == 1, C.UNSUPPORTED, "envelope/profile version"
    )
    length = int.from_bytes(header[17:25], "big")
    require(length < 2**63, C.INVALID_ENCODING, "envelope length overflow")
    require(length <= max_bytes - 57, C.RESOURCE_LIMIT, "declared stream byte budget")
    payload = take(length)
    require(source.read(1) == b"", C.INVALID_ENCODING, "trailing stream bytes")
    return unpack(header + payload, expected, max_bytes=max_bytes)
