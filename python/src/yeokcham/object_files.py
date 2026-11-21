"""Private immutable files and process locks for the restricted Linux store."""

import _sqlite3
import errno
import hashlib
import os
import platform
import re
import sqlite3
import stat
import sys
import time
from collections.abc import Callable, Iterable, Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Literal

from . import codec, content
from .errors import Code, ContentError, require
from .identities import ContentId, StoredObjectId, TreeId

StorageCode = Literal[
    "InvalidStore",
    "UnsupportedRuntime",
    "IdentityMismatch",
    "Busy",
    "Stale",
    "RequestMismatch",
    "Exhausted",
    "UncertainCommit",
    "StorageFull",
    "StorageIO",
]


class StoreError(Exception):
    def __init__(self, code: StorageCode, message: str):
        self.code = code
        super().__init__(code + ": " + message)


def io_error(error: OSError) -> StoreError:
    return StoreError(
        "StorageFull" if error.errno in (errno.ENOSPC, errno.EDQUOT) else "StorageIO",
        str(error),
    )


@contextmanager
def cleanup_preserving_error(cleanup: Callable[[], None]) -> Iterator[None]:
    try:
        yield
    except BaseException as primary:
        try:
            cleanup()
        except (OSError, sqlite3.Error, ContentError, StoreError) as secondary:
            primary.add_note(f"Cleanup failed: {secondary}")
        raise
    else:
        cleanup()


def check_runtime(path: Path) -> None:
    if (
        sys.version_info[:3] != (3, 14, 8)
        or sys.platform != "linux"
        or platform.machine() != "x86_64"
    ):
        raise StoreError(
            "UnsupportedRuntime", "only qualified Linux CPython3.14.8/x86_64 profile"
        )
    c = sqlite3.connect(":memory:", autocommit=True)
    try:
        source = c.execute("select sqlite_source_id()").fetchone()[0]
        options = "\n".join(sorted(r[0] for r in c.execute("pragma compile_options")))
        c.execute("create table probe(n integer) strict")
    finally:
        c.close()
    library = next(
        (
            Path(line.split()[-1])
            for line in Path("/proc/self/maps").read_text().splitlines()
            if "/libsqlite3.so." in line
        ),
        None,
    )
    if (
        sqlite3.sqlite_version != "3.54.0"
        or source
        != "2026-10-09 15:46:58 be8d059e9a49089ab2dce5ed26dd87aaf598fdc5fbe0b107c0dd758464bcalt1"
        or hashlib.sha256(options.encode()).hexdigest()
        != "b21634e22f921a220f8494a0e551605763d8f3d33e582075f574a42d718a152a"
        or hashlib.sha256(Path(_sqlite3.__file__).read_bytes()).hexdigest()
        != "ed9dc2218de28a5725a171a18b2ae31c9065486bd54361b6cdf598d36682760a"
        or library is None
        or hashlib.sha256(library.read_bytes()).hexdigest()
        != "758544266d5060aff683efcc94ee9abf2625c6ff9d02b70bb6d1296e0ee9128f"
    ):
        raise StoreError(
            "UnsupportedRuntime", "SQLite binary/source/options profile mismatch"
        )
    target = path if path.exists() else path.parent
    matches = []
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        fields, tail = line.split(" - ", 1)
        mount = Path(
            re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), fields.split()[4])
        )
        if target == mount or target.is_relative_to(mount):
            matches.append((len(mount.parts), tail.split()[0]))
    if not matches or max(matches)[1] != "btrfs":
        raise StoreError(
            "UnsupportedRuntime",
            "only qualified local Btrfs filesystem; tmpfs/network excluded",
        )


def checked_path(path: Path) -> Path:
    if not isinstance(path, Path) or not path.is_absolute() or ".." in path.parts:
        raise StoreError("InvalidStore", "absolute nontraversing store path required")
    if any(p in (".yeokcham", ".yeokcham-v2") for p in path.parts):
        raise StoreError("InvalidStore", "existing VCS store namespace excluded")
    for ancestor in reversed((path, *path.parents)):
        if ancestor.is_symlink():
            raise StoreError("InvalidStore", "symlink store path component")
    return path


def private_stat(fd: int, *, directory: bool) -> None:
    info = os.fstat(fd)
    if info.st_uid != os.geteuid() or (
        not stat.S_ISDIR(info.st_mode) if directory else not stat.S_ISREG(info.st_mode)
    ):
        raise StoreError("InvalidStore", "foreign or wrong-kind private store entry")
    if stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600):
        raise StoreError("InvalidStore", "private store permissions mismatch")


