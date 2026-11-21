"""Restricted M1b.1 contract tests; every store is disposable and outside checkout."""

import errno
import os
import signal
import sqlite3
import subprocess
import sys
import time
from dataclasses import replace
from pathlib import Path

import pytest
from hypothesis import given, seed, settings
from hypothesis import strategies as st
from yeokcham import codec, content
from yeokcham.errors import ContentError
from yeokcham.identities import (
    CaptureId,
    RepositoryId,
    SnapshotId,
    StoredObjectId,
    WorkspaceId,
)

REPO = RepositoryId(b"r" * 32)
WS = WorkspaceId(b"w" * 16)


def api():
    from yeokcham import private_store

    return private_store


def closure(data=b"one"):
    objects = {}
    cid = content.write_content([data], objects.__setitem__)
    raw = content.encode_tree([content.File(b"file", content.Mode.REGULAR, cid)])
    root = codec.object_id(raw)
    objects[root] = raw
    raw = content.encode_snapshot(content.TreeId(root.raw))
    snapshot = SnapshotId(codec.object_id(raw).raw)
    objects[StoredObjectId(snapshot.raw)] = raw
    content.Verifier(objects.get).snapshot(snapshot, max_file_bytes=0)
    return snapshot, objects


@pytest.fixture
def store_path(tmp_path):
    assert not tmp_path.is_relative_to(Path(__file__).resolve().parents[2])
    return tmp_path / "private-store"


@pytest.fixture
def store(store_path):
    s = api().PrivateStore.initialize(store_path, REPO)
    try:
        yield s
    finally:
        s.close()


def append(s, key=b"key", data=b"one", expected=None):
    snapshot, objects = closure(data)
    state = expected if expected is not None else s.workspace(WS)
    return s.append_capture(WS, snapshot, objects.get, expected=state, key=key)


def inspect(path):
    c = sqlite3.connect(path / "metadata.sqlite3", autocommit=True)
    assert c.execute("pragma integrity_check").fetchone() == ("ok",)
    assert c.execute("pragma foreign_key_check").fetchall() == []
    rows = c.execute(
        "select workspace,sequence,parent,snapshot from capture order by workspace,sequence"
    ).fetchall()
    requests = c.execute("select state,count(*) from request group by state").fetchall()
    roots = c.execute("select count(*) from root").fetchone()[0]
    workspaces = c.execute(
        "select id,cursor,version,next_seq from workspace order by id"
    ).fetchall()
    c.close()
    for _, _, _, snap in rows:

        def resolver(identity):
            file = path / "objects" / identity.hex()
            return file.read_bytes() if file.exists() else None

        content.Verifier(resolver).snapshot(SnapshotId(snap), max_file_bytes=0)
    return rows, dict(requests), roots, workspaces


def test_initialize_open_modes_and_identity(store, store_path):
    mod = api()
    with mod.PrivateStore.open(store_path, REPO) as other:
        assert other.repository == REPO
        assert other.verify_roots().completed == 0
    with pytest.raises(mod.StoreError, match="IdentityMismatch"):
        mod.PrivateStore.open(store_path, RepositoryId(b"x" * 32))
    c = sqlite3.connect(store_path / "metadata.sqlite3", autocommit=True)
    assert c.execute("pragma journal_mode").fetchone() == ("delete",)
    assert c.execute("pragma application_id").fetchone() == (0x594B5031,)
    assert c.execute("pragma user_version").fetchone() == (1,)
    c.close()


@pytest.mark.parametrize("kind", ["directory", "unknown-db", "symlink", "live-name"])
def test_refuse_existing_or_live_path(store_path, kind):
    mod = api()
    path = store_path
    if kind == "live-name":
        path = store_path.parent / ".yeokcham-v2"
    elif kind == "symlink":
        path.symlink_to(store_path.parent, target_is_directory=True)
    else:
        path.mkdir()
        if kind == "unknown-db":
            (path / "metadata.sqlite3").write_bytes(b"unknown")
    with pytest.raises((mod.StoreError, FileExistsError)):
        mod.PrivateStore.initialize(path, REPO)
    if kind == "unknown-db":
        assert (path / "metadata.sqlite3").read_bytes() == b"unknown"


