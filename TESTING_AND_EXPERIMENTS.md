# Testing and experiments

`opam exec -- dune build @all` and `opam exec -- dune runtest` are the active
local verification commands. The suite covers V4 model transitions, generated
model and authority properties, canonical goldens, store compare-and-swap,
restore journal recovery, package object closure and causal checks, device
rotation, branch-scoped authority actions and explicit reconciliation, recovery,
phrase-checked join, and no-working-tree-mutation receive.

The current Darwin implementation check is green for the focused suite. This
does **not** prove the Linux watcher. On a Linux host, run:

```sh
opam exec -- dune exec test/test_v4_watch.exe
```

Pass requires the real inotify process loop to observe a file change, debounce,
call V4 capture, and produce a new checkpoint. A Darwin refusal test cannot
substitute for this evidence. Record host, kernel, inotify limits, timing, and
any leaked watcher process with the result.

Persistent fixtures under `test/golden/v4/` are compatibility commitments for
the active V4 record schemas. Tests that inspect or receive a package assert
that invalid input adds neither a destination object nor a state-head update;
the live working tree remains untouched throughout package review and receive.

No benchmark, transport, semantic sidecar, Git, or CI delivery result is used
as evidence for the current product model.