def validate_object(identity: StoredObjectId, raw: bytes) -> None:
    env = codec.unpack(raw, identity)
    value = codec.decode(env.payload)
    require(
        codec.encode(value) == env.payload,
        Code.NONCANONICAL,
        "canonical object payload",
    )
    if env.kind == 1:
        content.Verifier(lambda oid: raw if oid == identity else None).content(
            ContentId(identity.raw), max_bytes=0
        )
    elif env.kind == 13:
        schema, data = content.array(value, 2)
        content.version(schema)
        require(
            type(data) is bytes and 0 < len(data) <= 131072,
            Code.INVALID_CONTENT,
            "chunk shape/size",
        )
    elif env.kind == 3:
        schema, root = content.array(value, 2)
        content.version(schema)
        content.reference(root)
    elif env.kind == 2:
        schema, rows = content.array(value, 2)
        content.version(schema)
        require(type(rows) is list, Code.INVALID_CONTENT, "tree entries")
        assert isinstance(rows, list)
        entries: list[content.File | content.Directory] = []
        for row in rows:
            require(
                type(row) is list and len(row) in (3, 4),
                Code.INVALID_CONTENT,
                "tree row",
            )
            assert isinstance(row, list)
            tag, name = row[:2]
            require(
                type(tag) is int and type(name) is bytes,
                Code.INVALID_CONTENT,
                "tree tag/name",
            )
            assert isinstance(name, bytes)
            if tag == 1 and len(row) == 3:
                entries.append(
                    content.Directory(name, TreeId(content.reference(row[2])))
                )
            elif tag == 0 and len(row) == 4:
                mode = row[2]
                require(
                    type(mode) is int and mode in (0, 1, 2),
                    Code.INVALID_CONTENT,
                    "tree mode",
                )
                assert type(mode) is int
                entries.append(
                    content.File(
                        name, content.Mode(mode), ContentId(content.reference(row[3]))
                    )
                )
            else:
                raise ContentError(Code.INVALID_CONTENT, "tree tag/arity")
        require(
            content.encode_tree(entries) == raw,
            Code.NONCANONICAL,
            "tree canonical order",
        )
    else:
        fields = content.array(value, 9)
        content.version(fields[0])
        require(
            all(type(v) is int for v in fields[1:7]),
            Code.INVALID_CONTENT,
            "manifest scalars",
        )
        total = fields[1]
        require(
            type(total) is int and 65536 < total <= 2**62 - 1,
            Code.NONCANONICAL,
            "manifest length",
        )
        require(
            fields[2:7] == [1, 64, 16384, 65536, 131072],
            Code.UNSUPPORTED,
            "manifest profile",
        )
        content.reference(fields[7])
        refs = fields[8]
        require(
            type(refs) is list and bool(refs),
            Code.INVALID_CONTENT,
            "manifest references",
        )
        assert isinstance(refs, list)
        length = 0
        for ref in refs:
            oid, size = content.array(ref, 2)
            content.reference(oid)
            require(
                type(size) is int and 0 < size <= 131072,
                Code.INVALID_CONTENT,
                "manifest chunk size",
            )
            assert type(size) is int
            length += size
        require(length == total, Code.INVALID_CONTENT, "manifest declared size")


