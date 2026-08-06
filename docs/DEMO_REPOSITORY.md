# Scripted demonstration repository

## M11-01 vertical slice

`tools/demo/create-repository-v1.sh` creates one new, self-contained local
repository for the downstream M11 demonstrations. It uses only implemented
snapshot/scratch commands: `init`, `checkpoint`, and `timeline`.

The initial snapshot contains regular files, an executable file, and a symlink.
The second checkpoint renames one unchanged file, modifies another, creates a
third, and changes the executable mode. The script records its two printed
checkpoint IDs and timeline under `.yeokcham/` for later demonstrations, so those
logs never become uncheckpointed source changes.

## Reproducibility and ownership

The source bytes, path layout, mode transition, and symlink target are fixed in
the versioned script. Checkpoint object IDs are expected to differ between runs
because checkpoint observation time is immutable evidence. No timing-based
correctness claim is made.

The root must be an absolute, nonexistent directory whose parent already
exists. Creation places an exact ownership marker at
`.yeokcham-demo-owned-v1`. If a creation command fails, the script removes only
that root after rechecking the marker. It never uses an existing directory as a
repository. Cleanup requires the same marker and rejects every other target.

## Setup and cleanup

From the repository root, choose a new directory beneath an existing temporary
directory:

```sh
demo_parent=$(mktemp -d)
demo_root="$demo_parent/yeokcham-demo"
sh tools/demo/create-repository-v1.sh --root "$demo_root"
```

The default script invocation runs the repository-local executable through
`opam exec -- dune exec`. Test callers may set `YEOKCHAM_BIN` to an absolute
already-built executable; it is an internal test seam, not user configuration.

Inspect the generated state with existing commands:

```sh
opam exec -- dune exec bin/yeokcham.exe -- timeline --limit 8 --root "$demo_root"
readlink "$demo_root/current-note"
```

Remove only a root created by this fixture, then its empty parent:

```sh
sh tools/demo/cleanup-repository-v1.sh --root "$demo_root"
rmdir "$demo_parent"
```

## Boundary and verification

The fixture creates no capsule, workspace, conflict, release, Git export,
semantic sidecar, sync state, network service, credential, or benchmark claim.
Shell argument errors and Yeokcham CLI failures are nonzero structured outcomes;
the failure path removes only a newly created, marker-verified fixture root.

`test_demo_fixture` runs creation, checks the exact source oracle and stored
timeline evidence, verifies rejection for an existing target without a Yeokcham
repository, and runs guarded cleanup. `make check` runs that focused test.
