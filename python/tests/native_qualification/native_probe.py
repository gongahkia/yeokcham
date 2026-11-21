"""Standalone Linux qualification. Use two disposable roots on different mounts."""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import select
import signal
import stat
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import Mock, patch

DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FILE = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
NOREPLACE = 1
EXCHANGE = 2
CHECKOUT = Path(__file__).resolve().parents[3]


@contextmanager
def opened(path, flags=DIR, *, parent=None):
    fd = os.open(path, flags, dir_fd=parent)
    try:
        yield fd
    finally:
        os.close(fd)


def identity(info):
    return (info.st_dev, info.st_ino, stat.S_IFMT(info.st_mode))


def stamp(info):
    return (
        identity(info),
        info.st_mode,
        info.st_size,
        info.st_nlink,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def sha(data):
    return hashlib.sha256(data).hexdigest()


def refused(call, *errors):
    try:
        call()
    except OSError as exc:
        assert exc.errno in errors, exc
        return errno.errorcode[exc.errno]
    raise AssertionError(f"expected errno {errors}")


def guard_root(path):
    path = Path(path).resolve(strict=True)
    if (
        path.is_relative_to(CHECKOUT)
        or CHECKOUT.is_relative_to(path)
        or {".yeokcham", ".yeokcham-v2"} & set(path.parts)
    ):
        raise ValueError(
            f"fixture root must be outside the checkout and active stores: {path}"
        )
    return path


class Native:
    def __init__(self, library):
        lib = ctypes.CDLL(str(library), use_errno=True)
        self.rename = lib.rename_with_flags
        self.rename.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        self.anchored = lib.anchored_open
        self.anchored.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        self.is_procfs = lib.is_procfs
        self.is_procfs.argtypes = [ctypes.c_int]
        self.casefold = lib.directory_casefold
        self.casefold.argtypes = [ctypes.c_int]
        self.getdents = lib.directory_read
        self.getdents.argtypes = [ctypes.c_int]
        self.getdents.restype = ctypes.c_long

    @staticmethod
    def checked(call, *args):
        result = call(*args)
        if result == -1:
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code))
        return result

    def anchored_call(self, parent, path, flags=FILE):
        return self.checked(self.anchored, parent, path, flags)

    def move(self, left, source, right, destination, flags=NOREPLACE):
        return self.checked(self.rename, left, source, right, destination, flags)


def child_command(library, root, stage, mode):
    return [
        sys.executable,
        "-B",
        __file__,
        "--child",
        str(library),
        str(root),
        stage,
        mode,
    ]


@contextmanager
def claimant(library, root, stage, mode="race"):
    with subprocess.Popen(
        child_command(library, root, stage, mode),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
    ) as process:
        try:
            assert receive(process) == "ready"
            yield process
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)


def receive(process):
    assert select.select([process.stdout], [], [], 10)[0], "child timed out"
    result = process.stdout.readline()
    assert result, "child exited before its evidence boundary"
    return result.decode().strip()


def proceed(process):
    process.stdin.write(b"go\n")
    process.stdin.flush()


def child(library, root, stage, mode):
    native = Native(library)
    root = guard_root(root)
    with opened(root) as parent:
        print("ready", flush=True)
        if sys.stdin.readline() != "go\n":
            return
        try:
            native.move(parent, os.fsencode(stage), parent, b"destination")
        except OSError as exc:
            print(errno.errorcode[exc.errno], flush=True)
        else:
            print("installed", flush=True)
        if mode == "hold":
            sys.stdin.readline()


def observe_regular(root):
    data = bytes(range(256)) * 17
    (root / "f").write_bytes(data)
    with opened(root) as parent, opened(b"f", FILE, parent=parent) as fd:
        before = os.fstat(fd)
        assert stat.S_ISREG(before.st_mode)
        actual = b"".join(os.read(fd, 97) for _ in range(46))
        assert actual == data and os.read(fd, 1) == b""
        assert stamp(before) == stamp(os.fstat(fd))
        assert stamp(before) == stamp(
            os.stat(b"f", dir_fd=parent, follow_symlinks=False)
        )
    return stamp(before), sha(actual)


