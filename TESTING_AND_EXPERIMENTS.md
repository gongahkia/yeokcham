# Testing and experiments

`opam exec -- dune build @all` and `opam exec -- dune runtest` are the active
local verification commands. The suite covers V4 model transitions, generated
model and authority properties, canonical goldens, store compare-and-swap,
restore journal recovery, package object closure and causal checks, device
rotation, branch-scoped authority actions and explicit reconciliation, recovery,
phrase-checked join, signed resolution purpose, and no-working-tree-mutation
receive. The package resolution test delivers conflicting shared work and its
signed resolution in an order requiring deferral, then proves it recreates a
resolved decision rather than a third shared change.

The Linux watcher loop passed on Linux 7.1.9-100.fc43.x86_64 during the latest
full local suite. On a Linux host, rerun:

```sh
opam exec -- dune exec test/test_v4_watch.exe
```

Pass requires the real inotify process loop to observe a file change, debounce,
call V4 capture, and produce a new checkpoint. This one-host result does not
establish macOS or WSL watcher support. Record host, kernel, inotify limits,
timing, and any leaked watcher process with future results.

Persistent fixtures under `test/golden/v4/` are compatibility commitments for
the active V4 record schemas. Tests that inspect or receive a package assert
that invalid input adds neither a destination object nor a state-head update;
the live working tree remains untouched throughout package review and receive.

Transport verification currently covers canonical publication and local-state
goldens, generated linear-feed validation, create-only relay pagination,
atomic two-replica receipt, idempotent replay, and a late-revoked record
entering the review inbox without changing the model. The HTTPS client and HTTP
relay listener are built with those core adapters. An end-to-end reverse-proxy/
TLS fixture and an injected post-receive upload interruption test remain
required before claiming deployment-level relay integration evidence. No
benchmark, semantic sidecar, Git, or CI delivery result is used as evidence for
the current model.
