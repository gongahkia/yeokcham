"""Bounded, read-only observation and detached canonical object construction."""

import errno
import hashlib
import os
import platform
import stat
import sys
import time
from collections.abc import Callable, Iterator
from contextlib import ExitStack, contextmanager
from dataclasses import dataclass
from typing import Literal

from . import _observation_linux as native
from . import codec, content
from .errors import Code, ContentError
from .identities import ContentId, SnapshotId, StoredObjectId, TreeId

RawPath = tuple[bytes, ...]
NativeIdentity = tuple[int, int]
Resolver = Callable[[StoredObjectId], bytes | None]
ObservationCode = Literal[
    "InvalidRoot",
    "Scope",
    "UnsupportedNative",
    "PermissionDenied",
    "ObservationIO",
    "IgnoreUnsupported",
    "Unstable",
]
_RESERVED = {b".yeokcham", b".yeokcham-v2"}
_STORE_MARKERS = {b"FORMAT", b"metadata.sqlite3"}
_IGNORE = b".yeokchamignore"
_ATTEMPTS = 3


@dataclass(frozen=True)
class ObservationLimits:
    depth: int = 64
    entries: int = 8192
    path_bytes: int = 4 * 1024 * 1024
    source_bytes: int = 64 * 1024 * 1024
    object_bytes: int = 80 * 1024 * 1024
    objects: int = 16384

    def __post_init__(self) -> None:
        for field, ceiling in (
            ("depth", 64),
            ("entries", 8192),
            ("path_bytes", 4 * 1024 * 1024),
            ("source_bytes", 64 * 1024 * 1024),
            ("object_bytes", 80 * 1024 * 1024),
            ("objects", 16384),
        ):
            value = getattr(self, field)
            if type(value) is not int or not 0 <= value <= ceiling:
                raise ValueError(f"{field} must be between zero and {ceiling}")


DEFAULT_LIMITS = ObservationLimits()


@dataclass(frozen=True)
class NativeStamp:
    device: int
    inode: int
    mode: int
    links: int
    size: int
    modified_ns: int
    changed_ns: int

    @property
    def identity(self) -> NativeIdentity:
        return self.device, self.inode


@dataclass(frozen=True)
class ObservedEntry:
    path: RawPath
    stamp: NativeStamp
    byte_digest: bytes | None


@dataclass(frozen=True)
class ObservationEvidence:
    root_path: bytes
    root: NativeStamp
    started_ns: int
    finished_ns: int
    elapsed_ns: int
    attempts: int
    entries: tuple[ObservedEntry, ...]


@dataclass(frozen=True)
class ObservedDirectory:
    snapshot: SnapshotId
    evidence: ObservationEvidence
    resolve: Resolver


@dataclass(frozen=True)
class ObservationRefused:
    code: ObservationCode | Code
    path: RawPath
    attempts: int
    detail: str


class _Refusal(Exception):
    def __init__(self, code: ObservationCode | Code, path: RawPath, detail: str):
        self.code = code
        self.path = path
        super().__init__(detail)


@contextmanager
def _fd(fd: int) -> Iterator[int]:
    try:
        yield fd
    finally:
        os.close(fd)


@contextmanager
def _operation(path: RawPath, *, binding: bool = False) -> Iterator[None]:
    try:
        yield
    except OSError as error:
        code: ObservationCode
        match error.errno:
            case errno.EACCES | errno.EPERM:
                code = "PermissionDenied"
            case (
                errno.EXDEV
                | errno.ENOSYS
                | errno.EOPNOTSUPP
                | errno.ENOTTY
                | errno.EINVAL
            ):
                code = "UnsupportedNative"
            case errno.EAGAIN | errno.ESTALE:
                code = "Unstable"
            case (
                errno.ENOENT
                | errno.ENOTDIR
                | errno.ELOOP
                | native.WRONG_TYPE
                | errno.EISDIR
            ):
                code = "InvalidRoot" if binding else "Unstable"
            case _:
                code = "ObservationIO"
        raise _Refusal(code, path, str(error)) from error


