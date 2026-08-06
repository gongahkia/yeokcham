# Automatic recovery demonstration

## M11-02 vertical slice

`tools/demo/demonstrate-recovery-v1.sh` operates on a root created by the
M11-01 fixture. It introduces known divergent bytes, an uncheckpointed file, a
mode change, and a symlink-target change. It then dry-runs and restores the
stored initial checkpoint.

The existing restore core first creates a durable safety checkpoint for the
divergent working directory, then applies the target plan and rescans it. The
script records the dry-run, restore output, and post-restore timeline under
`.paengi/`, then reports both the restored target and safety checkpoint ID.

No model type, persistent format, ref schema, ADR, CLI command, or automatic
watcher is introduced. This is a deterministic demonstration of existing
guarded restore behavior.

## Run it

Create a fixture first, then run recovery against that exact root:

```sh
demo_parent=$(mktemp -d)
demo_root="$demo_parent/paengi-demo"
sh tools/demo/create-repository-v1.sh --root "$demo_root"
sh tools/demo/demonstrate-recovery-v1.sh --root "$demo_root"
```

After success, the initial snapshot is restored exactly:

- `README.md` exists and `CHANGELOG.md` does not;
- `docs/todo.txt` contains its initial bytes;
- `divergent.txt` and `notes.txt` do not exist;
- `bin/run-demo` is executable; and
- `current-note` targets `docs/todo.txt`.

The recovery script requires the fixture ownership marker and exact 64-digit
initial checkpoint ID before it changes the working directory. Bad arguments,
missing fixture state, and invalid IDs reject nonzero before recovery changes.

## Safety limitation

Restore is guarded, not crash-atomic for a populated working directory. A
reported I/O failure can leave a partially applied target; Paengi retains the
reported safety checkpoint so the user can inspect and restore it explicitly.
This successful demo does not simulate a filesystem I/O failure and does not
claim that restore cannot partially apply during a process or host failure.

The script creates no capsule, workspace, conflict, release, Git export,
semantic sidecar, sync state, network service, credential, or performance
claim. Remove the root with `cleanup-repository-v1.sh` only after inspecting
the recovery evidence.

## Verification

`test_demo_recovery` creates the fixture, runs recovery, checks the exact
regular-file bytes, executable mode, symlink target, absent divergent paths,
and that the reported safety checkpoint resolves through `restore --dry-run`.
It also verifies that an unowned root is rejected before any recovery state
changes. `make check` runs this focused test.