@pytest.mark.parametrize(
    "change", ["application", "version", "schema", "identity", "truncated"]
)
def test_reopen_refuses_unknown_without_writes(store, store_path, change):
    store.close()
    db = store_path / "metadata.sqlite3"
    if change == "truncated":
        db.write_bytes(b"not sqlite")
    else:
        c = sqlite3.connect(db, autocommit=True)
        if change == "application":
            c.execute("pragma application_id=42")
        elif change == "version":
            c.execute("pragma user_version=99")
        elif change == "schema":
            c.execute("create table unknown(x)")
        else:
            c.execute("drop trigger repository_update")
            c.execute("update repository set identity=?", (b"z" * 32,))
        c.close()
    before = db.read_bytes()
    with pytest.raises(api().StoreError):
        api().PrivateStore.open(store_path, REPO)
    assert db.read_bytes() == before


def test_unsupported_capability_refuses_before_creation(store_path, monkeypatch):
    mod = api()
    monkeypatch.setattr(
        mod,
        "check_runtime",
        lambda path: (_ for _ in ()).throw(
            mod.StoreError("UnsupportedRuntime", "test")
        ),
    )
    with pytest.raises(mod.StoreError, match="UnsupportedRuntime"):
        mod.PrivateStore.initialize(store_path, REPO)
    assert not store_path.exists()


def test_object_publish_stream_read_duplicate_and_orphan(store):
    raw = codec.pack(1, codec.encode([1, b"bytes"]))
    identity = codec.object_id(raw)
    store.put_stream(
        identity, len(raw), (raw[i : i + 3] for i in range(0, len(raw), 3))
    )
    first = (store.path / "objects" / identity.hex()).stat()
    store.put_object(identity, raw)
    assert store.read_object(identity) == raw
    assert (store.path / "objects" / identity.hex()).stat().st_ino == first.st_ino
    assert inspect(store.path)[0] == [] and store.verify_roots().completed == 0


@pytest.mark.parametrize(
    "fault",
    [
        "wrong-id",
        "truncated",
        "cbor",
        "oversized-inline",
        "short-stream",
        "long-stream",
    ],
)
def test_bad_object_refuses(store, fault):
    raw = codec.pack(1, codec.encode([1, b"bytes"]))
    identity = codec.object_id(raw)
    if fault == "wrong-id":
        identity = StoredObjectId(b"x" * 32)
    elif fault == "truncated":
        raw = raw[:-1]
    elif fault == "cbor":
        raw = codec.pack(1, b"\x18\x01")
        identity = codec.object_id(raw)
    elif fault == "oversized-inline":
        raw = codec.pack(1, codec.encode([1, bytes(65537)]))
        identity = codec.object_id(raw)
    with pytest.raises(ContentError):
        if fault.endswith("stream"):
            store.put_stream(
                identity, len(raw) + (1 if fault == "short-stream" else -1), [raw]
            )
        else:
            store.put_object(identity, raw)
    assert inspect(store.path)[0] == []


def test_corrupt_existing_object_never_overwritten(store):
    raw = codec.pack(1, codec.encode([1, b"bytes"]))
    identity = codec.object_id(raw)
    store.put_object(identity, raw)
    file = store.path / "objects" / identity.hex()
    file.chmod(0o600)
    file.write_bytes(b"corrupt")
    with pytest.raises(ContentError):
        store.put_object(identity, raw)
    assert file.read_bytes() == b"corrupt"


