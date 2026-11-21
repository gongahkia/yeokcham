"""Recovery contract regressions on disposable Btrfs stores."""

import errno
import hashlib
import json
import os
import select
import signal
import sqlite3
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path
from unittest.mock import patch

import pytest
import test_private_store as baseline
from hypothesis import given, seed, settings
from hypothesis import strategies as st
from test_private_store import (
    REPO,
    WS,
    api,
    append,
    closure,
    inspect,
    worker,
)
from yeokcham import codec
from yeokcham.errors import Code, ContentError
from yeokcham.identities import StoredObjectId, WorkspaceId

store = baseline.store
store_path = baseline.store_path


def pending(store, *, complete=False):
    snapshot, objects = closure(b"pending")
    expected = store.workspace(WS)
    if complete:
        for oid, raw in objects.items():
            store.put_object(oid, raw)

    def stop(event):
        if event == ("objects-durable" if complete else "temp-created"):
            raise OSError(errno.EIO, "publication interrupted")

    store.fault = stop
    with pytest.raises(api().StoreError, match="StorageIO"):
        store.append_capture(
            WS, snapshot, objects.get, expected=expected, key=b"pending"
        )
    store.fault = None
    return expected, snapshot, objects


def test_inspection_distinguishes_unknown_incomplete_complete_and_stale(store):
    store.register_workspace(WS)
    assert store.inspect_request(WS, b"unknown") is None
    expected, snapshot, objects = pending(store)
    status = store.inspect_request(WS, b"pending")
    assert status.request.state == "pending" and status.request.snapshot == snapshot
    assert status.expected == expected and status.eligible is True
    assert (status.closure, status.error) == ("missing", Code.UNAVAILABLE)
    for oid, raw in objects.items():
        store.put_object(oid, raw)
    status = store.inspect_request(WS, b"pending")
    assert status.closure == "verified" and status.request.result is None
    assert len(status.digest) == 32
    assert inspect(store.path)[0] == []
    append(store, key=b"other")
    status = store.inspect_request(WS, b"pending")
    assert status.eligible is False and status.expected == expected
    assert status.closure == "verified"
    with pytest.raises(api().StoreError, match="Stale"):
        store.append_capture(
            WS, snapshot, objects.get, expected=expected, key=b"pending"
        )


def test_inspection_tracks_pending_invalid_and_retry_cannot_replace_it(store):
    store.register_workspace(WS)
    expected, snapshot, objects = pending(store, complete=True)
    root = store.path / "objects" / snapshot.hex()
    root.chmod(0o600)
    root.write_bytes(b"invalid")
    status = store.inspect_request(WS, b"pending")
    assert status.eligible is True
    assert (status.closure, status.error) == ("invalid", Code.INVALID_ENCODING)
    with pytest.raises(ContentError):
        store.append_capture(
            WS, snapshot, objects.get, expected=expected, key=b"pending"
        )
    assert root.read_bytes() == b"invalid"
    assert inspect(store.path)[1:3] == ({"pending": 1}, 1)


@pytest.mark.parametrize("damage", ["missing", "invalid", "io", "budget"])
def test_completed_metadata_remains_visible_when_bytes_cannot_be_verified(
    store, monkeypatch, damage
):
    store.register_workspace(WS)
    result = append(store)
    path = store.path / "objects" / result.snapshot.hex()
    if damage == "missing":
        path.unlink()
        expected = ("missing", Code.UNAVAILABLE)
    elif damage == "invalid":
        path.chmod(0o600)
        path.write_bytes(b"invalid")
        expected = ("invalid", Code.INVALID_ENCODING)
    else:

        def unavailable(_oid):
            if damage == "io":
                raise OSError(errno.EIO, "read failed")
            raise ContentError(Code.RESOURCE_LIMIT, "limit")

        monkeypatch.setattr(store.files, "read", unavailable)
        expected = (
            "unverified",
            "StorageIO" if damage == "io" else Code.RESOURCE_LIMIT,
        )
    status = store.inspect_request(WS, b"key")
    assert status.request.result == result and status.eligible is None
    assert (status.closure, status.error) == expected
    assert store.lookup_request(WS, b"key").result == result
    assert store.history(WS)[0].identity == result.capture


