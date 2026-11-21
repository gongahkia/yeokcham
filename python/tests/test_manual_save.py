"""Observation-to-M1b tests with disposable stores and spawn-process barriers."""

import errno
import multiprocessing
import os
import sqlite3
from pathlib import Path
from unittest.mock import patch

import pytest
import test_private_store as persistence
from test_observation import source as source_fixture
from test_private_store import REPO, WS, inspect
from yeokcham import content
from yeokcham.identities import CaptureId, WorkspaceId
from yeokcham.private_store import PrivateStore

store = persistence.store
store_path = persistence.store_path
source = source_fixture


def api():
    from yeokcham import manual_save

    return manual_save


def save(store, source, key=b"key", expected=None, workspace=WS):
    expected = expected if expected is not None else store.workspace(workspace)
    return api().save_directory(
        store, workspace, os.fsencode(source), expected=expected, key=key
    )


def recorded(result, status="completed"):
    assert isinstance(result, api().SaveRecorded), result
    assert result.status == status
    return result.result


def refused(result, code):
    assert isinstance(result, api().SaveRefused), result
    assert result.code == code
    return result


def test_first_unchanged_changed_and_return_to_exact_snapshot(store, source):
    item = source / "file"
    item.write_bytes(b"one")
    start = store.register_workspace(WS)
    first = recorded(save(store, source, expected=start))
    assert first.capture == CaptureId(WS, 0)
    same = recorded(save(store, source, b"unchanged"), "unchanged")
    assert same.capture == first.capture
    item.write_bytes(b"two")
    second = recorded(save(store, source, b"second"))
    assert second.capture == CaptureId(WS, 1)
    item.write_bytes(b"one")
    third = recorded(save(store, source, b"third"))
    assert third.capture == CaptureId(WS, 2) and third.snapshot == first.snapshot
    rows, requests, roots, _ = inspect(store.path)
    assert [(row[1], row[2]) for row in rows] == [(0, None), (1, 0), (2, 1)]
    assert requests == {"completed": 4} and roots == 4
    assert store.verify_roots().completed == 4
    assert (
        store.read_snapshot(third.capture, max_file_bytes=64)[(b"file",)].data == b"one"
    )


def test_original_key_and_argument_mismatch(store, source):
    start = store.register_workspace(WS)
    item = source / "file"
    item.write_bytes(b"before")
    initial = recorded(save(store, source, expected=start))
    assert recorded(save(store, source, expected=start)) == initial
    refused(save(store, source), "RequestMismatch")
    item.write_bytes(b"after")
    refused(save(store, source, expected=start), "RequestMismatch")
    assert len(store.history(WS)) == 1


def test_stale_and_failed_observation_preserve_previous_save(store, source):
    start = store.register_workspace(WS)
    original = recorded(save(store, source, expected=start))
    (source / "new").write_bytes(b"later")
    refused(save(store, source, b"stale", expected=start), "Stale")
    (source / ".yeokchamignore").write_bytes(b"*.tmp")
    refused(save(store, source, b"bad-scope"), "IgnoreUnsupported")
    assert store.workspace(WS).cursor == original.capture
    assert store.lookup_request(WS, b"stale") is None
    assert store.lookup_request(WS, b"bad-scope") is None
    assert len(store.history(WS)) == 1


@pytest.mark.parametrize("overlap", ["exact", "ancestor", "descendant", "inside"])
def test_backing_store_overlap_refuses(store, source, overlap):
    store.register_workspace(WS)
    if overlap == "inside":
        with PrivateStore.initialize(source / "backend", REPO) as inner:
            inner.register_workspace(WS)
            refused(save(inner, source), "Scope")
    else:
        path = {
            "exact": store.path,
            "ancestor": store.path.parent,
            "descendant": store.path / "objects",
        }[overlap]
        refused(save(store, path), "Scope")
    assert store.workspace(WS).cursor is None
    assert store.lookup_request(WS, b"key") is None