def _runtime() -> None:
    if (
        sys.platform != "linux"
        or platform.machine() != "x86_64"
        or sys.version_info[:3] != (3, 14, 8)
    ):
        raise _Refusal(
            "UnsupportedNative", (), "restricted Linux x86-64 CPython profile"
        )


def _valid_name(name: bytes, max_name: int) -> bool:
    return (
        0 < len(name) <= max_name
        and name not in (b".", b"..")
        and b"/" not in name
        and b"\0" not in name
    )


def _components(root: bytes) -> RawPath:
    if type(root) is not bytes or len(root) > 4095 or not root.startswith(b"/home/"):
        raise _Refusal("InvalidRoot", (), "expected absolute raw path below /home")
    parts = tuple(root[len(b"/home/") :].split(b"/"))
    if len(parts) > 64 or any(not _valid_name(name, 255) for name in parts):
        raise _Refusal("InvalidRoot", (), "invalid root components")
    if _RESERVED.intersection(parts):
        raise _Refusal("Scope", (), "reserved metadata component in root")
    return parts


def _stamp(info: os.stat_result) -> NativeStamp:
    return NativeStamp(
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _same(actual: NativeStamp, expected: NativeStamp, path: RawPath) -> None:
    if actual != expected:
        raise _Refusal("Unstable", path, "native identity or attributes changed")


def _name_max(fd: int, path: RawPath) -> int:
    size = os.fpathconf(fd, "PC_NAME_MAX")
    if not 0 < size <= 255:
        raise _Refusal("UnsupportedNative", path, "unsupported NAME_MAX")
    return size


def _present(fd: int, name: bytes) -> bool:
    try:
        with _fd(native.open_at(fd, name, native.PIN)):
            return True
    except FileNotFoundError:
        return False


def _reserved(names: set[bytes], path: RawPath) -> None:
    if _RESERVED.intersection(names) or _STORE_MARKERS <= names:
        raise _Refusal("Scope", path, "managed metadata within observation scope")


def _check_ancestor(fd: int, protected: frozenset[NativeIdentity]) -> None:
    if _stamp(os.fstat(fd)).identity in protected:
        raise _Refusal("Scope", (), "root overlaps protected private storage")
    _reserved({name for name in _RESERVED | _STORE_MARKERS if _present(fd, name)}, ())


@contextmanager
def _binding(
    parts: RawPath, protected: frozenset[NativeIdentity]
) -> Iterator[tuple[int, ...]]:
    with ExitStack() as cleanup:
        with _operation((), binding=True):
            system = cleanup.enter_context(_fd(os.open(b"/", native.DIRECTORY)))
            _check_ancestor(system, protected)
            home = cleanup.enter_context(
                _fd(
                    native.open_at(system, b"home", native.DIRECTORY, system_mount=True)
                )
            )
            initial = _stamp(os.fstat(home))
            if (
                native.filesystem(home) != native.BTRFS
                or initial.inode != 256
                or not os.fstatvfs(home).f_flag & os.ST_NOATIME
            ):
                raise _Refusal(
                    "UnsupportedNative", (), "expected local noatime Btrfs /home"
                )
            chain = [system, home]
            for name in parts:
                parent = chain[-1]
                _check_ancestor(parent, protected)
                if native.casefold(parent):
                    raise _Refusal(
                        "UnsupportedNative", (), "casefold binding directory"
                    )
                if not _valid_name(name, _name_max(parent, ())):
                    raise _Refusal("InvalidRoot", (), "root component exceeds NAME_MAX")
                child = cleanup.enter_context(
                    _fd(native.open_at(parent, name, native.DIRECTORY))
                )
                if os.fstat(child).st_dev != initial.device:
                    raise _Refusal(
                        "UnsupportedNative", (), "root crosses Btrfs subvolume"
                    )
                chain.append(child)
            _check_ancestor(chain[-1], protected)
        yield tuple(chain)


def _recheck_binding(
    original: tuple[int, ...],
    parts: RawPath,
    protected: frozenset[NativeIdentity],
) -> None:
    try:
        with _binding(parts, protected) as fresh:
            for a, b in zip(original, fresh, strict=True):
                if _stamp(os.fstat(a)).identity != _stamp(os.fstat(b)).identity:
                    raise _Refusal(
                        "Unstable", (), "root or ancestor changed its name binding"
                    )
    except _Refusal as error:
        if error.code == "InvalidRoot":
            raise _Refusal(
                "Unstable", (), "admitted root binding is no longer available"
            ) from error
        raise


class _Detached:
    """Offset index over one unnamed request-local spool."""

    def __init__(self, fd: int, limits: ObservationLimits):
        self.fd: int | None = fd
        self.limits = limits
        self.size = 0
        self.offsets: dict[StoredObjectId, tuple[int, int]] = {}

    def descriptor(self) -> int:
        if self.fd is None:
            raise ValueError("detached observation is closed")
        return self.fd

    def put(self, identity: StoredObjectId, raw: bytes) -> None:
        if identity in self.offsets:
            return
        end = self.size + len(raw)
        if end > self.limits.object_bytes or len(self.offsets) >= self.limits.objects:
            raise _Refusal(Code.RESOURCE_LIMIT, (), "detached object budget")
        start = self.size
        view = memoryview(raw)
        while view:
            written = os.pwrite(self.descriptor(), view, self.size)
            if not written:
                raise OSError(errno.EIO, "detached spool write made no progress")
            self.size += written
            view = view[written:]
        self.offsets[identity] = start, len(raw)

    def get(self, identity: StoredObjectId) -> bytes | None:
        fd = self.descriptor()
        record = self.offsets.get(identity)
        if record is None:
            return None
        offset, length = record
        raw = os.pread(fd, length, offset)
        if len(raw) != length:
            raise ContentError(Code.INTEGRITY, "detached object truncated")
        return raw


@contextmanager
def _spool(system: int, limits: ObservationLimits) -> Iterator[_Detached]:
    with (
        _operation(()),
        _fd(
            native.open_at(system, b"tmp", native.DIRECTORY, system_mount=True)
        ) as temporary,
    ):
        if native.filesystem(temporary) != native.TMPFS:
            raise _Refusal("UnsupportedNative", (), "expected system tmpfs for spool")
        descriptor = os.open(
            b".",
            os.O_TMPFILE | os.O_RDWR | os.O_EXCL | os.O_CLOEXEC,
            0o600,
            dir_fd=temporary,
        )
    with _fd(descriptor):
        detached = _Detached(descriptor, limits)
        try:
            yield detached
        finally:
            detached.fd = None


def _feeds(fd: int, size: int, path: RawPath) -> Iterator[bytes]:
    count = 0
    while data := os.read(fd, min(65536, size - count + 1)):
        count += len(data)
        if count > size:
            raise _Refusal("Unstable", path, "file exceeded its observed length")
        yield data
    if count != size:
        raise _Refusal("Unstable", path, "source ended before its observed length")


def _ignore(data: bytes, path: RawPath) -> None:
    for raw in data.split(b"\n"):
        line = raw.removesuffix(b"\r").rstrip(b" ")
        if b"\0" in line or (line and not line.startswith(b"#")):
            raise _Refusal(
                "IgnoreUnsupported", path, "only blank and comment lines supported"
            )


class _Scan:
    def __init__(
        self,
        detached: _Detached,
        device: int,
        protected: frozenset[NativeIdentity],
    ):
        self.detached = detached
        self.limits = detached.limits
        self.device = device
        self.protected = protected
        self.evidence: dict[RawPath, ObservedEntry] = {}
        self.memberships: dict[RawPath, tuple[bytes, ...]] = {}
        self.directories: set[NativeIdentity] = set()
        self.entries = self.path_bytes = self.source_bytes = 0

    def snapshot(self, root: int) -> SnapshotId:
        tree = self.directory(root, (), False)
        assert tree is not None
        raw = content.encode_snapshot(tree)
        identity = codec.object_id(raw)
        self.detached.put(identity, raw)
        return SnapshotId(identity.raw)

    def recheck(self, root: int) -> None:
        self.entries = self.path_bytes = 0
        self.directory(root, (), True)

    def _checked_stamp(self, fd: int, path: RawPath) -> NativeStamp:
        stamp = _stamp(os.fstat(fd))
        if stamp.device != self.device:
            raise _Refusal("UnsupportedNative", path, "crossed Btrfs subvolume")
        if stamp.identity in self.protected:
            raise _Refusal("Scope", path, "path overlaps protected private storage")
        return stamp

    def _names(self, fd: int, path: RawPath) -> tuple[bytes, ...]:
        max_name = _name_max(fd, path)
        names: set[bytes] = set()
        prefix_bytes = sum(map(len, path))
        with (
            _fd(native.open_at(fd, b".", native.DIRECTORY)) as fresh,
            os.scandir(fresh) as listing,
        ):
            for item in listing:
                name = os.fsencode(item.name)
                if not _valid_name(name, max_name) or name in names:
                    raise _Refusal(
                        "UnsupportedNative", path, "unrepresentable directory listing"
                    )
                self.entries += 1
                self.path_bytes += prefix_bytes + len(name)
                if (
                    len(path) >= self.limits.depth
                    or self.entries > self.limits.entries
                    or self.path_bytes > self.limits.path_bytes
                ):
                    raise _Refusal(Code.RESOURCE_LIMIT, path, "source path budget")
                names.add(name)
        _reserved(names, path)
        return tuple(sorted(names))

    def directory(self, fd: int, path: RawPath, recheck: bool) -> TreeId | None:
        start = self._checked_stamp(fd, path)
        if native.casefold(fd):
            raise _Refusal("UnsupportedNative", path, "casefold directory")
        if recheck:
            _same(start, self.evidence[path].stamp, path)
        else:
            if start.identity in self.directories:
                raise _Refusal("UnsupportedNative", path, "repeated directory identity")
            self.directories.add(start.identity)
            self.evidence[path] = ObservedEntry(path, start, None)

        names = self._names(fd, path)
        if recheck and names != self.memberships[path]:
            raise _Refusal("Unstable", path, "directory membership changed")
        self.memberships[path] = names
        rows: list[content.File | content.Directory] = []
        for name in names:
            if not path and name == b".git":
                continue
            child = self._entry(fd, name, path + (name,), recheck)
            if child is not None:
                rows.append(child)
        _same(self._checked_stamp(fd, path), start, path)
        if recheck:
            return None
        raw = content.encode_tree(rows)
        identity = codec.object_id(raw)
        self.detached.put(identity, raw)
        return TreeId(identity.raw)

    def _entry(
        self, parent: int, name: bytes, path: RawPath, recheck: bool
    ) -> content.File | content.Directory | None:
        with _operation(path), _fd(native.open_at(parent, name, native.PIN)) as pin:
            start = self._checked_stamp(pin, path)
            if recheck:
                _same(start, self.evidence[path].stamp, path)
            if name == _IGNORE and (not stat.S_ISREG(start.mode) or start.size > 65536):
                raise _Refusal(
                    "IgnoreUnsupported", path, "expected bounded regular ignore file"
                )
            row: content.Directory | content.File | None
            if stat.S_ISDIR(start.mode):
                with _fd(native.open_at(pin, b".", native.DIRECTORY)) as directory:
                    _same(self._checked_stamp(directory, path), start, path)
                    target = self.directory(directory, path, recheck)
                row = content.Directory(name, target) if target is not None else None
            else:
                row = self._leaf(parent, name, path, pin, start, recheck)
            _same(self._checked_stamp(pin, path), start, path)
            with _fd(native.open_at(parent, name, native.PIN)) as member:
                _same(self._checked_stamp(member, path), start, path)
            return row

    def _leaf(
        self,
        parent: int,
        name: bytes,
        path: RawPath,
        pin: int,
        start: NativeStamp,
        recheck: bool,
    ) -> content.File | None:
        if not recheck:
            self.source_bytes += start.size
            if self.source_bytes > self.limits.source_bytes:
                raise _Refusal(Code.RESOURCE_LIMIT, path, "source byte budget")

        digest = hashlib.sha256()
        cid: ContentId | None = None
        if stat.S_ISLNK(start.mode):
            target = os.readlink(b"", dir_fd=pin)
            if len(target) != start.size:
                raise _Refusal("Unstable", path, "symlink length changed")
            digest.update(target)
            if not recheck:
                cid = content.write_content(
                    [target], self.detached.put, expected_size=len(target)
                )
            mode = content.Mode.SYMLINK
        elif stat.S_ISREG(start.mode):
            if start.links != 1:
                raise _Refusal("UnsupportedNative", path, "hardlinked regular file")
            mode = (
                content.Mode.EXECUTABLE if start.mode & 0o111 else content.Mode.REGULAR
            )
            with _fd(native.open_at(parent, name, native.REGULAR)) as fd:
                _same(self._checked_stamp(fd, path), start, path)

                def feeds() -> Iterator[bytes]:
                    for block in _feeds(fd, start.size, path):
                        digest.update(block)
                        yield block

                if recheck:
                    for _ in feeds():
                        pass
                else:
                    stream = feeds()
                    if name == _IGNORE:
                        rules = b"".join(stream)
                        _ignore(rules, path)
                        stream = iter([rules])
                    cid = content.write_content(
                        stream, self.detached.put, expected_size=start.size
                    )
                _same(self._checked_stamp(fd, path), start, path)
        else:
            raise _Refusal("UnsupportedNative", path, "special filesystem entry")

        actual = digest.digest()
        if recheck:
            if actual != self.evidence[path].byte_digest:
                raise _Refusal("Unstable", path, "source bytes changed between reads")
            return None
        self.evidence[path] = ObservedEntry(path, start, actual)
        assert cid is not None
        return content.File(name, mode, cid)


@contextmanager
def observe_directory(
    root: bytes,
    *,
    limits: ObservationLimits = DEFAULT_LIMITS,
    _protected: frozenset[NativeIdentity] = frozenset(),
) -> Iterator[ObservedDirectory | ObservationRefused]:
    """Yield verified detached objects for the context's lifetime."""
    attempts = 0
    with ExitStack() as spool_lifetime:
        try:
            _runtime()
            parts = _components(root)
            with _binding(parts, _protected) as chain:
                while True:
                    attempts += 1
                    with ExitStack() as attempt:
                        detached = attempt.enter_context(_spool(chain[0], limits))
                        started_ns, counter = time.time_ns(), time.monotonic_ns()
                        scan = _Scan(detached, os.fstat(chain[-1]).st_dev, _protected)
                        try:
                            with _operation(()):
                                snapshot = scan.snapshot(chain[-1])
                                content.Verifier(detached.get).snapshot(
                                    snapshot, max_file_bytes=0
                                )
                                scan.recheck(chain[-1])
                                _recheck_binding(chain, parts, _protected)
                                _same(
                                    _stamp(os.fstat(chain[-1])),
                                    scan.evidence[()].stamp,
                                    (),
                                )
                        except _Refusal as error:
                            if error.code != "Unstable" or attempts >= _ATTEMPTS:
                                raise
                            _recheck_binding(chain, parts, _protected)
                            continue

                        evidence = ObservationEvidence(
                            root,
                            scan.evidence[()].stamp,
                            started_ns,
                            time.time_ns(),
                            time.monotonic_ns() - counter,
                            attempts,
                            tuple(row for path, row in scan.evidence.items() if path),
                        )
                        spool_lifetime.enter_context(attempt.pop_all())
                        break
            result: ObservedDirectory | ObservationRefused = ObservedDirectory(
                snapshot, evidence, detached.get
            )
        except _Refusal as error:
            result = ObservationRefused(error.code, error.path, attempts, str(error))
        except ContentError as error:
            result = ObservationRefused(error.code, (), attempts, str(error))
        yield result
