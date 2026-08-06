# Multiple enabled capsules demonstration

## M11-05 vertical slice

`tools/demo/demonstrate-workspace-v1.sh` creates two caller-ID capsules from
the M11-01 fixture, resolves the original changed checkpoint to its exact
snapshot through the read-only `workspace_base_v1` helper, and creates one
durable workspace. It enables both immutable revisions, records explicit order,
disables only the second capsule, then re-enables that same revision and records
the order again.

The helper reads a verified checkpoint and prints its snapshot object ID. It
does not write a ref, object, index, workspace, or source file. The workspace
is Yeokcham selection state; no Git branch is created, inspected, or implied.

## Run and verify

```sh
demo_parent=$(mktemp -d)
demo_root="$demo_parent/yeokcham-demo"
sh tools/demo/create-repository-v1.sh --root "$demo_root"
sh tools/demo/demonstrate-workspace-v1.sh --root "$demo_root"
```

The final `.yeokcham/demo-v1-workspace-order-final` contains the same two ordered
revision IDs passed to `work reorder`. `.yeokcham/demo-v1-workspace-disabled`
contains only the first selection; re-enabling restores the second selection
without changing either capsule or revision identity.

Bad roots, unowned fixtures, missing base checkpoints, repeated runs, invalid
helper output, or failed workspace transitions reject nonzero. No model schema,
ADR, `yeokcham` CLI behavior, materialisation, conflict, release, Git export,
sync state, or performance claim is added.

`test_demo_workspace` covers two selected revisions, deterministic explicit
order, independent disable/re-enable, and the read-only helper. `make check`
runs the focused test.