def test_cleanup_failure_keeps_primary_object_validation_error(store, monkeypatch):
    real_unlink = os.unlink

    def fail_stage(path, *args, **kwargs):
        if str(path).startswith(".stage-"):
            raise OSError(errno.EIO, "stage removal failed")
        return real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(os, "unlink", fail_stage)
    raw = codec.pack(1, b"\x18\x01")
    oid = codec.object_id(raw)
    with pytest.raises(ContentError) as exc:
        store.put_object(oid, raw)
    assert any("stage removal failed" in n for n in exc.value.__notes__)
    assert not (store.path / "objects" / oid.hex()).exists()


def test_existing_object_resync_uses_verified_descriptor(store, monkeypatch):
    raw = codec.pack(1, codec.encode([1, b"existing"]))
    oid = codec.object_id(raw)
    store.put_object(oid, raw)
    original = os.open
    opens = []

    def track(path, *args, **kwargs):
        if path == oid.hex():
            opens.append(path)
        return original(path, *args, **kwargs)

    monkeypatch.setattr(os, "open", track)
    store.put_object(oid, raw)
    assert opens == [oid.hex()]


def test_rollback_failure_is_secondary_and_inspectable(store):
    class FailingTransaction:
        in_transaction = True

        def execute(self, sql):
            if sql == "COMMIT":
                raise sqlite3.OperationalError("primary COMMIT failure")
            if sql == "ROLLBACK":
                raise sqlite3.OperationalError("secondary ROLLBACK failure")

    with (
        pytest.raises(api().StoreError, match="UncertainCommit") as exc,
        store._transaction(FailingTransaction(), "capture"),
    ):
        pass
    assert str(exc.value.__cause__) == "primary COMMIT failure"
    assert any("secondary ROLLBACK failure" in n for n in exc.value.__notes__)


@pytest.mark.parametrize(
    "event", ["request-inserted", "root-inserted", "request-completed"]
)
def test_kill_during_each_sql_ownership_change(store, event):
    store.register_workspace(WS)
    child = worker(store.path, "kill", event)
    assert child.returncode == -signal.SIGKILL, child.stderr
    with api().PrivateStore.open(store.path, REPO) as recovered:
        captures, requests, roots, states = inspect(store.path)
        assert captures == [] and states[0][1] is None
        assert (requests, roots) == (
            ({"pending": 1}, 1) if event == "request-completed" else ({}, 0)
        )
        assert append(recovered).capture.sequence == 0


def damage_sql(path, table: str, mutate: Callable):
    with sqlite3.connect(path / "metadata.sqlite3", autocommit=False) as c:
        trigger = f"{table}_update"
        saved = c.execute(
            "SELECT sql FROM sqlite_schema WHERE name=?", (trigger,)
        ).fetchone()[0]
        c.execute(f"DROP TRIGGER {trigger}")
        mutate(c)
        c.execute(saved)
        assert c.execute("PRAGMA integrity_check").fetchone() == ("ok",)
        assert c.execute("PRAGMA foreign_key_check").fetchall() == []


@pytest.mark.parametrize("damage", ["request", "cursor"])
def test_reopen_rejects_fk_valid_wrong_history_relationships(store, damage):
    store.register_workspace(WS)
    append(store)
    append(store, key=b"next", data=b"next")
    if damage == "request":
        damage_sql(
            store.path,
            "request",
            lambda c: c.execute(
                "UPDATE request SET result_sequence=1 WHERE key=?", (b"key",)
            ),
        )
    else:
        damage_sql(
            store.path,
            "workspace",
            lambda c: c.execute("UPDATE workspace SET cursor=0, version=1, next_seq=1"),
        )
    before = (store.path / "metadata.sqlite3").read_bytes()
    with pytest.raises(api().StoreError, match="InvalidStore"):
        api().PrivateStore.open(store.path, REPO)
    assert (store.path / "metadata.sqlite3").read_bytes() == before


def test_malformed_prefixed_marker_is_invalid_store(store):
    marker = store.path / "FORMAT"
    marker.chmod(0o600)
    marker.write_bytes(api().MARKER + b"no-id\n")
    with pytest.raises(api().StoreError, match="InvalidStore"):
        api().PrivateStore.open(store.path, REPO)
    assert marker.read_bytes().endswith(b"no-id\n")


