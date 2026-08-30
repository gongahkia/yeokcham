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

Persistent fixtures under `test/golden/v4/` are commitments for the single,
released V4 schemas. Retired pre-release encodings are rejection inputs, not
compatibility or migration fixtures. Tests that inspect or receive a package assert
that invalid input adds neither a destination object nor a state-head update;
the live working tree remains untouched throughout package review and receive.

Inspection verification has textual golden fixtures for empty and linear work,
open decisions, signed resolutions, delivery milestones, deferred review
references, narrow-width wrapping, and authority forks, reconciliation, and
revocation. A generated test permutes model collection order and confirms the
rendered work graph remains identical while the model export is unchanged. CLI
coverage confirms `log`, `graph`, and `graph --authority` neither scan unsaved
working-tree bytes nor change persisted model state.

Transport verification covers canonical publication and local-state goldens,
generated feed validation, same-publisher feed forks, create-only relay
pagination and negative listener requests, atomic two-replica receipt,
idempotent replay, incomplete-closure rejection, signed-resolution receipt,
and a receive-first late-review batch containing a parent and two feed-fork
children. That batch is retried before adoption; every publication remains in
the review inbox and neither retry changes shared state or the working tree.
The HTTPS client and HTTP relay listener are built with those core adapters.
Bootstrap verification adds a canonical `bootstrap-basis-v1` fixture and a
two-replica path from a source repository through an untrusted relay into a
fresh target. It rejects wrong root phrases before creating target state and
only materialises the target working tree after an explicit later `restore`.
The relay test also proves bootstrap entries are SHA-addressed and create-only.
Relay access verification adds a canonical local policy registry fixture and
unit tests for scope, expiry, revocation, rotation, and verifier-only storage.
The listener matrix checks read-only, write-only, cross-repository, expired,
revoked, and rotated-old credentials before immutable storage is called.
The transport suite passes an end-to-end HTTPS fixture: OpenSSL generates an
ephemeral certificate for a loopback `socat` TLS reverse proxy, while the relay
remains a separate plain-HTTP backend. The production client continues to use
its default trust store; the fixture's `--cacert` path is available only when
the explicit `YEOKCHAM_V4_TEST_TRANSPORT=1` switch is set.

A separate malicious TLS peer supplies corrupt publication, manifest, and
object bytes; an absent closure object; a wrong-repository publication; a
publication under the wrong route ID; and a missing causal parent. Each case
proves the peer request reached its injected response and leaves the local
state head, destination object count, transport cursor, and working tree
unchanged.

The same fixture runs a two-replica `sync` test that injects a test-only failure
before the first outbound PUT. It proves that received work, its cursor, and
model state survive the upload error; the failed publication is not marked
announced; and a subsequent sync uploads and records it. TLS tests require
`/usr/bin/openssl` and `/usr/bin/socat`; CI installs both, and missing tools
fail the test rather than producing a skip.

No benchmark, semantic sidecar, Git, or CI delivery result is used as evidence
for the current model.