def changed_while_reading(root, kind):
    (root / "f").write_bytes(b"abcdefgh")
    with opened(root) as parent, opened(b"f", FILE, parent=parent) as fd:
        before = os.fstat(fd)
        first = os.read(fd, 4)
        if kind in {"mutate", "mtime"}:
            with opened(b"f", os.O_WRONLY | os.O_NOFOLLOW, parent=parent) as other:
                assert os.pwrite(other, b"12345678", 0) == 8
            if kind == "mtime":
                os.utime(
                    b"f", ns=(before.st_atime_ns, before.st_mtime_ns), dir_fd=parent
                )
        else:
            (root / "replacement").write_bytes(
                b"abcdefgh" if kind == "equal" else b"12345678"
            )
            os.replace(b"replacement", b"f", src_dir_fd=parent, dst_dir_fd=parent)
        second = os.read(fd, 4)
        after = os.fstat(fd)
        member = os.stat(b"f", dir_fd=parent, follow_symlinks=False)
        if kind == "mtime":
            assert (identity(before), before.st_size, before.st_mtime_ns) == (
                identity(after),
                after.st_size,
                after.st_mtime_ns,
            )
            assert before.st_ctime_ns != after.st_ctime_ns
        if kind in {"mutate", "mtime"}:
            assert first + second == b"abcd5678"
            assert os.pread(fd, 8, 0) == b"12345678"
            assert identity(before) == identity(member) and stamp(before) != stamp(
                member
            )
        else:
            assert first + second == b"abcdefgh"
            assert identity(before) == identity(after) != identity(member)
            assert (root / "f").read_bytes() == (
                b"abcdefgh" if kind == "equal" else b"12345678"
            )
    return {
        "before": stamp(before),
        "held": stamp(after),
        "member": stamp(member),
        "stream_hex": (first + second).hex(),
        "path_hex": (root / "f").read_bytes().hex(),
    }


def mode_fidelity(root, *, change):
    file = root / "program"
    file.write_bytes(b"\r\n\x00\xff")
    file.chmod(0o700 if not change else 0o600)
    with opened(root) as parent, opened(b"program", FILE, parent=parent) as fd:
        before = os.fstat(fd)
        if change:
            file.chmod(0o700)
        after = os.fstat(fd)
        assert identity(before) == identity(after)
        assert os.read(fd, 4) == b"\r\n\x00\xff"
        assert stat.S_IMODE(after.st_mode) == 0o700
        assert bool((before.st_mode ^ after.st_mode) & stat.S_IXUSR) == change
    return stamp(before), stamp(after)


def raw_fidelity(root, kind):
    with opened(root) as parent:
        if kind == "bytes":
            name = b"bad-\xff-\n"
            with opened(
                name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, parent=parent
            ) as fd:
                os.write(fd, b"opaque\x00\xff")
            old_names = [os.fsencode(entry) for entry in os.listdir(parent)]
            with opened(b".", parent=parent) as fresh:
                assert [os.fsencode(entry) for entry in os.listdir(fresh)] == [name]
            with opened(name, FILE, parent=parent) as fd:
                assert os.read(fd, 8) == b"opaque\x00\xff"
            return {
                "name_hex": name.hex(),
                "bytes_hex": "6f706171756500ff",
                "old_directory_fd_names": [entry.hex() for entry in old_names],
            }
        if kind == "empty":
            os.mkdir(b"empty", 0o700, dir_fd=parent)
            with opened(b"empty", parent=parent) as fd:
                assert os.listdir(fd) == []
                return identity(os.fstat(fd))
        os.symlink(b"missing-\xfe\n", b"link", dir_fd=parent)
        assert os.readlink(b"link", dir_fd=parent) == b"missing-\xfe\n"
        error = refused(lambda: os.open(b"link", FILE, dir_fd=parent), errno.ELOOP)
        return {"target_hex": "6d697373696e672dfe0a", "open": error}


