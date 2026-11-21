"""Native observation tests on external disposable noatime Btrfs fixtures."""

import errno
import os
import socket
import stat
import subprocess
import sys
from dataclasses import replace
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest
from conftest import MANIFEST
from hypothesis import given, settings
from hypothesis import strategies as st
from yeokcham import content
from yeokcham.errors import Code
from yeokcham.identities import SnapshotId, StoredObjectId


@pytest.fixture
def source(tmp_path):
    assert not tmp_path.is_relative_to(Path(__file__).resolve().parents[2])
    root = tmp_path / "source"
    root.mkdir()
    return root


def observer():
    from yeokcham import observation

    return observation


def read(root, **kwargs):
    api = observer()
    with api.observe_directory(os.fsencode(root), **kwargs) as result:
        assert isinstance(result, api.ObservedDirectory), result
        found = content.Verifier(result.resolve).snapshot(
            result.snapshot, max_file_bytes=256 * 1024
        )
        return result.snapshot, result.evidence, found


def refused(root, code, **kwargs):
    api = observer()
    with api.observe_directory(os.fsencode(root), **kwargs) as result:
        assert isinstance(result, api.ObservationRefused), result
        assert result.code == code
        return result


def test_empty_repeat_and_closed_resolver(source):
    api = observer()
    with api.observe_directory(os.fsencode(source)) as result:
        assert isinstance(result, api.ObservedDirectory)
        first = result.snapshot
        assert content.Verifier(result.resolve).snapshot(first) == {}
        stamp = source.stat()
        evidence = result.evidence
        assert (evidence.root.device, evidence.root.inode) == (
            stamp.st_dev,
            stamp.st_ino,
        )
        assert evidence.started_ns <= evidence.finished_ns
        assert evidence.elapsed_ns > 0 and evidence.attempts == 1
    with pytest.raises(ValueError, match="closed"):
        result.resolve(StoredObjectId(first.raw))
    assert read(source)[0] == first


def test_reference_mixed_native_bytes(source, corpus):
    (source / "A").write_bytes(b"a\r\nb")
    raw = os.fsencode(source) + b"/bad-\xff"
    with open(raw, "wb") as stream:
        stream.write(b"\0\xff")
    (source / "empty").mkdir()
    (source / "nested").mkdir()
    (source / "nested" / "note").write_bytes(b"end\n")
    (source / "run").write_bytes(b"#!/bin/sh\nexit 0\n")
    (source / "run").chmod(0o755)
    (source / "link").symlink_to("missing/target")
    vector = next(v for v in MANIFEST["trees"] if v["name"] == "RC03-mixed")
    expected = SnapshotId.from_hex(vector["snapshot"])
    api = observer()
    with api.observe_directory(os.fsencode(source)) as result:
        assert isinstance(result, api.ObservedDirectory)
        assert result.snapshot == expected
        seen = set()

        def compare(identity):
            seen.add(identity)
            raw = result.resolve(identity)
            assert raw == (corpus / "objects" / (identity.hex() + ".bin")).read_bytes()
            return raw

        observed = content.Verifier(compare).snapshot(expected)
        assert observed[(b"A",)].data == b"a\r\nb"
        assert observed[(b"run",)].mode == content.Mode.EXECUTABLE
        assert observed[(b"link",)].data == b"missing/target"
        assert observed[(b"empty",)].kind == "directory"
        assert observed[(b"bad-\xff",)].data == b"\0\xff"
        assert observed[(b"nested", b"note")].data == b"end\n"
        assert len(seen) == 9


@pytest.mark.parametrize("size", [1, 65536, 65537, 150000])
def test_nested_streams_and_distinct_paths(source, size):
    (source / "nested").mkdir()
    data = (bytes(range(256)) * 600)[:size]
    a, b = source / "f", source / "nested" / "g"
    a.write_bytes(data)
    b.write_bytes(data)
    before = a.stat()
    _, evidence, tree = read(source)
    after = a.stat()
    assert (
        before.st_mode,
        before.st_atime_ns,
        before.st_mtime_ns,
        before.st_ctime_ns,
    ) == (after.st_mode, after.st_atime_ns, after.st_mtime_ns, after.st_ctime_ns)
    assert tree[(b"f",)].data == tree[(b"nested", b"g")].data == data
    assert tree[(b"f",)].content == tree[(b"nested", b"g")].content
    assert tree[(b"nested",)].kind == "directory"
    assert len(evidence.entries) == 3


