"""Restricted private persistence. No working-tree, public-history or deletion API."""

import hashlib
import os
import sqlite3
import stat
from collections.abc import Callable, Iterable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from types import TracebackType
from typing import Literal, Self

from . import codec, content
from .errors import Code, ContentError, require
from .identities import CaptureId, RepositoryId, SnapshotId, StoredObjectId, WorkspaceId
from .object_files import (
    ObjectFiles,
    StorageCode,
    StoreError,
    check_runtime,
    checked_path,
    cleanup_preserving_error,
    io_error,
    private_stat,
)
from .private_schema import (
    APPLICATION_ID,
    SCHEMA_VERSION,
    expected_schema,
    install,
    schema_rows,
)

__all__ = [
    "Capture",
    "CaptureResult",
    "PrivateStore",
    "RecoveryInfo",
    "RequestInfo",
    "RootReport",
    "StoreError",
    "WorkspaceState",
    "allocate_sequence",
]
MAX_SEQUENCE = 2**63 - 1
MARKER = b"YEOKCHAM-PY-PRIVATE\n1\n"
Resolver = Callable[[StoredObjectId], bytes | None]


@dataclass(frozen=True)
class WorkspaceState:
    workspace: WorkspaceId
    version: int
    cursor: CaptureId | None
    next_sequence: int

    def __post_init__(self) -> None:
        if (
            type(self.workspace) is not WorkspaceId
            or type(self.version) is not int
            or not 0 <= self.version <= MAX_SEQUENCE
            or type(self.next_sequence) is not int
            or self.next_sequence != self.version
        ):
            raise TypeError("typed workspace/counter required")
        if self.cursor is not None and (
            type(self.cursor) is not CaptureId
            or self.cursor.workspace != self.workspace
        ):
            raise TypeError("cursor belongs to this workspace")


@dataclass(frozen=True)
class Capture:
    identity: CaptureId
    parent: CaptureId | None
    snapshot: SnapshotId


@dataclass(frozen=True)
class CaptureResult:
    capture: CaptureId
    snapshot: SnapshotId
    version: int
    changed: bool


@dataclass(frozen=True)
class RequestInfo:
    state: str
    snapshot: SnapshotId
    result: CaptureResult | None


@dataclass(frozen=True)
class RecoveryInfo:
    request: RequestInfo
    digest: bytes
    expected: WorkspaceState
    eligible: bool | None
    closure: Literal["verified", "missing", "invalid", "unverified"]
    error: Code | StorageCode | None


@dataclass(frozen=True)
class _Request:
    info: RequestInfo
    digest: bytes
    expected: WorkspaceState
    eligible: bool | None


@dataclass(frozen=True)
class RootReport:
    completed: int
    pending: int
    incomplete_pending: int


def allocate_sequence(next_sequence: int) -> tuple[int, int]:
    if type(next_sequence) is not int or not 0 <= next_sequence <= MAX_SEQUENCE:
        raise ValueError("invalid sequence")
    if next_sequence == MAX_SEQUENCE:
        raise StoreError("Exhausted", "capture sequence/version exhausted")
    return next_sequence, next_sequence + 1


def _workspace_id(workspace: WorkspaceId) -> None:
    if type(workspace) is not WorkspaceId:
        raise TypeError("WorkspaceId required")


def _key(key: bytes) -> None:
    if type(key) is not bytes or not 1 <= len(key) <= 128:
        raise ValueError("request key requires1..128 bytes")


def _arguments(
    workspace: WorkspaceId, version: int, parent: int | None, snapshot: SnapshotId
) -> bytes:
    return hashlib.sha256(
        b"yeokcham/private-request/m1b1\0"
        + codec.encode([1, workspace.raw, version, parent, snapshot.raw])
    ).digest()


def _rollback_after_error(c: sqlite3.Connection, primary: BaseException) -> None:
    if c.in_transaction:
        try:
            c.execute("ROLLBACK")
        except (sqlite3.Error, OSError) as secondary:
            primary.add_note(f"ROLLBACK failed: {secondary}")


