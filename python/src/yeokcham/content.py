"""Streaming retained contents and bounded logical trees, with injected byte IO only.

Resolvers must return at most codec.MAX_OBJECT bytes (or None); allocation inside
an arbitrary caller's resolver is outside this boundary. Sinks receive immutable
objects, not store transactions. A failed write may have emitted unrooted chunks.
"""

import hashlib
from collections.abc import Callable, Iterable, Iterator
from dataclasses import dataclass
from enum import IntEnum
from itertools import chain

from . import codec
from .codec import Value
from .errors import Code as C
from .errors import require
from .identities import ContentId, FullContentId, SnapshotId, StoredObjectId, TreeId

MASK = 2**64 - 1
state = 0x6A09E667F3BCC909
_table = []
for _ in range(256):
    state = (state * 6364136223846793005 + 1442695040888963407) & MASK
    _table.append(state)
TABLE = tuple(_table)


def chunk_bytes(feeds: Iterable[bytes]) -> Iterator[bytes]:
    window = bytearray(64)
    position = 0
    rolling = 0
    buffer = bytearray()
    for feed in feeds:
        if type(feed) is not bytes:
            raise TypeError("stream feeds must be bytes")
        for byte in feed:
            slot = position % 64
            rolling = ((rolling << 1) | (rolling >> 63)) & MASK
            rolling ^= TABLE[byte]
            if position >= 64:
                rolling ^= TABLE[window[slot]]
            window[slot] = byte
            position += 1
            buffer.append(byte)
            if len(buffer) == 131072 or (len(buffer) >= 16384 and rolling & 65535 == 0):
                yield bytes(buffer)
                buffer.clear()
    if buffer:
        yield bytes(buffer)


def write_content(
    feeds: Iterable[bytes],
    sink: Callable[[StoredObjectId, bytes], None],
    *,
    expected_size: int | None = None,
) -> ContentId:
    if expected_size is not None:
        require(
            type(expected_size) is int and 0 <= expected_size <= 2**62 - 1,
            C.INVALID_CONTENT,
            "invalid expected file size",
        )

    def put(kind: int, value: Value) -> StoredObjectId:
        raw = codec.pack(kind, codec.encode(value))
        identity = codec.object_id(raw)
        sink(identity, raw)
        return identity

    def checked_feeds() -> Iterator[bytes]:
        count = 0
        for feed in feeds:
            if type(feed) is not bytes:
                raise TypeError("stream feeds must be bytes")
            count += len(feed)
            require(count <= 2**62 - 1, C.RESOURCE_LIMIT, "file length bound")
            require(
                expected_size is None or count <= expected_size,
                C.INVALID_CONTENT,
                "file size exceeds declaration",
            )
            yield feed

    chunks = iter(chunk_bytes(checked_feeds()))
    prefix: list[bytes] = []
    prefix_size = 0
    for chunk in chunks:
        prefix.append(chunk)
        prefix_size += len(chunk)
        if prefix_size > 65536:
            break
    if prefix_size <= 65536:
        require(
            expected_size is None or expected_size == prefix_size,
            C.INVALID_CONTENT,
            "file size mismatch",
        )
        return ContentId(put(1, [1, b"".join(prefix)]).raw)
    refs: list[Value] = []
    total = 0
    digest = hashlib.sha256(b"yeokcham:content:v1\0")
    for chunk in chain(prefix, chunks):
        total += len(chunk)
        require(total <= 2**62 - 1, C.RESOURCE_LIMIT, "file length bound")
        require(len(refs) < 40000, C.RESOURCE_LIMIT, "manifest item bound")
        digest.update(chunk)
        refs.append([put(13, [1, chunk]).raw, len(chunk)])
    require(
        expected_size is None or total == expected_size,
        C.INVALID_CONTENT,
        "file size mismatch",
    )
    return ContentId(
        put(14, [1, total, 1, 64, 16384, 65536, 131072, digest.digest(), refs]).raw
    )


class Mode(IntEnum):
    REGULAR = 0
    EXECUTABLE = 1
    SYMLINK = 2


@dataclass(frozen=True)
class VerifiedContent:
    identity: ContentId
    full_id: FullContentId
    length: int
    data: bytes | None
    classification: str


@dataclass(frozen=True)
class Entry:
    kind: str
    mode: Mode | None = None
    data: bytes | None = None
    content: ContentId | None = None


@dataclass(frozen=True)
class Limits:
    objects: int = 65536
    depth: int = 256
    entries: int = 1048576
    path_bytes: int = 64 * 1024 * 1024

    def __post_init__(self) -> None:
        for value, ceiling in (
            (self.objects, 65536),
            (self.depth, 256),
            (self.entries, 1048576),
            (self.path_bytes, 64 * 1024 * 1024),
        ):
            if type(value) is not int or not 0 <= value <= ceiling:
                raise ValueError("limits may only reduce qualified bounds")


def array(value: Value, n: int) -> list[Value]:
    require(type(value) is list and len(value) == n, C.INVALID_CONTENT, "payload arity")
    assert isinstance(value, list)
    return value