def test_reopen_incomplete_initialization_refuses_without_repair(store, monkeypatch):
    child_path = store.path.parent / "interrupted"
    original = os.open

    def stop(path, flags, *args, **kwargs):
        if path == "FORMAT" and flags & os.O_CREAT:
            raise OSError(errno.EIO, "initializer interrupted")
        return original(path, flags, *args, **kwargs)

    monkeypatch.setattr(os, "open", stop)
    with pytest.raises(api().StoreError, match="StorageIO"):
        api().PrivateStore.initialize(child_path, REPO)
    db = child_path / "metadata.sqlite3"
    before = db.read_bytes()
    assert not (child_path / "FORMAT").exists()
    with pytest.raises(api().StoreError, match="InvalidStore"):
        api().PrivateStore.open(child_path, REPO)
    assert db.read_bytes() == before and not (child_path / "FORMAT").exists()


def test_existing_orphan_does_not_resolve_unknown_key(store):
    store.register_workspace(WS)
    snapshot, objects = closure()
    for oid, raw in objects.items():
        store.put_object(oid, raw)
    assert store.read_object(StoredObjectId(snapshot.raw))
    assert store.inspect_request(WS, b"lost") is None
    assert inspect(store.path)[0:3] == ([], {}, 0)


@pytest.mark.parametrize("state", ["pending", "completed"])
def test_same_handle_retry_requires_store_directory_sync(store, monkeypatch, state):
    store.register_workspace(WS)
    expected = store.workspace(WS)
    snapshot, objects = closure(b"pending")
    if state == "pending":
        pending(store, complete=True)
    else:
        store.append_capture(
            WS, snapshot, objects.get, expected=expected, key=b"pending"
        )
    real_sync = os.fsync

    def fail(fd):
        if fd == store.files.root:
            raise OSError(errno.EIO, "store directory still unsynced")
        return real_sync(fd)

    before = inspect(store.path)
    with monkeypatch.context() as faults:
        faults.setattr(os, "fsync", fail)
        with pytest.raises(api().StoreError, match="UncertainCommit") as error:
            store.append_capture(
                WS, snapshot, objects.get, expected=expected, key=b"pending"
            )
        assert error.value.__cause__.errno == errno.EIO
    assert inspect(store.path) == before
    assert store.lookup_request(WS, b"pending").state == state
    assert (
        store.append_capture(
            WS, snapshot, objects.get, expected=expected, key=b"pending"
        ).capture.sequence
        == 0
    )


@pytest.mark.parametrize("damage", ["missing", "wrong-snapshot"])
def test_malformed_pending_root_is_not_reported_as_an_object_problem(store, damage):
    store.register_workspace(WS)
    pending(store)
    if damage == "missing":
        trigger = "root_delete"
        statement = "DELETE FROM root"
    else:
        trigger = "root_update"
        statement = "UPDATE root SET snapshot=zeroblob(32)"
    connection = sqlite3.connect(store.path / "metadata.sqlite3", autocommit=False)
    try:
        saved = connection.execute(
            "SELECT sql FROM sqlite_schema WHERE name=?", (trigger,)
        ).fetchone()[0]
        connection.execute(f"DROP TRIGGER {trigger}")
        connection.execute(statement)
        connection.execute(saved)
        connection.commit()
        assert connection.execute("PRAGMA foreign_key_check").fetchall()
    finally:
        connection.close()
    before = (store.path / "metadata.sqlite3").read_bytes()
    with pytest.raises(api().StoreError, match="InvalidStore"):
        store.inspect_request(WS, b"pending")
    with pytest.raises(api().StoreError, match="InvalidStore"):
        api().PrivateStore.open(store.path, REPO)
    assert (store.path / "metadata.sqlite3").read_bytes() == before