def _check_history(c: sqlite3.Connection) -> None:
    """Check semantic links that FKs cannot express in the frozen schema."""
    bad = c.execute(
        """
        SELECT 1 FROM capture AS h
        JOIN workspace AS w ON w.id=h.workspace
        JOIN request AS p ON p.workspace=h.workspace AND p.key=h.request_key
        WHERE h.sequence>=w.next_seq
           OR h.parent IS NOT CASE WHEN h.sequence>0 THEN h.sequence-1 END
           OR p.changed IS NOT 1 OR p.result_sequence IS NOT h.sequence
        UNION ALL
        SELECT 1 FROM request AS r
        JOIN workspace AS w ON w.id=r.workspace
        LEFT JOIN capture AS h
          ON h.workspace=r.workspace AND h.sequence=r.result_sequence
        WHERE r.expected_version>w.version
           OR r.parent IS NOT CASE WHEN r.expected_version>0 THEN r.expected_version-1 END
           OR (r.state='completed' AND (
               r.snapshot IS NOT h.snapshot OR r.result_version IS NOT h.sequence+1
               OR (r.changed=1 AND (
                   h.request_key IS NOT r.key OR h.parent IS NOT r.parent
                   OR h.sequence IS NOT r.expected_version
               ))
               OR (r.changed=0 AND h.sequence IS NOT r.parent)
           ))
        LIMIT 1
        """
    ).fetchone()
    if bad is not None:
        raise StoreError("InvalidStore", "invalid capture ancestry or request result")


@contextmanager
def _errors() -> Iterator[None]:
    try:
        yield
    except OSError as error:
        raise io_error(error) from error
    except sqlite3.Error as error:
        base = getattr(error, "sqlite_errorcode", 0) & 255
        if base in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED):
            raise StoreError("Busy", "bounded SQLite lock wait") from error
        if base == sqlite3.SQLITE_FULL:
            raise StoreError("StorageFull", str(error)) from error
        if base == sqlite3.SQLITE_IOERR:
            raise StoreError("StorageIO", str(error)) from error
        raise StoreError("InvalidStore", str(error)) from error