def test_history_unchanged_equal_snapshots_and_replay(store):
    assert store.register_workspace(WS).cursor is None
    assert store.register_workspace(WS) == store.workspace(WS)
    state = store.workspace(WS)
    a = append(store, b"a", expected=state)
    unchanged = append(store, b"same")
    assert (
        not unchanged.changed
        and unchanged.capture == a.capture
        and unchanged.version == a.version
    )
    b = append(store, b"b", b"two")
    again = append(store, b"again", b"one")
    assert a.snapshot == again.snapshot and a.capture != again.capture
    history = store.history(WS)
    assert [v.identity.sequence for v in history] == [0, 1, 2]
    assert [v.parent for v in history] == [None, a.capture, b.capture]
    assert (
        store.workspace(WS).cursor == again.capture and store.workspace(WS).version == 3
    )
    assert append(store, b"a", expected=state) == a
    assert store.lookup_request(WS, b"a").result == a
    with pytest.raises(api().StoreError, match="RequestMismatch"):
        append(store, b"a", b"different", expected=state)
    with pytest.raises(api().StoreError, match="Stale"):
        append(store, b"stale", b"different", expected=state)
    assert len(store.history(WS, after=0, limit=1)) == 1
    assert store.verify_roots().completed == 4


@pytest.mark.parametrize("fault", ["missing-root", "missing-child", "corrupt-child"])
def test_incomplete_closure_retains_pending_not_capture(store, fault):
    store.register_workspace(WS)
    snapshot, objects = closure()
    if fault == "missing-root":
        objects.pop(StoredObjectId(snapshot.raw))
    else:
        child = next(oid for oid, raw in objects.items() if codec.unpack(raw).kind == 1)
        if fault == "missing-child":
            objects.pop(child)
        else:
            objects[child] = b"corrupt"
    with pytest.raises(ContentError):
        store.append_capture(
            WS, snapshot, objects.get, expected=store.workspace(WS), key=b"bad"
        )
    rows, requests, roots, workspaces = inspect(store.path)
    assert (
        rows == []
        and requests == {"pending": 1}
        and roots == 1
        and workspaces[0][1] is None
    )
    assert store.lookup_request(WS, b"bad").state == "pending"


def test_verified_large_file_closure_streams_not_flattened(store):
    store.register_workspace(WS)
    snapshot, objects = closure(bytes(range(256)) * 4097)
    result = store.append_capture(
        WS, snapshot, objects.get, expected=store.workspace(WS), key=b"large"
    )
    entries = store.read_snapshot(result.capture, max_file_bytes=0)
    assert entries[(b"file",)].data is None
    assert inspect(store.path)[0][0][3] == snapshot.raw


@pytest.mark.parametrize(
    "statement",
    [
        "delete from capture",
        "update capture set parent=0",
        "delete from root",
        "delete from request",
        "delete from workspace",
        "update workspace set version=100",
        "update request set state='pending'",
        "update root set snapshot=zeroblob(32)",
    ],
)
def test_sql_immutable_and_transition_guards(store, statement):
    store.register_workspace(WS)
    append(store)
    c = sqlite3.connect(store.path / "metadata.sqlite3", autocommit=True)
    c.execute("pragma foreign_keys=on")
    with pytest.raises(sqlite3.IntegrityError):
        c.execute(statement)
    assert not c.in_transaction
    c.close()
    assert len(inspect(store.path)[0]) == 1


def test_invalid_cas_identity_ancestry_and_exhaustion(store):
    mod = api()
    store.register_workspace(WS)
    with pytest.raises((TypeError, ValueError)):
        store.register_workspace(RepositoryId(b"x" * 32))
    state = store.workspace(WS)
    with pytest.raises(mod.StoreError, match="Stale"):
        append(store, expected=replace(state, cursor=CaptureId(WS, 99)))
    with pytest.raises(mod.StoreError, match="Exhausted"):
        mod.allocate_sequence(2**63 - 1)
    assert mod.allocate_sequence(2**63 - 2) == (2**63 - 2, 2**63 - 1)
    assert len(store.history(WS)) == 0