def substituted_directory(root, kind, native):
    (root / "d").mkdir()
    (root / "d" / "f").write_bytes(b"original")
    (root / "other").mkdir()
    (root / "other" / "f").write_bytes(b"foreign")
    with opened(root) as parent, opened(b"d", parent=parent) as d:
        (root / "d").rename(root / "held")
        if kind == "symlink":
            (root / "d").symlink_to("other", target_is_directory=True)
            error = refused(
                lambda: os.open(b"d", DIR, dir_fd=parent), errno.ELOOP, errno.ENOTDIR
            )
            assert (
                refused(lambda: native.anchored_call(parent, b"d/f"), errno.ELOOP)
                == "ELOOP"
            )
        elif kind == "parent":
            (root / "d").mkdir()
            (root / "d" / "f").write_bytes(b"foreign")
            error = "membership changed"
            (root / "stage").write_bytes(b"candidate")
            native.move(parent, b"stage", d, b"installed")
            assert (root / "held" / "installed").read_bytes() == b"candidate"
            assert not (root / "d" / "installed").exists()
        else:
            error = refused(
                lambda: os.stat(b"d", dir_fd=parent, follow_symlinks=False),
                errno.ENOENT,
            )
        with opened(b"f", FILE, parent=d) as file:
            assert os.read(file, 20) == b"original"
        held = identity(os.fstat(d))
        assert held == identity(os.stat(b"held", dir_fd=parent, follow_symlinks=False))
        if kind != "rename":
            assert held != identity(os.stat(b"d", dir_fd=parent, follow_symlinks=False))
    return {"held": held, "lookup": error, "bytes_hex": b"original".hex()}


def alias(root, native):
    (root / "a").write_bytes(b"same")
    os.link(root / "a", root / "b")
    with opened(root) as parent:
        info = os.stat(b"a", dir_fd=parent, follow_symlinks=False)
        assert identity(info) == identity(
            os.stat(b"b", dir_fd=parent, follow_symlinks=False)
        )
        assert info.st_nlink == 2
        assert (
            refused(lambda: native.move(parent, b"a", parent, b"b"), errno.EEXIST)
            == "EEXIST"
        )
        assert (root / "a").read_bytes() == (root / "b").read_bytes() == b"same"
    return {"identity": identity(info), "aliases": info.st_nlink}


def special(root):
    os.mkfifo(root / "fifo")
    (root / "denied").write_bytes(b"private")
    (root / "denied").chmod(0)
    with opened(root) as parent:
        assert stat.S_ISFIFO(
            os.stat(b"fifo", dir_fd=parent, follow_symlinks=False).st_mode
        )
        try:
            return refused(
                lambda: os.open(b"denied", FILE, dir_fd=parent), errno.EACCES
            )
        finally:
            (root / "denied").chmod(0o600)


def exclusive(root):
    with opened(root) as parent:
        flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW
        with opened(b"new", flags, parent=parent) as fd:
            assert os.write(fd, b"data") == 4
            os.fsync(fd)
        os.mkdir(b"new-dir", 0o700, dir_fd=parent)
        with opened(b"new-dir", parent=parent) as directory:
            os.fsync(directory)
        os.fsync(parent)
        assert (root / "new").read_bytes() == b"data"
        return [
            refused(lambda: os.open(b"new", flags, dir_fd=parent), errno.EEXIST),
            refused(lambda: os.mkdir(b"new-dir", dir_fd=parent), errno.EEXIST),
        ]


def no_replace(root, native):
    (root / "stage").mkdir()
    (root / "stage" / "item").write_bytes(b"exact")
    (root / "destination").mkdir()
    with opened(root) as parent, opened(b"destination", parent=parent) as original:
        existing = identity(os.fstat(original))
        error = refused(
            lambda: native.move(parent, b"stage", parent, b"destination"), errno.EEXIST
        )
        assert existing == identity(os.stat(b"destination", dir_fd=parent))
        assert os.listdir(original) == []
        stage = identity(os.stat(b"stage", dir_fd=parent))
        native.move(parent, b"stage", parent, b"another")
        os.fsync(parent)
        assert stage == identity(os.stat(b"another", dir_fd=parent))
        assert (root / "another" / "item").read_bytes() == b"exact"
        assert not (root / "stage").exists()
        (root / "f").write_bytes(b"winner")
        (root / "new").write_bytes(b"candidate")
        assert refused(lambda: native.move(parent, b"new", parent, b"f"), errno.EEXIST)
        assert (root / "f").read_bytes() == b"winner"
        assert (root / "new").read_bytes() == b"candidate"
    return {"existing_empty": existing, "refusal": error, "installed": stage}


def concurrent(root, library):
    results = []
    for first, second in [("one", "two"), ("two", "one")]:
        folder = root / first
        folder.mkdir()
        for name in [first, second]:
            (folder / name).mkdir()
            (folder / name / "value").write_bytes(name.encode())
        with (
            claimant(library, folder, first) as a,
            claimant(library, folder, second) as b,
        ):
            proceed(a)
            proceed(b)
            left, right = receive(a), receive(b)
            assert {left, right} == {"installed", "EEXIST"}
            assert a.wait(timeout=10) == b.wait(timeout=10) == 0
        winner, loser = (first, second) if left == "installed" else (second, first)
        assert (folder / "destination" / "value").read_bytes() == winner.encode()
        assert (folder / loser / "value").read_bytes() == loser.encode()
        results.append({"winner": winner, "refused": loser})
    return results