class ObjectFiles:
    def __init__(self, path: Path, event: Callable[[str], None], timeout: float):
        self.path = checked_path(path)
        self.event = event
        self.timeout = timeout
        self.root = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.objects = self.locks = -1
        try:
            private_stat(self.root, directory=True)
            self.objects = os.open(
                "objects",
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=self.root,
            )
            self.locks = os.open(
                "locks", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.root
            )
            private_stat(self.objects, directory=True)
            private_stat(self.locks, directory=True)
            self.binding = os.fstat(self.root)
        except BaseException:
            self.close()
            raise

    def close(self) -> None:
        for name in ("locks", "objects", "root"):
            fd = getattr(self, name, -1)
            if fd >= 0:
                os.close(fd)
                setattr(self, name, -1)

    def check_binding(self) -> None:
        checked_path(self.path)
        if self.root < 0:
            raise StoreError("InvalidStore", "closed store")
        current = self.path.stat(follow_symlinks=False)
        if (current.st_dev, current.st_ino) != (
            self.binding.st_dev,
            self.binding.st_ino,
        ):
            raise StoreError("InvalidStore", "store directory replaced")
        for name, fd in [("objects", self.objects), ("locks", self.locks)]:
            current = os.stat(name, dir_fd=self.root, follow_symlinks=False)
            opened = os.fstat(fd)
            if (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
                raise StoreError("InvalidStore", "store child directory replaced")

    @contextmanager
    def locked(self, name: str, *, exclusive: bool = False) -> Iterator[None]:
        import fcntl

        self.check_binding()
        flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK
        if name.startswith("workspace-"):
            flags |= os.O_CREAT
        fd = os.open(name, flags, 0o600, dir_fd=self.locks)
        with cleanup_preserving_error(lambda: os.close(fd)):
            private_stat(fd, directory=False)
            os.fsync(fd)
            os.fsync(self.locks)
            deadline = time.monotonic() + self.timeout
            while True:
                try:
                    fcntl.flock(
                        fd,
                        (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB,
                    )
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise StoreError("Busy", "process lock deadline") from None
                    time.sleep(min(0.01, max(0, deadline - time.monotonic())))
            yield

    def _open_canonical(self, identity: StoredObjectId) -> int | None:
        if type(identity) is not StoredObjectId:
            raise TypeError("object access requires StoredObjectId")
        try:
            return os.open(
                identity.hex(),
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=self.objects,
            )
        except FileNotFoundError:
            return None
        except OSError as error:
            if error.errno == errno.ELOOP:
                raise ContentError(Code.INTEGRITY, "object symlink") from error
            raise io_error(error) from error

    def _read_verified(self, fd: int, identity: StoredObjectId) -> bytes:
        info = os.fstat(fd)
        require(
            stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid(),
            Code.INTEGRITY,
            "object type/owner",
        )
        require(
            info.st_size <= codec.MAX_OBJECT, Code.RESOURCE_LIMIT, "object file size"
        )
        with os.fdopen(fd, "rb", closefd=False) as source:
            raw = source.read(info.st_size + 1)
        require(len(raw) == info.st_size, Code.INTEGRITY, "object size changed")
        validate_object(identity, raw)
        return raw

    def read(self, identity: StoredObjectId) -> bytes | None:
        fd = self._open_canonical(identity)
        if fd is None:
            return None
        with cleanup_preserving_error(lambda: os.close(fd)):
            return self._read_verified(fd, identity)

    def put(
        self, identity: StoredObjectId, length: int, feeds: Iterable[bytes]
    ) -> None:
        if type(identity) is not StoredObjectId:
            raise TypeError("publication requires StoredObjectId")
        require(
            type(length) is int and 57 <= length <= codec.MAX_OBJECT,
            Code.RESOURCE_LIMIT,
            "object declared length",
        )
        name = ".stage-" + os.urandom(16).hex()
        fd = os.open(
            name,
            os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW,
            0o600,
            dir_fd=self.objects,
        )
        with cleanup_preserving_error(lambda: os.close(fd)):
            opened = os.fstat(fd)
            with cleanup_preserving_error(lambda: self._remove_stage(name, opened)):
                self._publish_stage(fd, name, identity, length, feeds)

    def _remove_stage(self, name: str, opened: os.stat_result) -> None:
        current = os.stat(name, dir_fd=self.objects, follow_symlinks=False)
        require(
            (current.st_dev, current.st_ino) == (opened.st_dev, opened.st_ino),
            Code.INTEGRITY,
            "stage name no longer identifies our object",
        )
        os.unlink(name, dir_fd=self.objects)
        os.fsync(self.objects)

    def _publish_stage(
        self,
        fd: int,
        name: str,
        identity: StoredObjectId,
        length: int,
        feeds: Iterable[bytes],
    ) -> None:
        self.event("temp-created")
        count = 0
        for feed in feeds:
            if type(feed) is not bytes:
                raise TypeError("object stream requires bytes")
            count += len(feed)
            require(
                count <= length,
                Code.INVALID_ENCODING,
                "declared object length exceeded",
            )
            view = memoryview(feed)
            while view:
                written = os.write(fd, view)
                if not written:
                    raise OSError(errno.EIO, "zero object write")
                view = view[written:]
        require(count == length, Code.INVALID_ENCODING, "truncated object stream")
        self.event("temp-written")
        os.lseek(fd, 0, os.SEEK_SET)
        with os.fdopen(fd, "rb", closefd=False) as source:
            raw = source.read(length + 1)
        validate_object(identity, raw)
        os.fchmod(fd, 0o400)
        os.fsync(fd)
        self.event("file-synced")
        try:
            os.link(
                name,
                identity.hex(),
                src_dir_fd=self.objects,
                dst_dir_fd=self.objects,
                follow_symlinks=False,
            )
        except FileExistsError:
            existing_fd = self._open_canonical(identity)
            require(
                existing_fd is not None, Code.UNAVAILABLE, "existing object disappeared"
            )
            assert existing_fd is not None
            with cleanup_preserving_error(lambda: os.close(existing_fd)):
                require(
                    self._read_verified(existing_fd, identity) == raw,
                    Code.INTEGRITY,
                    "existing immutable bytes differ",
                )
                os.fsync(existing_fd)
        else:
            self.event("object-linked")
        os.fsync(self.objects)
        self.event("object-dir-synced")
