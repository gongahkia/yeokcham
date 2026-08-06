# Scratch-to-capsule demonstration

## M11-04 vertical slice

`tools/demo/demonstrate-capsule-v1.sh` starts with an M11-01 fixture, makes
three scratch changes, and creates one capsule with caller-supplied stable ID
`1111…1111`. It records the first immutable revision, re-enters the existing
editing flow, folds a later checkpoint, and records the distinct current
revision. `capsule show` verifies exact replay before each display.

The script finally requests a split plan without `--confirm`. The CLI prints
the read-only plan then rejects publication, making the confirmation boundary
visible without manufacturing a second capsule. It creates no semantic intent
inference, workspace, release, Git export, sync state, credential, or model/
persistent-format/ADR change.

## Run and inspect

```sh
demo_parent=$(mktemp -d)
demo_root="$demo_parent/yeokcham-demo"
sh tools/demo/create-repository-v1.sh --root "$demo_root"
sh tools/demo/demonstrate-capsule-v1.sh --root "$demo_root"
```

The script keeps its command evidence under `.yeokcham/` and prints capsule plus
both revision IDs. The capsule ID stays fixed; a fold produces a new immutable
revision. Inspect the replay-validated current object with:

```sh
opam exec -- dune exec bin/yeokcham.exe -- capsule show \
  1111111111111111111111111111111111111111111111111111111111111111 --root "$demo_root"
```

Bad roots, absent ownership markers, repeated execution, malformed CLI output,
and an unexpectedly confirmed split reject nonzero. The unconfirmed split is
not an error in repository state: it is a deliberate read-only plan boundary.

## Verification

`test_demo_capsule` checks stable ID, distinct revision IDs, replay-validated
display, complete two-revision history, exact folded bytes, and the recorded
unconfirmed split plan. `make check` runs the focused test.