class PrivateStore:
    def __init__(self, path: Path, repository: RepositoryId, timeout: float = 1):
        if type(repository) is not RepositoryId:
            raise TypeError("RepositoryId required")
        if type(timeout) not in (int, float) or not 0 <= timeout <= 5:
            raise ValueError("lock timeout0..5 seconds")
        self.path = checked_path(path)
        check_runtime(path)
        self.repository = repository
        self.timeout = timeout
        self.fault: Callable[[str], None] | None = None
        self.files = ObjectFiles(path, self._event, timeout)
        self.database_binding: tuple[int, int] | None = None
        try:
            self._verify_opened()
        except BaseException:
            self.close()
            raise

    def _event(self, event: str) -> None:
        if self.fault is not None:
            self.fault(event)

    @classmethod
    def initialize(
        cls, path: Path, repository: RepositoryId, *, timeout: float = 1
    ) -> Self:
        checked_path(path)
        check_runtime(path)
        if type(timeout) not in (int, float) or not 0 <= timeout <= 5:
            raise ValueError("lock timeout0..5 seconds")
        if type(repository) is not RepositoryId:
            raise TypeError("RepositoryId required")
        with _errors():
            os.mkdir(path, 0o700)
            parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                root = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            except BaseException:
                os.close(parent)
                raise
            try:
                for name in ("objects", "locks"):
                    os.mkdir(name, 0o700, dir_fd=root)
                for name in ("publication", "metadata-access"):
                    lock = os.open(
                        path / "locks" / name, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600
                    )
                    try:
                        os.fsync(lock)
                    finally:
                        os.close(lock)
                for name in ("objects", "locks"):
                    fd = os.open(
                        name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root
                    )
                    try:
                        os.fsync(fd)
                    finally:
                        os.close(fd)
                c = sqlite3.connect(
                    (path / "metadata.sqlite3").as_uri() + "?mode=rwc&vfs=unix",
                    uri=True,
                    autocommit=True,
                )
                try:
                    os.chmod(path / "metadata.sqlite3", 0o600)
                    c.execute("PRAGMA journal_mode=DELETE")
                    c.execute("PRAGMA synchronous=EXTRA")
                    c.execute("PRAGMA foreign_keys=ON")
                    c.execute("BEGIN IMMEDIATE")
                    install(c)
                    c.execute(f"PRAGMA application_id={APPLICATION_ID}")
                    c.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
                    c.execute("INSERT INTO repository VALUES(1,?,1)", (repository.raw,))
                    c.execute("COMMIT")
                except BaseException as error:
                    _rollback_after_error(c, error)
                    raise
                finally:
                    c.close()
                db = os.open(
                    "metadata.sqlite3", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=root
                )
                try:
                    os.fsync(db)
                finally:
                    os.close(db)
                os.fsync(root)
                os.fsync(parent)
                marker = os.open(
                    "FORMAT",
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    0o400,
                    dir_fd=root,
                )
                try:
                    raw = MARKER + repository.hex().encode() + b"\n"
                    if os.write(marker, raw) != len(raw):
                        raise OSError("short format marker write")
                    os.fsync(marker)
                finally:
                    os.close(marker)
                os.fsync(root)
                os.fsync(parent)
            finally:
                os.close(root)
                os.close(parent)
        return cls.open(path, repository, timeout=timeout)

    @classmethod
    def open(cls, path: Path, repository: RepositoryId, *, timeout: float = 1) -> Self:
        with _errors():
            return cls(path, repository, timeout)

    def _verify_opened(self) -> None:
        with _errors():
            try:
                fd = os.open(
                    "FORMAT",
                    os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                    dir_fd=self.files.root,
                )
            except FileNotFoundError as error:
                raise StoreError("InvalidStore", "missing FORMAT marker") from error
            try:
                if not stat.S_ISREG(os.fstat(fd).st_mode):
                    raise StoreError("InvalidStore", "FORMAT marker must be regular")
                marker = os.read(fd, len(MARKER) + 66)
            finally:
                os.close(fd)
            raw_identity = marker[len(MARKER) : -1]
            if (
                not marker.startswith(MARKER)
                or not marker.endswith(b"\n")
                or len(raw_identity) != 64
                or any(byte not in b"0123456789abcdef" for byte in raw_identity)
            ):
                raise StoreError("InvalidStore", "invalid FORMAT marker")
            if raw_identity != self.repository.hex().encode():
                raise StoreError("IdentityMismatch", "FORMAT repository mismatch")
            for name in ("publication", "metadata-access"):
                gate = os.open(name, os.O_RDWR | os.O_NOFOLLOW, dir_fd=self.files.locks)
                try:
                    private_stat(gate, directory=False)
                finally:
                    os.close(gate)
            with (
                self.files.locked("publication"),
                self.files.locked("metadata-access", exclusive=True),
            ):
                self._admit_database()
                with self._connected() as c:
                    if (
                        c.execute("PRAGMA integrity_check").fetchone() != ("ok",)
                        or c.execute("PRAGMA foreign_key_check").fetchone() is not None
                    ):
                        raise StoreError(
                            "InvalidStore",
                            "metadata integrity/root ownership check failed",
                        )
                    _check_history(c)
                    marker_fd = os.open(
                        "FORMAT", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.files.root
                    )
                    parent_fd = -1
                    try:
                        parent_fd = os.open(
                            self.path.parent,
                            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        )
                        os.fsync(marker_fd)
                        os.fsync(self.files.root)
                        os.fsync(parent_fd)
                    finally:
                        os.close(marker_fd)
                        if parent_fd >= 0:
                            os.close(parent_fd)

    def close(self) -> None:
        self.files.close()

    def __enter__(self) -> Self:
        return self

    def __exit__(
        self,
        kind: type[BaseException] | None,
        value: BaseException | None,
        trace: TracebackType | None,
    ) -> None:
        self.close()

    @contextmanager
    def _connection(self) -> Iterator[sqlite3.Connection]:
        with (
            self.files.locked("metadata-access"),
            self._connected() as c,
        ):
            yield c

    def _admit_database(self) -> None:
        """Raw header access requires the exclusive metadata-admission lease."""
        self.files.check_binding()
        fd = os.open(
            "metadata.sqlite3", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=self.files.root
        )
        try:
            private_stat(fd, directory=False)
            info = os.fstat(fd)
            header = os.read(fd, 100)
            if (
                info.st_nlink != 1
                or len(header) != 100
                or header[:16] != b"SQLite format 3\0"
                or int.from_bytes(header[68:72], "big") != APPLICATION_ID
                or int.from_bytes(header[60:64], "big") != SCHEMA_VERSION
            ):
                raise StoreError(
                    "InvalidStore", "unknown database header/application/version"
                )
            binding = (info.st_dev, info.st_ino)
            if self.database_binding is not None and self.database_binding != binding:
                raise StoreError("InvalidStore", "database replaced")
            self.database_binding = binding
        finally:
            os.close(fd)

    @contextmanager
    def _connected(self) -> Iterator[sqlite3.Connection]:
        self.files.check_binding()
        info = os.stat(
            "metadata.sqlite3", dir_fd=self.files.root, follow_symlinks=False
        )
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_nlink != 1
            or self.database_binding != (info.st_dev, info.st_ino)
        ):
            raise StoreError("InvalidStore", "database binding changed or not admitted")
        c = sqlite3.connect(
            (self.path / "metadata.sqlite3").as_uri() + "?mode=rw&vfs=unix",
            uri=True,
            autocommit=True,
            timeout=self.timeout,
        )
        with cleanup_preserving_error(c.close):
            if c.execute("PRAGMA application_id").fetchone() != (
                APPLICATION_ID,
            ) or c.execute("PRAGMA user_version").fetchone() != (SCHEMA_VERSION,):
                raise StoreError("InvalidStore", "database application/version changed")
            if schema_rows(c) != expected_schema():
                raise StoreError("InvalidStore", "unknown exact schema")
            rows = c.execute(
                "SELECT singleton,identity,format FROM repository"
            ).fetchall()
            if rows != [(1, self.repository.raw, 1)]:
                raise StoreError("IdentityMismatch", "database repository binding")
            if c.execute("PRAGMA journal_mode").fetchone() != ("delete",):
                raise StoreError("InvalidStore", "non-DELETE database")
            c.execute("PRAGMA synchronous=EXTRA")
            c.execute("PRAGMA foreign_keys=ON")
            if (
                c.execute("PRAGMA synchronous").fetchone() != (3,)
                or c.execute("PRAGMA foreign_keys").fetchone() != (1,)
                or not c.autocommit
                or c.in_transaction
            ):
                raise StoreError("UnsupportedRuntime", "transaction modes unavailable")
            try:
                yield c
            except BaseException as error:
                _rollback_after_error(c, error)
                raise
            if c.in_transaction:
                c.execute("ROLLBACK")

    @contextmanager
    def _transaction(self, c: sqlite3.Connection, event: str) -> Iterator[None]:
        c.execute("BEGIN IMMEDIATE")
        try:
            yield
            self._event(event + "-before-commit")
        except BaseException as error:
            _rollback_after_error(c, error)
            raise
        try:
            c.execute("COMMIT")
            self._event(event + "-committed")
        except (sqlite3.Error, OSError) as error:
            uncertain = StoreError(
                "UncertainCommit", "reopen and resolve original request identity"
            )
            _rollback_after_error(c, uncertain)
            raise uncertain from error

    def _state(self, c: sqlite3.Connection, workspace: WorkspaceId) -> WorkspaceState:
        row = c.execute(
            "SELECT version,cursor,next_seq FROM workspace WHERE id=?", (workspace.raw,)
        ).fetchone()
        require(row is not None, Code.UNAVAILABLE, "missing workspace")
        assert row is not None
        return WorkspaceState(
            workspace,
            row[0],
            None if row[1] is None else CaptureId(workspace, row[1]),
            row[2],
        )

    def workspace(self, workspace: WorkspaceId) -> WorkspaceState:
        _workspace_id(workspace)
        with _errors(), self.files.locked("publication"), self._connection() as c:
            return self._state(c, workspace)

    def register_workspace(self, workspace: WorkspaceId) -> WorkspaceState:
        _workspace_id(workspace)
        with (
            _errors(),
            self.files.locked("workspace-" + workspace.hex(), exclusive=True),
            self.files.locked("publication"),
            self._connection() as c,
        ):
            with self._transaction(c, "workspace"):
                c.execute(
                    "INSERT OR IGNORE INTO workspace VALUES(?,NULL,0,0)",
                    (workspace.raw,),
                )
            return self._state(c, workspace)

    def put_object(self, identity: StoredObjectId, raw: bytes) -> None:
        if type(raw) is not bytes:
            raise TypeError("object bytes required")
        self.put_stream(
            identity, len(raw), (raw[i : i + 65536] for i in range(0, len(raw), 65536))
        )

    def put_stream(
        self, identity: StoredObjectId, length: int, feeds: Iterable[bytes]
    ) -> None:
        with _errors(), self.files.locked("publication"):
            self.files.put(identity, length, feeds)

    def read_object(self, identity: StoredObjectId) -> bytes:
        with _errors(), self.files.locked("publication"):
            raw = self.files.read(identity)
            require(raw is not None, Code.UNAVAILABLE, "missing object")
            assert raw is not None
            return raw

    def _lookup(
        self,
        c: sqlite3.Connection,
        workspace: WorkspaceId,
        key: bytes,
        digest: bytes | None = None,
    ) -> _Request | None:
        row = c.execute(
            """
            SELECT r.arguments,r.snapshot,r.expected_version,r.parent,r.state,
                   r.result_sequence,r.result_version,r.changed,
                   o.snapshot,w.version,w.cursor
            FROM request AS r
            LEFT JOIN root AS o ON o.workspace=r.workspace AND o.key=r.key
            LEFT JOIN workspace AS w ON w.id=r.workspace
            WHERE r.workspace=? AND r.key=?
            """,
            (workspace.raw, key),
        ).fetchone()
        if row is None:
            return None
        (
            args,
            raw,
            version,
            parent,
            state,
            sequence,
            result_version,
            changed,
            root,
            current,
            cursor,
        ) = row
        if root != raw or current is None:
            raise StoreError(
                "InvalidStore", "request lacks its exact root or workspace"
            )
        snap = SnapshotId(raw)
        if args != _arguments(workspace, version, parent, snap):
            raise StoreError("InvalidStore", "request argument digest corrupt")
        if digest is not None and args != digest:
            raise StoreError(
                "RequestMismatch", "same key has different frozen arguments"
            )
        info = RequestInfo(
            state,
            snap,
            None
            if state == "pending"
            else CaptureResult(
                CaptureId(workspace, sequence), snap, result_version, bool(changed)
            ),
        )
        expected = WorkspaceState(
            workspace,
            version,
            None if parent is None else CaptureId(workspace, parent),
            version,
        )
        return _Request(
            info,
            args,
            expected,
            (version == current and parent == cursor) if state == "pending" else None,
        )

    def lookup_request(self, workspace: WorkspaceId, key: bytes) -> RequestInfo | None:
        _workspace_id(workspace)
        _key(key)
        with _errors(), self.files.locked("publication"), self._connection() as c:
            request = self._lookup(c, workspace, key)
            return None if request is None else request.info

    def inspect_request(
        self, workspace: WorkspaceId, key: bytes
    ) -> RecoveryInfo | None:
        """Read recovered SQL authority and independently verify its exact closure."""
        _workspace_id(workspace)
        _key(key)
        with _errors(), self.files.locked("publication"):
            with self._connection() as c:
                request = self._lookup(c, workspace, key)
            if request is None:
                return None
            closure: Literal["verified", "missing", "invalid", "unverified"] = (
                "verified"
            )
            failure: Code | StorageCode | None = None
            try:
                content.Verifier(self.files.read).snapshot(
                    request.info.snapshot, max_file_bytes=0
                )
            except ContentError as error:
                failure = error.code
                if failure == Code.UNAVAILABLE:
                    closure = "missing"
                elif failure == Code.RESOURCE_LIMIT:
                    closure = "unverified"
                else:
                    closure = "invalid"
            except StoreError as error:
                if error.code not in ("StorageIO", "StorageFull"):
                    raise
                closure, failure = "unverified", error.code
            except OSError as error:
                closure, failure = "unverified", io_error(error).code
            return RecoveryInfo(
                request.info,
                request.digest,
                request.expected,
                request.eligible,
                closure,
                failure,
            )

    def append_capture(
        self,
        workspace: WorkspaceId,
        snapshot: SnapshotId,
        resolver: Resolver,
        *,
        expected: WorkspaceState,
        key: bytes,
    ) -> CaptureResult:
        _workspace_id(workspace)
        _key(key)
        if (
            type(snapshot) is not SnapshotId
            or type(expected) is not WorkspaceState
            or expected.workspace != workspace
        ):
            raise TypeError("exact snapshot/workspace expectation required")
        parent = None if expected.cursor is None else expected.cursor.sequence
        digest = _arguments(workspace, expected.version, parent, snapshot)
        with (
            _errors(),
            self.files.locked("workspace-" + workspace.hex(), exclusive=True),
            self.files.locked("publication"),
        ):
            with self._connection() as c:
                prior = self._lookup(c, workspace, key, digest)
                if (prior is None or prior.info.result is None) and self._state(
                    c, workspace
                ) != expected:
                    raise StoreError("Stale", "workspace CAS changed")
                if prior is None:
                    with self._transaction(c, "request"):
                        if self._state(c, workspace) != expected:
                            raise StoreError("Stale", "workspace CAS changed")
                        c.execute(
                            "INSERT INTO request VALUES(?,?,?,?,?,?,'pending',NULL,NULL,NULL)",
                            (
                                workspace.raw,
                                key,
                                digest,
                                snapshot.raw,
                                expected.version,
                                parent,
                            ),
                        )
                        self._event("request-inserted")
                        c.execute(
                            "INSERT INTO root VALUES(?,?,?)",
                            (workspace.raw, key, snapshot.raw),
                        )
                        self._event("root-inserted")
            if prior is not None:
                # SQLite may expose the row after journal unlink even if its
                # directory sync failed. Seal that boundary before using it.
                try:
                    os.fsync(self.files.root)
                except OSError as error:
                    raise StoreError(
                        "UncertainCommit", "could not sync recovered request directory"
                    ) from error
                if prior.info.result is not None:
                    content.Verifier(self.files.read).snapshot(
                        prior.info.snapshot, max_file_bytes=0
                    )
                    return prior.info.result
            published: set[StoredObjectId] = set()

            def incoming(oid: StoredObjectId) -> bytes | None:
                if oid in published:
                    return self.files.read(oid)
                raw = resolver(oid)
                if raw is None:
                    raw = self.files.read(oid)
                if raw is not None:
                    self.files.put(
                        oid,
                        len(raw),
                        (raw[i : i + 65536] for i in range(0, len(raw), 65536)),
                    )
                    published.add(oid)
                return raw

            content.Verifier(incoming).snapshot(snapshot, max_file_bytes=0)
            content.Verifier(self.files.read).snapshot(snapshot, max_file_bytes=0)
            self._event("objects-durable")
            self.files.check_binding()
            with self._connection() as c:
                with self._transaction(c, "capture"):
                    pending = self._lookup(c, workspace, key, digest)
                    if pending is None or pending.info.state != "pending":
                        raise StoreError(
                            "InvalidStore", "missing pending capture intent"
                        )
                    current = self._state(c, workspace)
                    if current != expected:
                        raise StoreError("Stale", "workspace CAS changed")
                    row = (
                        None
                        if parent is None
                        else c.execute(
                            "SELECT snapshot FROM capture WHERE workspace=? AND sequence=?",
                            (workspace.raw, parent),
                        ).fetchone()
                    )
                    changed = row is None or row[0] != snapshot.raw
                    if changed:
                        sequence, next_seq = allocate_sequence(current.next_sequence)
                        c.execute(
                            "INSERT INTO capture(workspace,sequence,parent,snapshot,request_key) VALUES(?,?,?,?,?)",
                            (workspace.raw, sequence, parent, snapshot.raw, key),
                        )
                        self._event("capture-inserted")
                        if (
                            c.execute(
                                "UPDATE workspace SET cursor=?,next_seq=?,version=? WHERE id=? AND version=? AND cursor IS ?",
                                (
                                    sequence,
                                    next_seq,
                                    next_seq,
                                    workspace.raw,
                                    expected.version,
                                    parent,
                                ),
                            ).rowcount
                            != 1
                        ):
                            raise StoreError("Stale", "workspace CAS changed")
                        self._event("cursor-updated")
                        version = next_seq
                    else:
                        assert parent is not None
                        sequence, version = parent, expected.version
                    updated = c.execute(
                        "UPDATE request SET state='completed',result_sequence=?,result_version=?,changed=? WHERE workspace=? AND key=? AND state='pending'",
                        (sequence, version, int(changed), workspace.raw, key),
                    )
                    if updated.rowcount != 1:
                        raise StoreError(
                            "InvalidStore", "request completion lost its owner"
                        )
                    self._event("request-completed")
                return CaptureResult(
                    CaptureId(workspace, sequence), snapshot, version, changed
                )

    def history(
        self, workspace: WorkspaceId, *, after: int = -1, limit: int = 1000
    ) -> tuple[Capture, ...]:
        _workspace_id(workspace)
        if (
            type(after) is not int
            or after < -1
            or type(limit) is not int
            or not 1 <= limit <= 10000
        ):
            raise ValueError("history pagination bounds")
        with _errors(), self.files.locked("publication"), self._connection() as c:
            self._state(c, workspace)
            rows = c.execute(
                "SELECT sequence,parent,snapshot FROM capture WHERE workspace=? AND sequence>? ORDER BY sequence LIMIT ?",
                (workspace.raw, after, limit),
            ).fetchall()
            return tuple(
                Capture(
                    CaptureId(workspace, r[0]),
                    None if r[1] is None else CaptureId(workspace, r[1]),
                    SnapshotId(r[2]),
                )
                for r in rows
            )

    def read_snapshot(
        self, capture: CaptureId, *, max_file_bytes: int = 0
    ) -> dict[tuple[bytes, ...], content.Entry]:
        if type(capture) is not CaptureId:
            raise TypeError("CaptureId required")
        with _errors(), self.files.locked("publication"):
            with self._connection() as c:
                row = c.execute(
                    "SELECT snapshot FROM capture WHERE workspace=? AND sequence=?",
                    (capture.workspace.raw, capture.sequence),
                ).fetchone()
                require(row is not None, Code.UNAVAILABLE, "missing capture")
                assert row is not None
                snapshot = SnapshotId(row[0])
            return content.Verifier(self.files.read).snapshot(
                snapshot, max_file_bytes=max_file_bytes
            )

    def verify_roots(self) -> RootReport:
        with _errors(), self.files.locked("publication"):
            with self._connection() as c:
                rows = c.execute(
                    "SELECT r.snapshot,q.state FROM root r JOIN request q USING(workspace,key) ORDER BY r.workspace,r.key LIMIT 10001"
                ).fetchall()
                require(
                    len(rows) <= 10000, Code.RESOURCE_LIMIT, "root audit page bound"
                )
            completed = pending = incomplete = 0
            for raw, state in rows:
                try:
                    content.Verifier(self.files.read).snapshot(
                        SnapshotId(raw), max_file_bytes=0
                    )
                except ContentError:
                    if state == "completed":
                        raise
                    incomplete += 1
                if state == "completed":
                    completed += 1
                else:
                    pending += 1
            return RootReport(completed, pending, incomplete)
