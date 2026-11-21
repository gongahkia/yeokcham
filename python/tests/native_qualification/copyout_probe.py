"""Run direct copy-out contrasts against a separately exported historical source."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import os
import shutil
import stat
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

from native_probe import guard_root

REVISION = "fba3daa945eb2c670595ab660576be30b8b3d380"
BINARY_SHA256 = "b5b8528d5aee3ada78dc4bd5c24fd702aa57a0b33dd5d9050551e8e3f0d0aca5"


def evidence(path):
    info = path.lstat()
    item = {
        "dev": info.st_dev,
        "ino": info.st_ino,
        "mode": info.st_mode,
        "mtime_ns": info.st_mtime_ns,
        "ctime_ns": info.st_ctime_ns,
        "nlink": info.st_nlink,
        "size": info.st_size,
    }
    if stat.S_ISREG(info.st_mode):
        data = path.read_bytes()
        item["sha256"] = hashlib.sha256(data).hexdigest()
        item["hex"] = data.hex()
    elif stat.S_ISLNK(info.st_mode):
        item["symlink_hex"] = os.readlink(os.fsencode(path)).hex()
    return item


def inventory(path):
    if not path.exists():
        return None
    out = {".": evidence(path)}
    for base, dirs, files in os.walk(path, followlinks=False):
        for name in sorted(dirs + files, key=os.fsencode):
            entry = Path(base) / name
            out[entry.relative_to(path).as_posix()] = evidence(entry)
    return out


def visibility(inventory):
    return {
        name: (
            stat.S_IFMT(item["mode"]),
            bool(item["mode"] & 0o111) if stat.S_ISREG(item["mode"]) else None,
            item.get("hex"),
            item.get("symlink_hex"),
        )
        for name, item in inventory.items()
    }


def verify(binary, fixture, env, source, live, target, history, node, label):
    verify_dir = source.parent / label
    verify_dir.mkdir()
    replica, dest = verify_dir / "source", verify_dir / "restored"
    replica.mkdir()
    shutil.copytree(source / ".yeokcham", replica / ".yeokcham", symlinks=True)
    dest.mkdir()
    checkpoint = next(
        item["entry"]["checkpoint"]
        for item in history["nodes"]
        if item["entry"]["node"] == str(node)
    )
    journal = replica / ".yeokcham"
    argv = [
        str(binary),
        "restore",
        "--yes",
        "--root",
        str(replica),
        "--checkpoint",
        checkpoint,
        "--destination",
        str(dest),
    ]
    expected = inventory(target)
    before = inventory(dest)
    old = os.open(dest, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        result = subprocess.run(
            argv, env=env, capture_output=True, text=True, check=False
        )
        held = os.fstat(old)
        fresh = os.open(b".", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=old)
        try:
            held_names = os.listdir(fresh)
        finally:
            os.close(fresh)
    finally:
        os.close(old)
    installed = inventory(dest)
    expected_manifest = fixture.inventory(target)
    matches = installed is not None and visibility(expected) == visibility(installed)
    actual_manifest = fixture.inventory(dest) if installed is not None else None
    stage_paths = {
        name: inventory(journal / name) for name in ("restore-staging", "journal")
    }
    retained = [
        stage
        for path, stage in (stage_paths["restore-staging"] or {}).items()
        if path.count("/") == 1
        and path.endswith("/0")
        and (stage["dev"], stage["ino"]) == (held.st_dev, held.st_ino)
    ]
    retained_original = (
        len(retained) == 1
        and (before["."]["dev"], before["."]["ino"]) == (held.st_dev, held.st_ino)
        and not held_names
    )
    result_record = {
        "argv": argv,
        "TMPDIR": env.get("TMPDIR"),
        "node": node,
        "checkpoint": checkpoint,
        "source": str(source),
        "history_entry": next(
            row["entry"]
            for row in history["nodes"]
            if row["entry"]["node"] == str(node)
        ),
        "source_live": inventory(live),
        "source_replica_identity": evidence(replica),
        "expected_tree_sha256": fixture.digest(expected_manifest),
        "actual_tree_sha256": fixture.digest(actual_manifest)
        if actual_manifest is not None
        else None,
        "expected": expected,
        "before": before,
        "retained_descriptor": {
            "dev": held.st_dev,
            "ino": held.st_ino,
            "names": held_names,
        },
        "installed": installed,
        "restoration_metadata_root": sorted(os.listdir(journal)),
        "stage_and_journal": stage_paths,
        "cli_exit": result.returncode,
        "cli_stderr": result.stderr,
        "exact_bytes_and_attributes": matches and expected_manifest == actual_manifest,
        "original_empty_inode_retained": retained_original,
    }
    (verify_dir / "evidence.json").write_text(
        json.dumps(result_record, indent=2) + "\n"
    )
    print(
        json.dumps(
            {
                k: result_record[k]
                for k in [
                    "node",
                    "checkpoint",
                    "expected_tree_sha256",
                    "actual_tree_sha256",
                    "cli_exit",
                    "cli_stderr",
                    "exact_bytes_and_attributes",
                ]
            }
        ),
        flush=True,
    )
    return (
        result.returncode == 0
        and result_record["exact_bytes_and_attributes"]
        and retained_original
    )


def prepare(binary, runner, fixture, root, shape):
    pristine = root / "pristine"
    manifest = fixture.generate(pristine, 8192, 8, "asset", attributes=True)
    source = root / "history"
    shutil.copytree(pristine, source, symlinks=True)
    signers = root / "signers"
    signers.mkdir(mode=0o700)
    env = dict(os.environ, YEOKCHAM_V1_TEST_SIGNER_DIRECTORY=str(signers))
    runner.invoke(runner.command(binary, source, "initial_capture"), env)
    targets = [pristine]
    for node in range(1, 5):
        repeat = shape == "branching" and node == 3
        if shape == "branching" and node in (2, 4):
            runner.invoke(
                [str(binary), "undo", "--yes", "--to", "0", "--root", str(source)], env
            )
        if repeat:
            name = next(
                entry["path"]
                for entry in manifest["entries"]
                if entry["kind"] == "file"
            )
            shutil.copy2(pristine / name, source / name)
            expected = manifest
        else:
            expected = runner.edit(source, manifest, node)
        runner.invoke(runner.command(binary, source, "small_edit"), env)
        target = root / f"target-{node}"
        shutil.copytree(
            source, target, symlinks=True, ignore=shutil.ignore_patterns(".yeokcham")
        )
        fixture.verify(target, expected)
        targets.append(target)
    history = runner.check_history(binary, source, env, 5, 4)
    live = root / "different-live"
    shutil.copytree(targets[-1], live, symlinks=True)
    runner.edit(live, {"entries": fixture.inventory(live)}, -1)
    return env, source, live, history, targets


def run_focused(export, evidence_dir, runner, fixture, trace):
    sys.path.insert(0, str(export / "test"))
    test = importlib.import_module("test_benchmark_runner")
    original_checkpoint = runner.verify_checkpoint
    original_invoke = runner.invoke
    trace_index = 0
    commands = Path(__file__).with_name("trace_copyout_readlink.gdb")

    def traced_invoke(argv, env):
        nonlocal trace_index
        result = subprocess.run(
            [
                "gdb",
                "-nx",
                "-nh",
                "--batch",
                "--return-child-result",
                "-x",
                str(commands),
                "--args",
                *argv,
            ],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        (evidence_dir / f"readlink-{trace_index}.trace").write_text(
            result.stdout + result.stderr
        )
        trace_index += 1
        if result.returncode:
            raise RuntimeError(f"debugger inferior exit {result.returncode} at {argv}")
        return result.stdout, {"seconds": 0.0}

    def checkpoint(binary, root, env, tree, node, expected, scratch):
        def invoke(argv, environment):
            if argv[1] != "restore" or "--destination" not in argv:
                return original_invoke(argv, environment)
            destination = Path(argv[argv.index("--destination") + 1])
            replica = Path(argv[argv.index("--root") + 1])
            prior = evidence(destination)
            try:
                if (
                    trace
                    and node == 0
                    and root.name == "sample"
                    and len(tree["nodes"]) == 1
                ):
                    return traced_invoke(argv, environment)
                return original_invoke(argv, environment)
            except RuntimeError as error:
                metadata = replica / ".yeokcham"
                out = (
                    evidence_dir
                    / f"failure-{len(list(evidence_dir.glob('failure-*')))}"
                )
                out.mkdir()
                actual = fixture.inventory(destination)
                report = {
                    "argv": argv,
                    "TMPDIR": environment.get("TMPDIR"),
                    "source_native": evidence(replica),
                    "live_source": inventory(root),
                    "history": tree,
                    "node": node,
                    "before": prior,
                    "expected_manifest": expected,
                    "actual_manifest": actual,
                    "installed": inventory(destination),
                    "stage": inventory(metadata / "restore-staging"),
                    "journal": inventory(metadata / "journal"),
                    "reported_failure": str(error),
                }
                (out / "evidence.json").write_text(json.dumps(report, indent=2) + "\n")
                raise

        with patch.object(runner, "invoke", invoke):
            return original_checkpoint(binary, root, env, tree, node, expected, scratch)

    suite = unittest.TestSuite(
        [test.RunnerTests("test_resume_preserves_samples_and_refuses_changed_inputs")]
    )
    with patch.object(runner, "verify_checkpoint", checkpoint):
        result = unittest.TextTestRunner(verbosity=2).run(suite)
    return int(not result.wasSuccessful())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export", type=guard_root)
    parser.add_argument("binary", type=Path)
    parser.add_argument("evidence_dir", type=Path)
    parser.add_argument("--focused", action="store_true")
    parser.add_argument("--trace-readlink", action="store_true")
    args = parser.parse_args()
    if args.trace_readlink and not args.focused:
        parser.error("--trace-readlink requires --focused")
    binary = args.binary.resolve(strict=True)
    if hashlib.sha256(binary.read_bytes()).hexdigest() != BINARY_SHA256:
        raise SystemExit("unexpected historical binary")
    parent = guard_root(args.evidence_dir.parent)
    evidence_dir = parent / args.evidence_dir.name
    evidence_dir.mkdir(mode=0o700)
    sys.path.insert(0, str(args.export / "tools"))
    fixture = importlib.import_module("benchmark_fixture")
    runner = importlib.import_module("benchmark_runner")
    if args.focused:
        discovered = args.export / "bin/yeokcham_v1.exe"
        if not discovered.exists() or discovered.resolve() != binary:
            raise SystemExit(
                "focused test must discover the verified binary in the export"
            )
        return run_focused(
            args.export, evidence_dir, runner, fixture, args.trace_readlink
        )
    outcomes = []
    for shape in ("linear", "branching"):
        root = evidence_dir / shape
        root.mkdir()
        env, source, live, history, targets = prepare(
            binary, runner, fixture, root, shape
        )
        (root / "history.json").write_text(json.dumps(history, indent=2) + "\n")
        for node, target in enumerate(targets):
            print(f"{shape} retained-{node}", flush=True)
            outcomes.append(
                verify(
                    binary,
                    fixture,
                    env,
                    source,
                    live,
                    target,
                    history,
                    node,
                    f"retained-{node}",
                )
            )
        sample = root / "sample"
        shutil.copytree(targets[0], sample, symlinks=True)
        runner.invoke(runner.command(binary, sample, "initial_capture"), env)
        sample_history = runner.check_history(binary, sample, env, 1, 0)
        runner.edit(sample, {"entries": fixture.inventory(sample)}, -1)
        print(f"{shape} initial-capture sample", flush=True)
        outcomes.append(
            verify(
                binary,
                fixture,
                env,
                sample,
                sample,
                targets[0],
                sample_history,
                0,
                "initial-sample",
            )
        )
    print(f"{REVISION}: {sum(outcomes)}/{len(outcomes)} exact and successful")
    return int(not all(outcomes))


if __name__ == "__main__":
    sys.exit(main())