def test_opaque_symlink_never_follows(source):
    path = os.fsencode(source) + b"/link"
    os.symlink(b"../../missing-\xfe\n", path)
    assert read(source)[2][(b"link",)].data == b"../../missing-\xfe\n"


def test_hardlink_refuses_even_when_bytes_are_identical(source):
    (source / "a").write_bytes(b"same")
    os.link(source / "a", source / "b")
    refused(source, "UnsupportedNative")


@pytest.mark.parametrize("kind", ["fifo", "socket"])
def test_special_nodes_refuse_before_data_open(source, kind):
    path = source / "special"
    with socket.socket(socket.AF_UNIX) as server:
        if kind == "socket":
            server.bind(str(path))
        else:
            os.mkfifo(path)
        refused(source, "UnsupportedNative")


def test_kernel_regular_only_guards_type_race(source):
    from yeokcham import _observation_linux as native

    with socket.socket(socket.AF_UNIX) as server:
        server.bind(str(source / "socket"))
        os.mkfifo(source / "fifo")
        os.symlink("fifo", source / "link")
        (source / "dir").mkdir()
        fd = os.open(source, os.O_RDONLY | os.O_DIRECTORY)
        try:
            for name in (b"fifo", b"socket", b"link", b"dir"):
                with pytest.raises(OSError) as error:
                    native.open_at(fd, name, native.REGULAR)
                assert error.value.errno in {errno.EFTYPE, errno.ELOOP, errno.EISDIR}
        finally:
            os.close(fd)