@seed(30201)
@settings(max_examples=16, deadline=None)
@given(st.binary(max_size=128), st.binary(min_size=1, max_size=16))
def test_replay_key_and_digest_survive_reopen(tmp_path_factory, data, key):
    path = tmp_path_factory.mktemp("request-property") / "store"
    snapshot, objects = closure(data)
    with api().PrivateStore.initialize(path, REPO) as opened:
        opened.register_workspace(WS)
        expected = opened.workspace(WS)
        result = opened.append_capture(
            WS, snapshot, objects.get, expected=expected, key=key
        )
    with api().PrivateStore.open(path, REPO) as reopened:
        recovered = reopened.inspect_request(WS, key)
        # Hand-encoded CBOR array [format, workspace16, zero version, null parent, snapshot32].
        control = b"\x85\x01\x50" + WS.raw + b"\x00\xf6\x58\x20" + snapshot.raw
        assert (
            recovered.digest
            == hashlib.sha256(b"yeokcham/private-request/m1b1\0" + control).digest()
        )
        assert recovered.request.result == result and recovered.closure == "verified"
        assert (
            reopened.append_capture(WS, snapshot, {}.get, expected=expected, key=key)
            == result
        )
        with pytest.raises(api().StoreError, match="RequestMismatch"):
            reopened.append_capture(
                WS, snapshot, {}.get, expected=reopened.workspace(WS), key=key
            )


def test_kill_before_format_marker_cannot_create_authority(store_path):
    with subprocess_worker("initialize", store_path) as child:
        out, err = child.communicate(timeout=10)
        assert child.returncode == -signal.SIGKILL, err
        assert out.strip() == "before-marker"
    metadata = store_path / "metadata.sqlite3"
    assert metadata.is_file()
    before = metadata.read_bytes()
    with pytest.raises(api().StoreError, match="InvalidStore"):
        api().PrivateStore.open(store_path, REPO)
    assert not (store_path / "FORMAT").exists()
    assert metadata.read_bytes() == before


PHASES = (
    "before-temp",
    "after-temp",
    "stream-write",
    "after-write",
    "file-sync",
    "after-file-sync",
    "link",
    "after-link",
    "directory-sync",
    "unlink",
    "after-unlink-sync",
    "existing-verify",
    "existing-sync",
)
CANONICAL_VISIBLE = frozenset(PHASES[7:])
EXISTING = frozenset(PHASES[-2:])