def cross_mount(root, other, native):
    (root / "stage").write_bytes(b"here")
    with (
        TemporaryDirectory(dir=other) as target,
        opened(root) as a,
        opened(target) as b,
    ):
        assert os.fstat(a).st_dev != os.fstat(b).st_dev
        error = refused(
            lambda: native.move(a, b"stage", b, b"destination"), errno.EXDEV
        )
        assert os.listdir(b) == [] and (root / "stage").read_bytes() == b"here"
        return error, [os.fstat(fd).st_dev for fd in [a, b]]


def sync_failure(root, native, directory):
    (root / "stage").write_bytes(b"intact")
    with opened(root) as parent, opened(b"stage", FILE, parent=parent) as file:
        fd = parent if directory else file
        os.fsync(file)
        os.fsync(parent)
        if directory:
            native.move(parent, b"stage", parent, b"destination")
        error = Mock(side_effect=OSError(errno.EIO, "injected fsync failure"))
        with patch("os.fsync", error):
            result = refused(lambda: os.fsync(fd), errno.EIO)
        error.assert_called_once_with(fd)
        pipe = os.pipe()
        try:
            kernel = refused(lambda: os.fsync(pipe[0]), errno.EINVAL)
        finally:
            for end in pipe:
                os.close(end)
        retained, absent = (
            ("destination", "stage") if directory else ("stage", "destination")
        )
        assert not (root / absent).exists()
        assert (root / retained).read_bytes() == b"intact"
    return {
        "injected": result,
        "kernel_pipe": kernel,
        "observed_at": retained,
        "outcome": "uncertain after publication"
        if directory
        else "prepublication refusal",
    }


def terminate(root, library, published):
    (root / "stage").mkdir()
    (root / "stage" / "f").write_bytes(b"complete")
    with opened(root) as parent, opened(b"stage", parent=parent) as staged:
        with opened(b"f", FILE, parent=staged) as file:
            os.fsync(file)
        os.fsync(staged)
        os.fsync(parent)
        stage = identity(os.fstat(staged))
    with claimant(library, root, "stage", "hold") as process:
        if published:
            proceed(process)
            assert receive(process) == "installed"
        process.kill()
        assert process.wait(timeout=10) == -signal.SIGKILL
    retained, absent = (
        ("destination", "stage") if published else ("stage", "destination")
    )
    assert not (root / absent).exists()
    assert identity((root / retained).stat()) == stage
    assert (root / retained / "f").read_bytes() == b"complete"
    return {"SIGKILL": True, "observed_at": retained, "identity": stage}


def publication_edits(root, native, retained):
    (root / "old").write_bytes(b"old")
    (root / "stage").write_bytes(b"new")
    with opened(root) as parent, opened(b"old", os.O_RDWR, parent=parent) as previous:
        old = os.fstat(previous)
        if retained:
            native.move(parent, b"stage", parent, b"old", EXCHANGE)
            before = os.fstat(previous)
            assert identity(os.stat(b"stage", dir_fd=parent)) == identity(old)
            assert (root / "old").read_bytes() == b"new"
            assert os.pwrite(previous, b"out", 0) == 3
            os.utime(root / "stage", ns=(before.st_atime_ns, before.st_mtime_ns))
            after = os.fstat(previous)
            assert (identity(before), before.st_size, before.st_mtime_ns) == (
                identity(after),
                after.st_size,
                after.st_mtime_ns,
            )
            assert (root / "stage").read_bytes() == b"out"
            assert (root / "old").read_bytes() == b"new"
            return {
                "retained_before": stamp(before),
                "retained_after": stamp(after),
                "retained_hex": b"out".hex(),
                "installed_hex": b"new".hex(),
            }
        native.move(parent, b"stage", parent, b"destination")
        destination = root / "destination"
        before_hash = sha(destination.read_bytes())
        destination.write_bytes(b"out")
        after_hash = sha(destination.read_bytes())
        assert before_hash == sha(b"new") and after_hash != before_hash
        assert (root / "old").read_bytes() == b"old"
        return {
            "expected": before_hash,
            "actual": after_hash,
            "preserved_original": True,
        }