def version(value: Value) -> None:
    require(type(value) is int, C.INVALID_CONTENT, "schema type")
    require(value == 1, C.UNSUPPORTED, "schema version")


def reference(value: Value) -> bytes:
    require(
        type(value) is bytes and len(value) == 32,
        C.INVALID_CONTENT,
        "reference must be 32 bytes",
    )
    assert isinstance(value, bytes)
    return value


class Verifier:
    """Each public call has fresh work counters; no root-only success is cached."""

    def __init__(
        self,
        resolver: Callable[[StoredObjectId], bytes | None],
        *,
        limits: Limits = Limits(),
    ):
        self.resolver = resolver
        self.limits = limits

    def _get(
        self, identity: StoredObjectId, seen: set[StoredObjectId]
    ) -> tuple[int, Value]:
        if identity not in seen:
            require(
                len(seen) < self.limits.objects,
                C.RESOURCE_LIMIT,
                "resolved object budget",
            )
            seen.add(identity)
        raw = self.resolver(identity)
        require(raw is not None, C.UNAVAILABLE, f"missing object {identity.hex()}")
        assert raw is not None
        env = codec.unpack(raw, identity)
        return env.kind, codec.decode(env.payload)

    def content(
        self, identity: ContentId, *, max_bytes: int = 65536
    ) -> VerifiedContent:
        return self._content(identity, max_bytes, False, set())

    def inspect_legacy(
        self, identity: ContentId, *, max_bytes: int = 65536
    ) -> VerifiedContent:
        return self._content(identity, max_bytes, True, set())

    def _content(
        self, identity: ContentId, bound: int, legacy: bool, seen: set[StoredObjectId]
    ) -> VerifiedContent:
        if type(identity) is not ContentId:
            raise TypeError("content requires ContentId")
        if type(bound) is not int or bound < 0:
            raise ValueError("display bound must be nonnegative")
        kind, value = self._get(StoredObjectId(identity.raw), seen)
        require(kind in (1, 14), C.INVALID_CONTENT, "wrong content object kind")
        digest = hashlib.sha256(b"yeokcham:content:v1\0")
        classification = "Canonical"
        if kind == 1:
            schema, data = array(value, 2)
            version(schema)
            require(type(data) is bytes, C.INVALID_CONTENT, "content is not bytes")
            assert isinstance(data, bytes)
            if len(data) > 65536:
                require(legacy, C.NONCANONICAL, "oversized inline representation")
                classification = "LegacyReadableNoncanonical"
            digest.update(data)
            return VerifiedContent(
                identity,
                FullContentId(digest.digest()),
                len(data),
                data if len(data) <= bound else None,
                classification,
            )
        fields = array(value, 9)
        version(fields[0])
        total, algorithm, window, minimum, average, maximum, full, refs = fields[1:]
        require(
            all(
                type(x) is int
                for x in (total, algorithm, window, minimum, average, maximum)
            ),
            C.INVALID_CONTENT,
            "manifest scalar type",
        )
        require(
            (algorithm, window, minimum, average, maximum)
            == (1, 64, 16384, 65536, 131072),
            C.UNSUPPORTED,
            "chunk algorithm parameters",
        )
        require(
            type(total) is int
            and 0 < total <= 2**62 - 1
            and type(refs) is list
            and bool(refs),
            C.INVALID_CONTENT,
            "manifest length/references",
        )
        assert type(total) is int and isinstance(refs, list)
        require(total > 65536, C.NONCANONICAL, "short manifest")
        expected_full = reference(full)
        lengths = []
        identities = []
        for ref in refs:
            rid, n = array(ref, 2)
            identities.append(StoredObjectId(reference(rid)))
            require(
                type(n) is int and 0 < n <= 2**62 - 1, C.INVALID_CONTENT, "chunk length"
            )
            assert type(n) is int
            lengths.append(n)
        require(sum(lengths) == total, C.INVALID_CONTENT, "manifest length sum")
        output = bytearray()
        offset = 0
        actual_ends = []
        expected_ends = []
        for n in lengths:
            offset += n
            expected_ends.append(offset)

        def feeds() -> Iterator[bytes]:
            for rid, n in zip(identities, lengths):
                k, v = self._get(rid, seen)
                require(k == 13, C.INVALID_CONTENT, "manifest reference is not chunk")
                schema, data = array(v, 2)
                version(schema)
                require(type(data) is bytes, C.INVALID_CONTENT, "chunk is not bytes")
                assert isinstance(data, bytes)
                require(len(data) == n, C.INTEGRITY, "chunk length mismatch")
                digest.update(data)
                if total <= bound:
                    output.extend(data)
                yield data

        offset = 0
        for chunk in chunk_bytes(feeds()):
            offset += len(chunk)
            actual_ends.append(offset)
        require(actual_ends == expected_ends, C.NONCANONICAL, "noncanonical chunk cuts")
        require(digest.digest() == expected_full, C.INTEGRITY, "full content identity")
        return VerifiedContent(
            identity,
            FullContentId(digest.digest()),
            total,
            bytes(output) if total <= bound else None,
            classification,
        )

    def tree(
        self, identity: TreeId, *, max_file_bytes: int = 65536
    ) -> dict[tuple[bytes, ...], Entry]:
        if type(identity) is not TreeId:
            raise TypeError("tree requires TreeId")
        return self._tree(identity, max_file_bytes, set())

    def snapshot(
        self, identity: SnapshotId, *, max_file_bytes: int = 65536
    ) -> dict[tuple[bytes, ...], Entry]:
        if type(identity) is not SnapshotId:
            raise TypeError("snapshot requires SnapshotId")
        seen: set[StoredObjectId] = set()
        kind, value = self._get(StoredObjectId(identity.raw), seen)
        require(kind == 3, C.INVALID_CONTENT, "not a snapshot")
        schema, root = array(value, 2)
        version(schema)
        return self._tree(TreeId(reference(root)), max_file_bytes, seen)

    def _tree(
        self, identity: TreeId, bound: int, seen: set[StoredObjectId]
    ) -> dict[tuple[bytes, ...], Entry]:
        result = {}
        entries = 0
        path_bytes = 0

        def walk(
            rid: TreeId, path: tuple[bytes, ...], ancestors: frozenset[TreeId]
        ) -> None:
            nonlocal entries, path_bytes
            require(
                len(path) <= self.limits.depth, C.RESOURCE_LIMIT, "tree depth budget"
            )
            require(rid not in ancestors, C.INVALID_CONTENT, "tree cycle")
            kind, value = self._get(StoredObjectId(rid.raw), seen)
            require(kind == 2, C.INVALID_CONTENT, "child is not tree")
            schema, children = array(value, 2)
            version(schema)
            require(type(children) is list, C.INVALID_CONTENT, "tree entries type")
            assert isinstance(children, list)
            previous = b""
            for child in children:
                require(
                    type(child) is list and len(child) in (3, 4),
                    C.INVALID_CONTENT,
                    "entry arity",
                )
                assert isinstance(child, list)
                tag, name = child[:2]
                require(
                    type(tag) is int
                    and tag in (0, 1)
                    and len(child) == (4 if tag == 0 else 3),
                    C.INVALID_CONTENT,
                    "entry kind/arity",
                )
                require(
                    type(name) is bytes
                    and name not in (b"", b".", b"..")
                    and b"/" not in name
                    and b"\0" not in name,
                    C.INVALID_CONTENT,
                    "invalid raw name",
                )
                assert isinstance(name, bytes)
                require(name > previous, C.INVALID_CONTENT, "tree order/duplicate")
                previous = name
                new_path = path + (name,)
                entries += 1
                path_bytes += sum(map(len, new_path))
                require(
                    entries <= self.limits.entries
                    and path_bytes <= self.limits.path_bytes,
                    C.RESOURCE_LIMIT,
                    "expanded tree budget",
                )
                target = reference(child[-1])
                if tag == 1:
                    result[new_path] = Entry("directory")
                    walk(TreeId(target), new_path, ancestors | {rid})
                else:
                    mode = child[2]
                    require(
                        type(mode) is int and mode in (0, 1, 2),
                        C.INVALID_CONTENT,
                        "file mode",
                    )
                    content_id = ContentId(target)
                    verified = self._content(content_id, bound, False, seen)
                    assert type(mode) is int
                    result[new_path] = Entry(
                        "file", Mode(mode), verified.data, content_id
                    )

        walk(identity, (), frozenset())
        return result