def subprocess_worker(*args, **kwargs):
    return subprocess.Popen(
        [sys.executable, "-B", __file__, *map(str, args)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        **kwargs,
    )


def ready_line(child):
    assert select.select([child.stdout], [], [], 10)[0], "child missed barrier"
    return child.stdout.readline().strip()


def outside_inspection(path):
    with subprocess_worker("inspect", path) as child:
        out, err = child.communicate(timeout=10)
        assert child.returncode == 0, err
        return json.loads(out)


@pytest.mark.parametrize("mode", ["eio", "kill"])
@pytest.mark.parametrize("phase", PHASES)
def test_object_boundary_faults_preserve_exact_pending_owner(store, mode, phase):
    store.register_workspace(WS)
    old = append(store, key=b"old", data=b"old")
    expected = store.workspace(WS)
    snapshot, objects = closure(b"next")
    raw = objects[StoredObjectId(snapshot.raw)]
    directory = store.path / "objects"
    name = directory / snapshot.hex()
    held = directory / ".stage-unowned-fixture"
    held.write_bytes(b"preserve this")
    committed_bytes = {file.name: file.read_bytes() for file in directory.iterdir()}
    if phase in EXISTING:
        store.put_object(StoredObjectId(snapshot.raw), raw)
        existing_inode = name.stat().st_ino
    with subprocess_worker("object", store.path, phase, mode) as child:
        out, err = child.communicate(timeout=15)
        assert child.returncode == (19 if mode == "eio" else -signal.SIGKILL), err
        assert out.strip() == f"fault:{phase}"
    with api().PrivateStore.open(store.path, REPO) as reopened:
        observed = outside_inspection(store.path)
        assert observed["captures"] == [[WS.hex(), 0, None, old.snapshot.hex()]]
        assert observed["owners"] == sorted(
            [
                [
                    WS.hex(),
                    b"old".hex(),
                    "completed",
                    old.snapshot.hex(),
                    old.snapshot.hex(),
                    0,
                ],
                [
                    WS.hex(),
                    b"next".hex(),
                    "pending",
                    snapshot.hex(),
                    snapshot.hex(),
                    None,
                ],
            ]
        )
        assert name.exists() == (phase in CANONICAL_VISIBLE)
        if name.exists():
            assert name.read_bytes() == raw
        if phase in EXISTING:
            assert name.stat().st_ino == existing_inode
        assert all(
            (directory / n).read_bytes() == data for n, data in committed_bytes.items()
        )
        before = reopened.inspect_request(WS, b"next")
        assert before.request.result is None and before.closure == "missing"
        resumed = reopened.append_capture(
            WS, snapshot, objects.get, expected=expected, key=b"next"
        )
        assert resumed.capture.sequence == 1
        assert (
            reopened.append_capture(
                WS, snapshot, objects.get, expected=expected, key=b"next"
            )
            == resumed
        )
        observed = outside_inspection(store.path)
        assert observed["captures"][-1] == [WS.hex(), 1, 0, snapshot.hex()]
        assert observed["owners"][0][-1] == 1
        assert held.read_bytes() == b"preserve this"


def test_killed_workspace_does_not_block_parallel_capture_read_or_same_key_retry(store):
    others = [WorkspaceId(bytes([n]) * 16) for n in (1, 2)]
    for workspace in [WS, *others]:
        store.register_workspace(workspace)
        snapshot, objects = closure(workspace.raw)
        store.append_capture(
            workspace,
            snapshot,
            objects.get,
            expected=store.workspace(workspace),
            key=b"first",
        )
    with (
        subprocess_worker("object", store.path, "stream-write", "pause-kill") as victim,
        subprocess_worker("peer", store.path, others[0].hex(), "write") as writer,
        subprocess_worker("peer", store.path, others[1].hex(), "read") as reader,
    ):
        assert {ready_line(child) for child in (victim, writer, reader)} == {"ready"}
        victim.stdin.write("go\n")
        victim.stdin.flush()
        assert ready_line(victim) == "fault:stream-write"
        started = time.monotonic()
        try:
            for child in (writer, reader):
                child.stdin.write("go\n")
                child.stdin.flush()
            for child in (writer, reader):
                out, err = child.communicate(timeout=10)
                assert child.returncode == 0, (out, err)
            elapsed = time.monotonic() - started
            assert victim.poll() is None
            victim.kill()
            victim.communicate(timeout=5)
        finally:
            for child in (writer, reader, victim):
                if child.poll() is None:
                    child.kill()
    status = store.inspect_request(WS, b"next")
    assert status.request.state == "pending" and status.eligible
    assert status.closure == "missing"
    with (
        subprocess_worker("peer", store.path, WS.hex(), "retry") as a,
        subprocess_worker("peer", store.path, WS.hex(), "retry") as b,
    ):
        assert ready_line(a) == ready_line(b) == "ready"
        for child in (a, b):
            child.stdin.write("go\n")
            child.stdin.flush()
        for child in (a, b):
            out, err = child.communicate(timeout=10)
            assert child.returncode == 0 and out.strip() == "1", err
    observed = outside_inspection(store.path)
    assert len(observed["captures"]) == 5
    assert [len(store.history(ws)) for ws in (WS, *others)] == [2, 2, 1]
    print(f"independent peers completed across stalled workspace in {elapsed:.4f}s")


def object_worker(path, phase, mode):
    with api().PrivateStore.open(path, REPO) as opened:
        if mode == "pause-kill":
            print("ready", flush=True)
            assert sys.stdin.readline() == "go\n"

        def fault():
            print(f"fault:{phase}", flush=True)
            if mode == "kill":
                os.kill(os.getpid(), signal.SIGKILL)
            if mode == "pause-kill":
                sys.stdin.readline()
                raise AssertionError("parent should kill at barrier")
            raise OSError(errno.EIO, phase)

        events = {
            "after-temp": "temp-created",
            "after-write": "temp-written",
            "after-file-sync": "file-synced",
            "after-link": "object-linked",
        }
        directory_syncs = 0
        snapshot, objects = closure(b"next")
        key = StoredObjectId(snapshot.raw)
        syscall_open, syscall_sync, syscall_unlink, syscall_link, syscall_write = (
            os.open,
            os.fsync,
            os.unlink,
            os.link,
            os.write,
        )
        verify = opened.files._read_verified

        def opening(name, *args, **kwargs):
            if phase == "before-temp" and str(name).startswith(".stage-"):
                fault()
            return syscall_open(name, *args, **kwargs)

        def sync(fd):
            nonlocal directory_syncs
            if fd == opened.files.objects:
                directory_syncs += 1
                if phase == "directory-sync" and directory_syncs == 1:
                    fault()
                if phase == "after-unlink-sync" and directory_syncs == 2:
                    fault()
            else:
                name = Path(os.readlink(f"/proc/self/fd/{fd}")).name
                if (phase == "file-sync" and name.startswith(".stage-")) or (
                    phase == "existing-sync" and name == key.hex()
                ):
                    fault()
            return syscall_sync(fd)

        def unlinking(name, *args, **kwargs):
            if phase == "unlink" and str(name).startswith(".stage-"):
                fault()
            return syscall_unlink(name, *args, **kwargs)

        def linking(*args, **kwargs):
            if phase == "link":
                fault()
            return syscall_link(*args, **kwargs)

        def writing(fd, view):
            if phase == "stream-write" and Path(
                os.readlink(f"/proc/self/fd/{fd}")
            ).name.startswith(".stage-"):
                syscall_write(fd, view[: max(1, len(view) // 2)])
                fault()
            return syscall_write(fd, view)

        def verifying(fd, identity):
            if phase == "existing-verify" and identity == key:
                fault()
            return verify(fd, identity)

        def event(name):
            if events.get(phase) == name:
                fault()

        opened.fault = event
        expected = opened.workspace(WS)
        with (
            patch.object(os, "open", opening),
            patch.object(os, "fsync", sync),
            patch.object(os, "unlink", unlinking),
            patch.object(os, "link", linking),
            patch.object(os, "write", writing),
            patch.object(opened.files, "_read_verified", verifying),
        ):
            try:
                opened.append_capture(
                    WS, snapshot, objects.get, expected=expected, key=b"next"
                )
            except api().StoreError as error:
                assert error.code == "StorageIO"
                sys.exit(19)
        raise AssertionError("fault not exercised")


def inspect_worker(path):
    caps, _, _, _ = inspect(path)
    from contextlib import closing

    with closing(sqlite3.connect(path / "metadata.sqlite3", autocommit=True)) as c:
        owners = c.execute(
            """
            SELECT q.workspace,q.key,q.state,q.snapshot,r.snapshot,q.result_sequence
            FROM request AS q JOIN root AS r USING(workspace,key) ORDER BY q.workspace,q.key
            """
        ).fetchall()
        assert all(a == b for _, _, _, a, b, _ in owners)
        assert c.execute("SELECT count(*) FROM root").fetchone() == (len(owners),)

    def encode_rows(rows):
        return [[v.hex() if isinstance(v, bytes) else v for v in row] for row in rows]

    print(json.dumps({"captures": encode_rows(caps), "owners": encode_rows(owners)}))


def peer_worker(path, identity, mode):
    ws = WorkspaceId.from_hex(identity)
    with api().PrivateStore.open(path, REPO) as opened:
        expected = opened.workspace(ws)
        print("ready", flush=True)
        assert sys.stdin.readline() == "go\n"
        if mode == "read":
            assert len(opened.history(ws)) == 1
            return
        snapshot, objects = closure(b"next" if mode == "retry" else b"peer")
        result = opened.append_capture(
            ws, snapshot, objects.get, expected=expected, key=b"next"
        )
        print(result.capture.sequence)


def initialize_worker(path):
    original = os.open

    def stop(name, flags, *args, **kwargs):
        if name == "FORMAT" and flags & os.O_CREAT:
            print("before-marker", flush=True)
            os.kill(os.getpid(), signal.SIGKILL)
        return original(name, flags, *args, **kwargs)

    with patch.object(os, "open", stop):
        api().PrivateStore.initialize(path, REPO)


if __name__ == "__main__":
    action, location, *args = sys.argv[1:]
    {
        "object": object_worker,
        "inspect": inspect_worker,
        "peer": peer_worker,
        "initialize": initialize_worker,
    }[action](Path(location), *args)
