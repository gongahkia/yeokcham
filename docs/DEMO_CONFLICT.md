# Persistent localised conflict demonstration

## M11-06 vertical slice

`tools/demo/demonstrate-conflict-v1.sh` starts from the M11-01 fixture's
initial checkpoint and creates three independent immutable capsule revisions:
two exact writes to `docs/todo.txt` and one write to
`conflict-unrelated.txt`. A workspace selects them in that explicit order.

Materialisation applies the first write, records the second as a persistent
`competing-edits` conflict, and continues with the unrelated write. The script
records the conflict ID and its structured kind, paths, and
`skip-operation` candidate. It then proves that the unsupported `replace`
action rejects without changing the current workspace, explicitly records a
`skip` resolution, re-shows the immutable conflict, and materialises the
resolution-bound workspace revision.

`skip` does not synthesize replacement bytes or resolve semantics. It binds an
immutable resolution to the exact failed `(capsule revision, operation index)`;
the original conflict remains inspectable by ID. This is Yeokcham workspace state,
not a Git branch, merge, or conflict-marker file.

## Run and inspect

```sh
demo_parent=$(mktemp -d)
demo_root="$demo_parent/yeokcham-demo"
sh tools/demo/create-repository-v1.sh --root "$demo_root"
sh tools/demo/demonstrate-conflict-v1.sh --root "$demo_root"
```

Before skip, `.yeokcham/demo-v1-conflict-partial` reports `partial=true`,
`docs/todo.txt` retains `first conflicting bytes`, and
`conflict-unrelated.txt` contains its exact independent bytes. The conflict
files show its stable ID before and after skip; the active list is empty only
after a later immutable workspace revision binds the explicit resolution.
`.yeokcham/demo-v1-conflict-complete` then reports `partial=false`.

Bad roots, unowned fixtures, invalid initial checkpoint IDs, repeated runs,
malformed command results, failed transitions, or an accepted unsupported
resolution action reject nonzero. The unsupported action's pre/post workspace
records are byte-identical. The script changes only an owned fixture and keeps
all command evidence under its `.yeokcham/` directory.

No model type, persistent format, ADR, `yeokcham` CLI behavior, semantic
resolution, materialisation guarantee, release, Git export, sync state, or
performance claim is added.

## Verification

`test_demo_conflict` creates the owned fixture and checks partial continuation
on the unrelated path, the structured immutable conflict display, unchanged
state after the unsupported action, explicit skip, post-skip conflict
inspectability, and complete rematerialisation. `make check` runs the focused
test.