@dataclass(frozen=True)
class File:
    name: bytes
    mode: Mode
    content: ContentId


@dataclass(frozen=True)
class Directory:
    name: bytes
    tree: TreeId


def encode_tree(entries: Iterable[File | Directory]) -> bytes:
    rows: list[Value] = []
    names: set[bytes] = set()
    for entry in entries:
        require(len(rows) < 40000, C.RESOURCE_LIMIT, "tree item budget")
        if type(entry) not in (File, Directory):
            raise TypeError("tree entry requires File or Directory")
        name = entry.name
        require(
            type(name) is bytes
            and name not in (b"", b".", b"..")
            and b"/" not in name
            and b"\0" not in name,
            C.INVALID_CONTENT,
            "invalid raw name",
        )
        require(name not in names, C.INVALID_CONTENT, "duplicate name")
        names.add(name)
        if isinstance(entry, File):
            if type(entry.mode) is not Mode or type(entry.content) is not ContentId:
                raise TypeError("file requires Mode and ContentId")
            rows.append([0, name, int(entry.mode), entry.content.raw])
        else:
            if type(entry.tree) is not TreeId:
                raise TypeError("directory requires TreeId")
            rows.append([1, name, entry.tree.raw])
    rows.sort(
        key=lambda row: (
            row[1] if isinstance(row, list) and isinstance(row[1], bytes) else b""
        )
    )
    return codec.pack(2, codec.encode([1, rows]))


def encode_snapshot(root: TreeId) -> bytes:
    if type(root) is not TreeId:
        raise TypeError("snapshot requires TreeId")
    return codec.pack(3, codec.encode([1, root.raw]))