def test_regular_only_kernel_refuses_character_device():
    from yeokcham import _observation_linux as native

    fd = os.open(b"/dev", os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        pinned = native.open_at(fd, b"null", native.PIN)
        try:
            assert stat.S_ISCHR(os.fstat(pinned).st_mode)
        finally:
            os.close(pinned)
        with pytest.raises(OSError) as error:
            native.open_at(fd, b"null", native.REGULAR)
        assert error.value.errno == errno.EFTYPE
    finally:
        os.close(fd)


@pytest.mark.parametrize(
    "suffix", [b"/./item", b"/../item", b"//item", b"/bad\0x", b"/" + b"x" * 256]
)
def test_invalid_root_component(source, suffix):
    refused(os.fsencode(source) + suffix, "InvalidRoot")


def test_symlink_in_root_chain_refuses(source):
    (source / "d").mkdir()
    (source / "d" / "real").mkdir()
    (source / "link").symlink_to("d")
    refused(source / "link" / "real", "InvalidRoot")


@pytest.mark.parametrize("name", [".yeokcham", ".yeokcham-v2"])
@pytest.mark.parametrize("location", ["ancestor", "root", "nested"])
def test_reserved_scope(source, name, location):
    nested = source / "nested"
    nested.mkdir()
    base = {"ancestor": source.parent, "root": source, "nested": nested}[location]
    (base / name).mkdir()
    (base / name / "private").write_bytes(b"out of scope")
    refused(source, "Scope")


def test_git_exclusion_and_inert_retained_ignore(source):
    (source / ".git").mkdir()
    (source / ".git" / "metadata").write_bytes(b"excluded")
    rules = b"# comments\r\n\n   \n"
    (source / ".yeokchamignore").write_bytes(rules)
    (source / ".env").write_bytes(b"ordinary")
    tree = read(source)[2]
    assert {path: entry.data for path, entry in tree.items()} == {
        (b".env",): b"ordinary",
        (b".yeokchamignore",): rules,
    }


@pytest.mark.parametrize(
    "rule", [b"!\n", b"../escape\n", b"*.log\n", b"\0", b"#" * 65537]
)
def test_ignore_malformed_effectful_and_oversized_refuse(source, rule):
    (source / ".yeokchamignore").write_bytes(rule)
    refused(source, "IgnoreUnsupported")


def test_ignore_symlink_refuses(source):
    (source / ".yeokchamignore").symlink_to("not-present")
    refused(source, "IgnoreUnsupported")


@pytest.mark.parametrize(
    "bound",
    ["depth", "entries", "path_bytes", "source_bytes", "object_bytes", "objects"],
)
def test_limits_refuse(source, bound):
    deep = source / "deep"
    deep.mkdir()
    (deep / "file").write_bytes(b"abc")
    limits = replace(observer().ObservationLimits(), **{bound: 1})
    result = refused(source, Code.RESOURCE_LIMIT, limits=limits)
    assert result.attempts == 1


def test_read_permission_refusal(source):
    item = source / "denied"
    item.write_bytes(b"private")
    item.chmod(0)
    try:
        assert refused(source, "PermissionDenied").path == (b"denied",)
    finally:
        item.chmod(0o600)


def test_required_native_capability_missing(source, monkeypatch):
    from yeokcham import _observation_linux as native

    def unavailable(*_args, **_kwargs):
        raise OSError(errno.ENOSYS, "unavailable")

    monkeypatch.setattr(native, "open_at", unavailable)
    refused(source, "UnsupportedNative")


def test_same_device_bind_alias_refused(source):
    real = source / "real"
    real.mkdir()
    (real / "payload").write_bytes(b"exact")
    alias = source / "alias"
    alias.mkdir()
    code = """
import os, subprocess, sys
from yeokcham.observation import ObservationRefused, observe_directory
root, real, alias = sys.argv[1:]
subprocess.run(['mount', '--bind', real, alias], check=True)
assert os.stat(real).st_dev == os.stat(alias).st_dev
assert os.stat(real).st_ino == os.stat(alias).st_ino
for path in [root, alias]:
    with observe_directory(os.fsencode(path)) as result:
        assert isinstance(result, ObservationRefused), result
        assert result.code == 'UnsupportedNative', result
"""
    result = subprocess.run(
        [
            "unshare",
            "-Ur",
            "-m",
            "--propagation",
            "private",
            "--",
            sys.executable,
            "-B",
            "-c",
            code,
            str(source),
            str(real),
            str(alias),
        ],
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize(
    "damage,code", [("missing", Code.UNAVAILABLE), ("corrupt", Code.INVALID_ENCODING)]
)
def test_detached_verification_refuses(source, monkeypatch, damage, code):
    api = observer()
    (source / "f").write_bytes(b"payload")
    monkeypatch.setattr(
        api._Detached, "get", lambda *_: None if damage == "missing" else b"broken"
    )
    refused(source, code)


def race_reader(monkeypatch, item, mutation, *, repeating=False):
    real_read = os.read
    hits = 0

    def read_then_change(fd, size):
        nonlocal hits
        info = os.fstat(fd)
        wanted = item.stat(follow_symlinks=False)
        data = real_read(fd, size)
        if (
            data
            and (info.st_dev, info.st_ino) == (wanted.st_dev, wanted.st_ino)
            and (repeating or not hits)
        ):
            hits += 1
            mutation()
        return data

    monkeypatch.setattr(os, "read", read_then_change)
    return lambda: hits


@pytest.mark.parametrize("kind", ["write", "replace", "add", "remove", "mode", "link"])
def test_mid_read_change_retries_with_complete_new_contents(source, monkeypatch, kind):
    item = source / "a"
    data = b"x" * 70000
    item.write_bytes(data)
    other = source / "other"
    other.write_bytes(b"old")
    link = source / "z"
    link.symlink_to("initial")
    old_fd = os.open(item, os.O_WRONLY)

    def mutation():
        if kind == "write":
            before = os.fstat(old_fd)
            assert os.pwrite(old_fd, b"z", 10) == 1
            os.utime(old_fd, ns=(before.st_atime_ns, before.st_mtime_ns))
        elif kind == "replace":
            tmp = source / "temp"
            tmp.write_bytes(data)
            tmp.replace(item)
        elif kind == "add":
            (source / "new").write_bytes(b"new")
        elif kind == "remove":
            other.unlink()
        elif kind == "mode":
            item.chmod(0o755)
        else:
            link.unlink()
            link.symlink_to("changed")

    hits = race_reader(monkeypatch, item, mutation)
    try:
        _, evidence, tree = read(source)
        assert hits() == 1 and evidence.attempts == 2
        assert tree[(b"a",)].data == item.read_bytes()
        assert ((b"other",) in tree) == (kind != "remove")
        assert ((b"new",) in tree) == (kind == "add")
        assert tree[(b"a",)].mode == (
            content.Mode.EXECUTABLE if kind == "mode" else content.Mode.REGULAR
        )
        assert tree[(b"z",)].data == os.readlink(os.fsencode(link))
    finally:
        os.close(old_fd)


@pytest.mark.parametrize("substitute", ["real", "symlink"])
def test_moved_root_cannot_retarget(source, monkeypatch, substitute):
    item = source / "f"
    item.write_bytes(b"original")
    moved = source.with_name("moved")

    def mutation():
        source.rename(moved)
        if substitute == "real":
            source.mkdir()
            (source / "f").write_bytes(b"foreign")
        else:
            source.symlink_to(moved, target_is_directory=True)

    race_reader(monkeypatch, item, mutation)
    assert refused(source, "Unstable").path == ()


def test_parent_change_refuses_obsolete_child_and_retries(source, monkeypatch):
    d = source / "d"
    d.mkdir()
    item = d / "f"
    item.write_bytes(b"old")

    def mutation():
        d.rename(source / "held")
        d.mkdir()
        item.write_bytes(b"new")

    race_reader(monkeypatch, item, mutation)
    _, evidence, tree = read(source)
    assert evidence.attempts == 2
    assert tree[(b"d", b"f")].data == b"new"
    assert tree[(b"held", b"f")].data == b"old"


def test_unstable_after_three_attempts(source, monkeypatch):
    item = source / "f"
    item.write_bytes(b"old")
    fd = os.open(item, os.O_WRONLY)
    try:
        hits = race_reader(
            monkeypatch, item, lambda: os.pwrite(fd, b"n", 0), repeating=True
        )
        outcome = refused(source, "Unstable")
        assert outcome.attempts == hits() == 3
        assert outcome.path == (b"f",)
    finally:
        os.close(fd)


name = st.binary(min_size=1, max_size=10).filter(
    lambda n: (
        b"/" not in n and b"\x00" not in n and n not in (b".", b"..", b".yeokcham")
    )
)


@settings(max_examples=20, deadline=None)
@given(st.dictionaries(name, st.binary(max_size=30), max_size=5))
def test_generated_tree_byte_order_and_exact_content(tmp_path_factory, leaves):
    base = tmp_path_factory.getbasetemp()
    snapshots = []
    for names in (leaves, reversed(tuple(leaves))):
        with TemporaryDirectory(dir=base) as root:
            d = os.fsencode(root) + b"/nested"
            os.mkdir(d)
            for n in names:
                with open(d + b"/" + n, "wb") as stream:
                    stream.write(leaves[n])
            identity, _, entries = read(root)
            assert entries[(b"nested",)].kind == "directory"
            assert {p[-1]: e.data for p, e in entries.items() if len(p) == 2} == leaves
            snapshots.append(identity)
    assert snapshots[0] == snapshots[1]


def test_final_read_compares_bytes_even_when_stat_matches(source, monkeypatch):
    item = source / "f"
    item.write_bytes(b"exact")
    expected = item.stat().st_ino
    real = os.read
    hits = 0

    def mismatching_second_read(fd, size):
        nonlocal hits
        data = real(fd, size)
        if data and os.fstat(fd).st_ino == expected:
            hits += 1
            if hits % 2 == 0:
                return b"x" + data[1:]
        return data

    monkeypatch.setattr(os, "read", mismatching_second_read)
    outcome = refused(source, "Unstable")
    assert outcome.attempts == 3 and hits == 6
    assert outcome.path == (b"f",)