def test_pending_publication_and_original_arguments_retry(store, source):
    store.register_workspace(WS)
    first = recorded(save(store, source, b"empty"))
    expected = store.workspace(WS)
    item = source / "f"
    item.write_bytes(b"new exact state")

    def fault(event):
        if event == "temp-created":
            raise OSError(errno.EIO, "publication interrupted")

    store.fault = fault
    failed = refused(save(store, source, b"pending", expected), "StorageIO")
    assert failed.snapshot is not None
    assert store.workspace(WS).cursor == first.capture
    assert store.inspect_request(WS, b"pending").closure == "missing"
    store.fault = None
    refused(
        api().resume_save(
            store, WS, snapshot=failed.snapshot, expected=expected, key=b"pending"
        ),
        "Unavailable",
    )
    item.write_bytes(b"other")
    refused(save(store, source, b"pending", expected), "RequestMismatch")
    item.write_bytes(b"new exact state")
    assert recorded(save(store, source, b"pending", expected)).capture == CaptureId(
        WS, 1
    )
    assert len(store.history(WS)) == 2


def test_lost_acknowledgment_recovers_exact_original_after_source_edit(store, source):
    start = store.register_workspace(WS)
    item = source / "f"
    item.write_bytes(b"old version")

    def fault(event):
        if event == "capture-committed":
            raise OSError(errno.EIO, "lost acknowledgment after COMMIT")

    store.fault = fault
    failure = refused(save(store, source, expected=start), "UncertainCommit")
    assert failure.snapshot is not None
    assert failure.observation is not None
    item.write_bytes(b"unrelated later bytes")
    with PrivateStore.open(store.path, REPO) as reopened:
        result = api().resume_save(
            reopened, WS, snapshot=failure.snapshot, expected=start, key=b"key"
        )
        assert result.observation is None
        committed = recorded(result)
        assert committed.capture == CaptureId(WS, 0)
        assert (
            reopened.read_snapshot(committed.capture, max_file_bytes=64)[(b"f",)].data
            == b"old version"
        )
        assert reopened.verify_roots().completed == 1
        refused(
            api().resume_save(
                reopened, WS, snapshot=failure.snapshot, expected=start, key=b"new-key"
            ),
            "Unavailable",
        )
    assert item.read_bytes() == b"unrelated later bytes"


def test_detached_source_capture_closure_and_modes(store, source):
    expected = store.register_workspace(WS)
    large = bytes(range(256)) * 400
    file = source / "script"
    file.write_bytes(large)
    file.chmod(0o755)
    os.symlink(b"outside/\xff", os.fsencode(source) + b"/raw-link")
    (source / "empty").mkdir()
    info = file.stat()
    result = save(store, source, expected=expected)
    final = recorded(result)
    _, _, _, _ = inspect(store.path)
    assert result.observation is not None
    tree = store.read_snapshot(final.capture, max_file_bytes=len(large))
    assert tree[(b"script",)].mode == content.Mode.EXECUTABLE
    assert tree[(b"script",)].data == large
    assert tree[(b"raw-link",)].data == b"outside/\xff"
    assert tree[(b"empty",)].kind == "directory"
    assert file.stat() == info and file.read_bytes() == large


def process_run(conn, store_path, source, workspace, key, expected, mode):
    """Separate process. The barrier follows the first actual source read."""
    with conn, PrivateStore.open(store_path, REPO) as store:
        if mode == "read":
            conn.send(tuple(capture.identity for capture in store.history(workspace)))
            return
        if mode == "barrier":
            data_id = (Path(source) / "f").stat().st_ino
            real_read = os.read
            signalled = False

            def stalled(fd, n):
                nonlocal signalled
                data = real_read(fd, n)
                if data and not signalled and os.fstat(fd).st_ino == data_id:
                    signalled = True
                    conn.send("reading")
                    assert conn.poll(30) and conn.recv() == "continue"
                return data

            with patch("os.read", stalled):
                result = save(store, source, key, expected, workspace)
        else:
            result = save(store, source, key, expected, workspace)
        conn.send(result)


