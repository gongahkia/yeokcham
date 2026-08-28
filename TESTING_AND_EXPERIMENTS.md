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
relay listener are built with those core adapters. The transport suite also
passes an end-to-end HTTPS fixture: OpenSSL generates an ephemeral certificate
for a loopback `socat` TLS reverse proxy, while the relay remains a separate
plain-HTTP backend. The production client continues to use its default trust
store; the fixture's `--cacert` path is available only when the explicit
`YEOKCHAM_V4_TEST_TRANSPORT=1` switch is set.

The same fixture runs a two-replica `sync` test that injects a test-only failure
before the first outbound PUT. It proves that received work, its cursor, and
model state survive the upload error; the failed publication is not marked
announced; and a subsequent sync uploads and records it. The TLS tests skip
when either `/usr/bin/openssl` or `/usr/bin/socat` is unavailable, so a skipped
run is not deployment evidence. The latest local Fedora run had both tools and
passed them.

No benchmark, semantic sidecar, Git, or CI delivery result is used as evidence
for the current model.