@pytest.mark.parametrize(
    "event",
    [
        "temp-created",
        "temp-written",
        "file-synced",
        "object-linked",
        "object-dir-synced",
        "objects-durable",
        "capture-inserted",
        "cursor-updated",
        "capture-before-commit",
        "capture-committed",
    ],
)
def test_process_interruption_separate_inspector(store, event):
    store.register_workspace(WS)
    proc = worker(store.path, "kill", event)
    assert proc.returncode == -signal.SIGKILL, proc.stderr
    rows, requests, roots, workspaces = inspect(store.path)
    completed = event == "capture-committed"
    assert (
        len(rows) == int(completed)
        and requests == {("completed" if completed else "pending"): 1}
        and roots == 1
    )
    assert workspaces[0][1] == (0 if completed else None)
    with api().PrivateStore.open(store.path, REPO) as reopened:
        result = append(reopened, expected=api().WorkspaceState(WS, 0, None, 0))
        assert result.capture == CaptureId(WS, 0) and len(reopened.history(WS)) == 1


@pytest.mark.parametrize(
    "event", ["file-synced", "object-dir-synced", "capture-before-commit"]
)
@pytest.mark.parametrize("number", [errno.ENOSPC, errno.EIO])
def test_io_error_preserves_cursor_and_retry(store, event, number):
    store.register_workspace(WS)

    def fault(current):
        if current == event:
            raise OSError(number, "injected")

    store.fault = fault
    with pytest.raises(api().StoreError):
        append(store)
    assert inspect(store.path)[0] == []
    store.fault = None
    assert append(store).capture == CaptureId(WS, 0)


def test_commit_uncertainty_and_lost_response_same_identity(store):
    store.register_workspace(WS)
    state = store.workspace(WS)

    def fault(event):
        if event == "capture-committed":
            raise OSError(errno.EIO, "response lost")

    store.fault = fault
    with pytest.raises(api().StoreError, match="UncertainCommit"):
        append(store, expected=state)
    store.fault = None
    result = append(store, expected=state)
    assert result.capture == CaptureId(WS, 0) and len(inspect(store.path)[0]) == 1


def test_three_workspaces_and_duplicate_key_processes(store):
    for i in range(3):
        store.register_workspace(WorkspaceId(bytes([i]) * 16))
    procs = [spawn(store.path, "append-workspace", str(i)) for i in range(3)]
    for proc in procs:
        stdout, stderr = proc.communicate(timeout=15)
        assert proc.returncode == 0, (stdout, stderr)
    assert len(inspect(store.path)[0]) == 3
    store.register_workspace(WS)
    procs = [spawn(store.path, "duplicate", "") for _ in range(2)]
    for proc in procs:
        stdout, stderr = proc.communicate(timeout=15)
        assert proc.returncode == 0, (stdout, stderr)
    assert len(store.history(WS)) == 1


def test_stale_concurrent_writers_one_workspace(store):
    store.register_workspace(WS)
    procs = [spawn(store.path, "stale", str(i)) for i in range(2)]
    codes = [proc.wait(timeout=15) for proc in procs]
    assert sorted(codes) == [0, 17] and len(inspect(store.path)[0]) == 1


def test_busy_bound_and_no_sql_transaction_during_input(store):
    store.register_workspace(WS)
    c = sqlite3.connect(store.path / "metadata.sqlite3", autocommit=True)
    c.execute("BEGIN IMMEDIATE")
    start = time.monotonic()
    with pytest.raises(api().StoreError, match="Busy"):
        append(store)
    assert time.monotonic() - start < 4
    c.execute("ROLLBACK")
    c.close()
    snapshot, objects = closure()

    def resolver(oid):
        c = sqlite3.connect(
            store.path / "metadata.sqlite3", autocommit=True, timeout=0.1
        )
        c.execute("BEGIN IMMEDIATE")
        c.execute("ROLLBACK")
        c.close()
        return objects.get(oid)

    store.append_capture(
        WS, snapshot, resolver, expected=store.workspace(WS), key=b"no-long-sql"
    )