def unsupported(root, native):
    (root / "stage").write_bytes(b"safe")
    with opened(root) as fd:
        actual = refused(
            lambda: native.move(fd, b"stage", fd, b"destination", 1 << 31), errno.EINVAL
        )
        with patch.object(
            native, "rename", side_effect=OSError(errno.ENOSYS, "injected")
        ):
            missing = refused(
                lambda: native.move(fd, b"stage", fd, b"destination"), errno.ENOSYS
            )
        assert (root / "stage").read_bytes() == b"safe"
        assert not (root / "destination").exists()
    return {"kernel_unsupported_flag": actual, "injected_syscall_absence": missing}


def anchored_boundaries(root, native):
    (root / "file").write_bytes(b"exact")
    (root / "sub").mkdir()
    (root / "link").symlink_to("sub")
    (root / "fold").write_bytes(b"lower")
    (root / "FOLD").write_bytes(b"upper")
    with opened(root) as fd, opened(b"/") as system:
        with opened(b".", parent=fd) as independent:
            assert native.checked(native.getdents, fd) > 0
            alias_fd = os.dup(fd)
            try:
                assert native.checked(native.getdents, alias_fd) == 0
            finally:
                os.close(alias_fd)
            assert native.checked(native.getdents, independent) > 0
        file = native.anchored_call(fd, b"file")
        try:
            assert os.read(file, 5) == b"exact"
            assert identity(os.fstat(file)) == identity((root / "file").stat())
        finally:
            os.close(file)
        paths = {
            "symlink": refused(
                lambda: native.anchored_call(fd, b"link/child"), errno.ELOOP
            ),
            "absolute": refused(lambda: native.anchored_call(fd, b"/tmp"), errno.EXDEV),
            "parent": refused(
                lambda: native.anchored_call(fd, b"../escape"), errno.EXDEV
            ),
            "mount": refused(lambda: native.anchored_call(system, b"tmp"), errno.EXDEV),
            "not_dir": refused(lambda: os.open(b"file", DIR, dir_fd=fd), errno.ENOTDIR),
        }
        limit = os.fpathconf(fd, "PC_NAME_MAX")
        with opened(b"a" * limit, os.O_WRONLY | os.O_CREAT | os.O_EXCL, parent=fd):
            pass
        paths["too_long"] = refused(
            lambda: os.open(b"b" * (limit + 1), FILE, dir_fd=fd), errno.ENAMETOOLONG
        )
        assert native.checked(native.casefold, fd) == 0
        assert identity((root / "fold").stat()) != identity((root / "FOLD").stat())
        assert (root / "fold").read_bytes() == b"lower"
        assert (root / "FOLD").read_bytes() == b"upper"

    supplied = root / "sub"
    with opened(supplied) as held, opened(root) as base:
        original = identity(os.fstat(held))
        supplied.rename(root / "moved")
        supplied.mkdir()
        assert identity(supplied.stat()) != original == identity(os.fstat(held))
        assert identity(os.stat(b"moved", dir_fd=base)) == original
    return {
        "errors": paths,
        "name_max": limit,
        "casefold": False,
        "fresh_directory_offset_independent": True,
        "absolute_rebinding_detected": True,
    }


def non_atomic(root):
    a, b = root / "a", root / "b"
    a.write_bytes(b"0")
    b.write_bytes(b"0")
    old_a = a.read_bytes()
    a.write_bytes(b"1")
    b.write_bytes(b"1")
    new_b = b.read_bytes()
    assert (old_a, new_b) == (b"0", b"1")
    return {"observed": "01", "actual_schedule": ["00", "10", "11"]}


def bind_child(library, root):
    native = Native(library)
    root = guard_root(root)
    subprocess.run(["mount", "--bind", root / "original", root / "alias"], check=True)
    original = identity((root / "original").stat())
    assert original == identity((root / "alias").stat())
    with opened(root) as fd, opened(b"alias/item", FILE, parent=fd) as plain:
        assert os.read(plain, 5) == b"exact"
        error = refused(lambda: native.anchored_call(fd, b"alias/item"), errno.EXDEV)
    print(json.dumps({"same_dev_and_inode": original, "guarded": error}))


