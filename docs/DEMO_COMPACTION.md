# Scratch compaction demonstration

## M11-03 vertical slice

`tools/demo/demonstrate-compaction-v1.sh` operates on an M11-01 fixture. It
pins the initial logical checkpoint, waits three seconds before creating a
known later head, and uses a fixed retention policy at an observed host time:
one recent second, no periodic retention, and no storage budget. The wait makes
the intermediate fixture checkpoint expired while retaining the head; it is
not a performance measurement or timing-based correctness claim.

The script records the existing `compact --dry-run --explain`, activation,
`--resume`, and retained-ID restore-plan outputs under `.paengi/`. The active
generation preserves logical checkpoint IDs while it may replace their physical
event/checkpoint representation. No model type, persistent schema, ADR, CLI
command, semantic sidecar, network state, or benchmark claim is added.

## Run it

```sh
demo_parent=$(mktemp -d)
demo_root="$demo_parent/paengi-demo"
sh tools/demo/create-repository-v1.sh --root "$demo_root"
sh tools/demo/demonstrate-compaction-v1.sh --root "$demo_root"
```

The recorded dry-run names exact cleanup candidates, expected object types, and
stored object-file bytes. Activation rederives that plan and quarantines only
superseded scratch records. `--resume` is intentionally run after activation;
its idempotent report may say that candidates are already quarantined.

The script dry-runs both retained logical IDs after activation. The focused test
also materialises each to prove its bytes, mode, and symlink target remain
exact. It does not claim that unretained logical checkpoints remain resolvable.

## Quarantine and prune

The default command never prunes. It leaves superseded scratch records beneath
`.paengi/trash/<generation-id>/`, where they remain a local recovery artifact
outside normal retained-ID resolution. Pass `--prune` only for a disposable
fixture root after inspecting activation and quarantine output:

```sh
sh tools/demo/demonstrate-compaction-v1.sh --root "$demo_root" --prune
```

`compact --prune` permanently removes quarantined objects. The script refuses
to rerun for one root, so a new fixture is required to demonstrate prune. It
does not promise rollback, cross-domain garbage collection, recovery of an
unretained ID, or restoration of a pruned object.

## Verification and errors

The script validates its ownership marker and stored initial checkpoint before
it pins or edits anything. Existing demonstration state and invalid roots reject
nonzero. `test_demo_compaction` checks dry-run/activation/resume evidence,
exact materialisation of retained IDs, no default prune file, and explicit prune
in a separately created disposable fixture. `make check` runs that focused
coverage.