def spawn(store, root, workspace, key, expected, mode):
    ctx = multiprocessing.get_context("spawn")
    parent, child = ctx.Pipe()
    process = ctx.Process(
        target=process_run,
        args=(child, store.path, root, workspace, key, expected, mode),
    )
    process.start()
    child.close()
    return process, parent


def receive(pair):
    process, conn = pair
    assert conn.poll(20), process
    return conn.recv()


def finish(pairs):
    for process, conn in pairs:
        if process.is_alive():
            process.kill()
        process.join(10)
        conn.close()
        assert not process.is_alive()


def test_three_independent_spaces_reader_sql_and_killed_observer(store, source):
    workspaces = [WorkspaceId(bytes([n]) * 16) for n in range(1, 4)]
    roots = [source / str(n) for n in range(3)]
    for root, workspace in zip(roots, workspaces, strict=True):
        root.mkdir()
        (root / "f").write_bytes(b"prior")
        store.register_workspace(workspace)
        assert recorded(save(store, root, b"prior", workspace=workspace)).capture == (
            CaptureId(workspace, 0)
        )
    for n, root in enumerate(roots):
        (root / "f").write_bytes(bytes([n]) * 70000)
    w0, w1, w2 = workspaces
    pairs = []
    try:
        stall = spawn(store, roots[0], w0, b"stalled", store.workspace(w0), "barrier")
        pairs.append(stall)
        assert receive(stall) == "reading"
        with sqlite3.connect(
            store.path / "metadata.sqlite3", timeout=0, autocommit=True
        ) as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("COMMIT")
        reader = spawn(store, roots[2], w2, b"", store.workspace(w2), "read")
        pairs.append(reader)
        assert receive(reader) == (CaptureId(w2, 0),)
        for root, workspace in zip(roots[1:], (w1, w2), strict=True):
            pair = spawn(
                store,
                root,
                workspace,
                b"independent",
                store.workspace(workspace),
                "save",
            )
            pairs.append(pair)
        for n, pair in enumerate(pairs[-2:], start=1):
            outcome = recorded(receive(pair))
            assert outcome.capture == CaptureId(workspaces[n], 1)
            assert (
                store.read_snapshot(outcome.capture, max_file_bytes=70000)[(b"f",)].data
                == bytes([n]) * 70000
            )
        stall[0].kill()
        stall[0].join(10)
        assert stall[0].exitcode == -9
        assert store.workspace(w0).cursor == CaptureId(w0, 0)
        assert store.lookup_request(w0, b"stalled") is None
        assert (
            store.read_snapshot(CaptureId(w0, 0), max_file_bytes=64)[(b"f",)].data
            == b"prior"
        )
        assert store.verify_roots().completed == 5
    finally:
        finish(pairs)


def test_same_space_detached_competitor_cannot_overwrite_cursor(store, source):
    old = source / "old-root"
    new = source / "new-root"
    old.mkdir()
    new.mkdir()
    (old / "f").write_bytes(b"old observation")
    (new / "f").write_bytes(b"new winner")
    expected = store.register_workspace(WS)
    pairs = []
    try:
        contender = spawn(store, old, WS, b"loser", expected, "barrier")
        pairs.append(contender)
        assert receive(contender) == "reading"
        winner = spawn(store, new, WS, b"winner", expected, "save")
        pairs.append(winner)
        won = recorded(receive(winner))
        contender[1].send("continue")
        refused(receive(contender), "Stale")
        assert (
            store.read_snapshot(won.capture, max_file_bytes=64)[(b"f",)].data
            == b"new winner"
        )
        assert store.lookup_request(WS, b"loser") is None
        assert len(store.history(WS)) == 1
    finally:
        finish(pairs)