def bind_mount(root, library):
    (root / "original").mkdir()
    (root / "alias").mkdir()
    (root / "original" / "item").write_bytes(b"exact")
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
            __file__,
            "--bind-child",
            str(library),
            str(root),
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def pinned_leaf(root, native):
    (root / "leaf").write_bytes(b"original")
    os.symlink(b"target-\xff", root / "link")
    with opened(root) as fd, opened(b"/proc/self/fd") as proc:
        assert native.checked(native.is_procfs, proc) == 1
        pinned = native.anchored_call(fd, b"leaf", os.O_PATH | os.O_NOFOLLOW)
        link = native.anchored_call(fd, b"link", os.O_PATH | os.O_NOFOLLOW)
        try:
            old = identity(os.fstat(pinned))
            assert stat.S_ISREG(os.fstat(pinned).st_mode)
            assert stat.S_ISLNK(os.fstat(link).st_mode)
            assert os.readlink(b"", dir_fd=link) == b"target-\xff"
            (root / "leaf").rename(root / "held")
            os.mkfifo(root / "leaf")
            member = os.stat(b"leaf", dir_fd=fd, follow_symlinks=False)
            assert stat.S_ISFIFO(member.st_mode) and old != identity(member)
            with opened(str(pinned).encode("ascii"), os.O_RDONLY, parent=proc) as data:
                assert identity(os.fstat(data)) == old
                assert os.read(data, 9) == b"original"
        finally:
            os.close(pinned)
            os.close(link)
    return {
        "opened": old,
        "current_member": identity(member),
        "file_hex": b"original".hex(),
        "link_hex": b"target-\xff".hex(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path)
    parser.add_argument("root", type=guard_root)
    parser.add_argument("other", type=guard_root)
    args = parser.parse_args()
    native = Native(args.library)
    cases = [
        ("01 regular full stream", observe_regular),
        ("02 modified during read", lambda p: changed_while_reading(p, "mutate")),
        ("03 replaced during read", lambda p: changed_while_reading(p, "replace")),
        ("04 equal bytes replaced", lambda p: changed_while_reading(p, "equal")),
        (
            "05 old inode changed with same mtime",
            lambda p: changed_while_reading(p, "mtime"),
        ),
        ("06 mode-only change", lambda p: mode_fidelity(p, change=True)),
        ("07 executable fidelity", lambda p: mode_fidelity(p, change=False)),
        ("08 raw name", lambda p: raw_fidelity(p, "bytes")),
        ("09 empty directory", lambda p: raw_fidelity(p, "empty")),
        ("10 raw symlink target", lambda p: raw_fidelity(p, "link")),
        (
            "11 symlink substitution",
            lambda p: substituted_directory(p, "symlink", native),
        ),
        ("12 directory rename", lambda p: substituted_directory(p, "rename", native)),
        (
            "13 parent substitution",
            lambda p: substituted_directory(p, "parent", native),
        ),
        ("14 hardlink aliases", lambda p: alias(p, native)),
        ("15 special node and permissions", special),
        ("16 exclusive creation and sync", exclusive),
        ("17 existing empty versus absent", lambda p: no_replace(p, native)),
        ("18 concurrent no-replace", lambda p: concurrent(p, args.library)),
        (
            "19 cross-filesystem no-replace",
            lambda p: cross_mount(p, args.other, native),
        ),
        ("20 file fsync fault", lambda p: sync_failure(p, native, False)),
        ("21 directory fsync fault", lambda p: sync_failure(p, native, True)),
        ("22 kill after publication", lambda p: terminate(p, args.library, True)),
        ("23 kill before publication", lambda p: terminate(p, args.library, False)),
        ("24 edits after publication", lambda p: publication_edits(p, native, False)),
        ("25 edits through retained fd", lambda p: publication_edits(p, native, True)),
        ("26 unsupported capability", lambda p: unsupported(p, native)),
        ("27 anchored boundaries", lambda p: anchored_boundaries(p, native)),
        ("28 mixed time observation", non_atomic),
        ("29 same-device bind mount", lambda p: bind_mount(p, args.library)),
        ("30 pinned typed leaf", lambda p: pinned_leaf(p, native)),
    ]
    for name, probe in cases:
        with TemporaryDirectory(prefix="native-m20-", dir=args.root) as root:
            evidence = probe(Path(root))
        print(json.dumps({"case": name, "evidence": evidence}), flush=True)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--child":
        child(*sys.argv[2:])
    elif len(sys.argv) > 1 and sys.argv[1] == "--bind-child":
        bind_child(*sys.argv[2:])
    else:
        main()