def test_committed_missing_or_corrupt_object_refuses_not_empty(store):
    store.register_workspace(WS)
    result = append(store)
    file = store.path / "objects" / result.snapshot.hex()
    file.chmod(0o600)
    file.write_bytes(b"corrupt")
    with pytest.raises(ContentError):
        store.verify_roots()
    with pytest.raises(ContentError):
        store.read_snapshot(result.capture)
    file.unlink()
    with pytest.raises(ContentError, match="missing"):
        store.verify_roots()
    assert len(store.history(WS)) == 1


@seed(20261122)
@settings(max_examples=15, deadline=None)
@given(st.lists(st.binary(max_size=32), min_size=1, max_size=8))
def test_history_property(tmp_path_factory, values):
    path = tmp_path_factory.mktemp("history-property") / "store"
    with api().PrivateStore.initialize(path, REPO) as s:
        s.register_workspace(WS)
        prior = None
        expected = []
        for i, data in enumerate(values):
            r = append(s, str(i).encode(), data)
            if prior != data:
                expected.append(r.snapshot)
            prior = data
        assert [c.snapshot for c in s.history(WS)] == expected
        assert len(inspect(path)[0]) == len(expected)


def spawn(path, mode, arg):
    return subprocess.Popen(
        [sys.executable, "-B", str(Path(__file__).resolve()), str(path), mode, arg],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def worker(path, mode, arg):
    return subprocess.run(
        [sys.executable, "-B", str(Path(__file__).resolve()), str(path), mode, arg],
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )


def test_constructor_cannot_bypass_store_admission(store_path):
    store_path.mkdir(mode=0o700)
    (store_path / "objects").mkdir(mode=0o700)
    (store_path / "locks").mkdir(mode=0o700)
    before = sorted(str(p.relative_to(store_path)) for p in store_path.rglob("*"))
    with pytest.raises(api().StoreError):
        api().PrivateStore(store_path, REPO)
    assert (
        sorted(str(p.relative_to(store_path)) for p in store_path.rglob("*")) == before
    )


def test_invalid_timeout_refuses_before_initialization(store_path):
    with pytest.raises(ValueError):
        api().PrivateStore.initialize(store_path, REPO, timeout=True)
    assert not store_path.exists()


def await_ready(proc):
    import select

    assert select.select([proc.stdout], [], [], 5)[0], "worker failed to reach boundary"
    assert proc.stdout.readline().strip() == "ready"


def test_stalled_input_does_not_block_other_workspaces(store):
    store.register_workspace(WS)
    for i in (1, 2):
        store.register_workspace(WorkspaceId(bytes([i]) * 16))
    paused = spawn(store.path, "pause-input", "")
    try:
        await_ready(paused)
        others = [spawn(store.path, "append-workspace", str(i)) for i in (1, 2)]
        for proc in others:
            stdout, stderr = proc.communicate(timeout=10)
            assert proc.returncode == 0, (stdout, stderr)
        assert store.history(WS) == ()
        report = store.verify_roots()
        assert (report.completed, report.pending, report.incomplete_pending) == (
            2,
            1,
            1,
        )
        paused.stdin.write("go\n")
        paused.stdin.flush()
        stdout, stderr = paused.communicate(timeout=10)
        assert paused.returncode == 0, (stdout, stderr)
        assert len(inspect(store.path)[0]) == 3
    finally:
        if paused.poll() is None:
            paused.kill()
            paused.communicate(timeout=5)


def test_reader_sees_old_complete_metadata_during_uncommitted_capture(store):
    store.register_workspace(WS)
    paused = spawn(store.path, "pause-sql", "")
    try:
        await_ready(paused)
        assert store.history(WS) == () and store.workspace(WS).cursor is None
        assert inspect(store.path)[0] == []
        paused.stdin.write("go\n")
        paused.stdin.flush()
        stdout, stderr = paused.communicate(timeout=10)
        assert paused.returncode == 0, (stdout, stderr)
        assert len(store.history(WS)) == 1
    finally:
        if paused.poll() is None:
            paused.kill()
            paused.communicate(timeout=5)


@pytest.mark.parametrize("number", [errno.EIO, errno.ENOSPC])
def test_actual_fsync_adapter_error_returns_no_capture(store, monkeypatch, number):
    from yeokcham import object_files

    store.register_workspace(WS)
    original = object_files.os.fsync
    seen = []

    def failed(fd):
        if Path(os.readlink("/proc/self/fd/" + str(fd))).name.startswith(".stage-"):
            seen.append(fd)
            raise OSError(number, "injected fsync syscall adapter")
        return original(fd)

    with monkeypatch.context() as patch:
        patch.setattr(object_files.os, "fsync", failed)
        with pytest.raises(api().StoreError):
            append(store)
    assert seen and inspect(store.path)[0] == []
    assert append(store).capture == CaptureId(WS, 0)


def test_actual_sqlite_full_preserves_existing_cursor(store, monkeypatch):
    from contextlib import contextmanager

    store.register_workspace(WS)
    first = append(store)
    original = store._connection
    codes = []

    @contextmanager
    def limited():
        with original() as c:
            pages = c.execute("PRAGMA page_count").fetchone()[0]
            c.execute(f"PRAGMA max_page_count={pages}")
            try:
                yield c
            except sqlite3.Error as error:
                codes.append(error.sqlite_errorcode & 255)
                raise

    monkeypatch.setattr(store, "_connection", limited)
    for i in range(200):
        try:
            append(store, key=i.to_bytes(2, "big"))
        except api().StoreError as error:
            assert error.code == "StorageFull"
            break
    else:
        pytest.fail("did not exercise SQLite FULL")
    monkeypatch.setattr(store, "_connection", original)
    assert sqlite3.SQLITE_FULL in codes
    assert (
        store.workspace(WS).cursor == first.capture and len(inspect(store.path)[0]) == 1
    )


def test_pending_capture_cannot_commit_without_completion(store):
    store.register_workspace(WS)

    def fail(event):
        if event == "temp-created":
            raise OSError(errno.EIO, "stop before objects")

    store.fault = fail
    with pytest.raises(api().StoreError):
        append(store)
    store.fault = None
    c = sqlite3.connect(store.path / "metadata.sqlite3", autocommit=True)
    c.execute("PRAGMA foreign_keys=ON")
    c.execute("BEGIN IMMEDIATE")
    snap, _ = closure()
    c.execute(
        "INSERT INTO capture(workspace,sequence,parent,snapshot,request_key) VALUES(?,0,NULL,?,?)",
        (WS.raw, snap.raw, b"key"),
    )
    with pytest.raises(sqlite3.IntegrityError):
        c.execute("COMMIT")
    assert c.in_transaction
    c.execute("ROLLBACK")
    c.close()
    assert inspect(store.path)[0] == []


def test_reopen_checks_root_ownership_not_only_schema(store, store_path):
    store.close()
    c = sqlite3.connect(store_path / "metadata.sqlite3", autocommit=True)
    assert c.execute("PRAGMA foreign_keys").fetchone() == (0,)
    c.execute("INSERT INTO root VALUES(?,?,?)", (WS.raw, b"orphan-owner", b"x" * 32))
    assert c.execute("PRAGMA integrity_check").fetchone() == ("ok",)
    assert c.execute("PRAGMA foreign_key_check").fetchall()
    c.close()
    with pytest.raises(api().StoreError, match="InvalidStore"):
        api().PrivateStore.open(store_path, REPO)


def test_commit_and_rollback_error_preserves_uncertain_classification(store):
    class BrokenCommit:
        in_transaction = True

        def execute(self, sql):
            if sql in ("COMMIT", "ROLLBACK"):
                raise sqlite3.OperationalError("injected adapter transaction fault")

    with (
        pytest.raises(api().StoreError, match="UncertainCommit"),
        store._transaction(BrokenCommit(), "capture"),
    ):
        pass


def test_reopen_reestablishes_marker_durability(store, store_path, monkeypatch):
    original = os.fsync
    sealed = []

    def tracked(fd):
        sealed.append(Path(os.readlink("/proc/self/fd/" + str(fd))).name)
        return original(fd)

    monkeypatch.setattr(os, "fsync", tracked)
    with api().PrivateStore.open(store_path, REPO):
        pass
    assert "FORMAT" in sealed


@pytest.mark.parametrize("number", [errno.EIO, errno.ENOSPC])
def test_objects_directory_sync_adapter_error_returns_no_capture(
    store, monkeypatch, number
):
    store.register_workspace(WS)
    original = os.fsync

    def failed(fd):
        if Path(os.readlink("/proc/self/fd/" + str(fd))).name == "objects":
            raise OSError(number, "injected objects directory fsync")
        return original(fd)

    with monkeypatch.context() as patch:
        patch.setattr(os, "fsync", failed)
        with pytest.raises(api().StoreError):
            append(store)
    assert inspect(store.path)[0] == []
    assert append(store).capture == CaptureId(WS, 0)


def test_independent_positive_content_and_mixed_snapshot_vectors(store, corpus):
    from conftest import MANIFEST
    from yeokcham.identities import ContentId

    seen = set()

    def reference(identity):
        seen.add(identity)
        return (corpus / "objects" / (identity.hex() + ".bin")).read_bytes()

    for case in MANIFEST["files"]:
        content.Verifier(reference).content(
            ContentId.from_hex(case["root"]), max_bytes=0
        )
    for case in MANIFEST["trees"]:
        content.Verifier(reference).snapshot(
            SnapshotId.from_hex(case["snapshot"]), max_file_bytes=0
        )
    for identity in seen:
        raw = reference(identity)
        store.put_object(identity, raw)
        assert store.read_object(identity) == raw
    store.register_workspace(WS)
    snapshot = SnapshotId.from_hex(MANIFEST["trees"][0]["snapshot"])
    result = store.append_capture(
        WS, snapshot, reference, expected=store.workspace(WS), key=b"golden"
    )
    actual = store.read_snapshot(result.capture, max_file_bytes=65536)
    assert actual[(b"bad-\xff",)].data == b"\0\xff"
    assert actual[(b"empty",)].kind == "directory"
    assert actual[(b"run",)].mode == content.Mode.EXECUTABLE
    assert actual[(b"link",)].data == b"missing/target"


if __name__ == "__main__":
    path, mode, arg = sys.argv[1:]
    with api().PrivateStore.open(Path(path), REPO) as s:
        if mode == "kill":

            def die(event):
                if event == arg:
                    os.kill(os.getpid(), signal.SIGKILL)

            s.fault = die
            append(s)
        elif mode == "pause-input":
            snapshot, objects = closure()
            first = True

            def paused_resolver(oid):
                global first
                if first:
                    first = False
                    print("ready", flush=True)
                    sys.stdin.readline()
                return objects.get(oid)

            s.append_capture(
                WS, snapshot, paused_resolver, expected=s.workspace(WS), key=b"paused"
            )
        elif mode == "pause-sql":

            def pause(event):
                if event == "capture-inserted":
                    print("ready", flush=True)
                    sys.stdin.readline()

            s.fault = pause
            append(s)
        elif mode == "append-workspace":
            ws = WorkspaceId(bytes([int(arg)]) * 16)
            snap, objects = closure(arg.encode())
            s.append_capture(
                ws, snap, objects.get, expected=s.workspace(ws), key=b"concurrent"
            )
        elif mode == "duplicate":
            append(s, expected=api().WorkspaceState(WS, 0, None, 0))
        elif mode == "stale":
            try:
                append(
                    s,
                    key=arg.encode(),
                    data=arg.encode(),
                    expected=api().WorkspaceState(WS, 0, None, 0),
                )
            except api().StoreError as exc:
                if exc.code == "Stale":
                    sys.exit(17)
                raise
