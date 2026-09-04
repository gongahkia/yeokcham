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

On 2026-09-04, the Fedora 43 source-checkout run of `make ci` passed after the
V4 onboarding and exact-local-inspection slice. The new service case compares
the active saved checkpoint with a current scan containing a directory create,
nested file create, file-content change, mode-only change, and deletion; it
asserts canonical path order, an explicit empty result after save, unchanged
state-head model, and unchanged live bytes. The CLI cases exercise top-level,
family, and every documented command-path help; unreleased source version
output; invalid-invocation failure; and the same exact `changes` output and
non-mutation boundary. No persistent record or golden fixture changed. The
separate `make release-verify-test` run also passed. The optional PKCS#11
integration remained skipped because `YEOKCHAM_V4_TEST_PKCS11_MODULE` was not
configured; that is not hardware-token evidence.

External-LSP verification adds a canonical `semantic-lsp-v1` local-config
fixture, restrictive file-mode, duplicate, matcher, and invalid-glob checks.
A compiled disposable fake server proves that initialization reports its
declared name/version/capabilities against named temporary snapshot URIs; that
same-symbol evidence remains advisory; and that `workspace/applyEdit`,
malformed JSON-RPC, oversized packets, and timeout return unavailable advice
without modifying repository bytes. The fake server is protocol-boundary
evidence only, not evidence that a real language server is correct for a
language or that semantic advice is trustworthy.

Custody verification adds a canonical local `custody-v1` fixture, restrictive
file-mode and create-only checks, an actual temporary OpenSSH agent with one
selected Ed25519 key, and an opaque-provider denial path. It also includes a
disposable-token integration test when
`YEOKCHAM_V4_TEST_PKCS11_MODULE` names a SoftHSM-compatible PKCS#11 module.
That test creates a sensitive non-extractable Ed25519 key, proves private bytes
are unavailable to V4, and signs a certificate, authority epoch, shared
revision, decision resolution, authorization, and adoption. It separately
checks wrong-PIN denial, unavailable provider, discovered-public-key mismatch,
and an external-signature refusal during rotation while comparing the complete
repository byte tree before and after. The current Fedora 43 local run used a
disposable SoftHSM 2.6.1 token; it is software-token interface evidence, not a
claim of physical-token coverage. CI creates an equivalent disposable token on
Linux and macOS; its results remain the CI record rather than a local claim.

Restore-proof verification adds a canonical `restore-proof-v1` fixture,
malformed-record rejection, explicit forget, interrupted/restarted restore,
legacy published-journal retain, and corruption-before-compaction tests. The
service test proves a completed journal may be pruned only after its safety and
target snapshots are explained by a durable proof, and proves a corrupt proof
does not advance the project-state head.

Local collection verification adds a canonical `gc-transaction-v1` fixture,
pure generated root classification, and integration tests for quarantining an
orphan, explicit restore, explicit purge, a purge restart after its durable
marker, retained large chunk-manifest and shared-revision closures, an empty
worktree, retained restore-proof closure, a state-head change after quarantine,
and corrupt or missing reachable objects. The CLI journey compacts old
checkpoints, reviews the dry-run explanation, stages a transaction, inspects
it, restores it, then explicitly stages and purges it. This is local storage
evidence only; it does not claim relay, package, or automatic cleanup.

The Linux watcher loop passed on Linux 7.1.9-100.fc43.x86_64 during the latest
full local suite. On a Linux host, rerun:

```sh
opam exec -- dune exec test/test_v4_watch.exe
```

Pass requires the real inotify process loop to observe a file change, debounce,
call V4 capture, and produce a new checkpoint. This one-host result does not
establish any other platform's watcher support. WSL is unsupported, not
planned, and supplies no future platform evidence. Record host, kernel, inotify
limits, timing, and any leaked watcher process with future results.

The macOS FSEvents source and foreground watcher loop passed on macOS 15.7.7
(24G720), x86_64, on the local APFS data volume on 2026-08-31. The focused
native source suite (seven tests, 0.77 seconds) observed create, modify, delete,
and one-sided rename notifications; it verified conservative coalescing/loss
normalization, idempotent close, root-loss restart, and a 200-rename storm. A
metadata write was also delivered as an ambiguous root/ancestor event on this
host, so the adapter correctly widened it to an exact whole-root scan instead
of claiming it was safe to ignore. The three-test foreground CLI loop took
4.51 seconds and verified an exact post-debounce checkpoint, one recorded
checkpoint for a rapid edit storm, and exit status 2 after permanent root loss.
This is single-host adapter evidence only; it does not establish Linux,
daemon, WSL, source-release, or release support. Re-run on a macOS host:

```sh
opam exec -- dune exec test/test_v4_macos_watcher.exe
opam exec -- dune exec test/test_v4_watch.exe
```

The Linux background-runtime executable test passed on Linux
7.1.9-100.fc43.x86_64 during the latest local suite. On a Linux host, rerun:

```sh
opam exec -- dune exec test/test_v4_runtime.exe
```

It starts a real detached daemon in a fresh mode-0700 `XDG_RUNTIME_DIR`, checks
its private versioned state and duplicate-start refusal, observes a debounced
checkpoint after a file edit, hard-kills and restarts it, rejects a missing XDG
runtime directory, and proves a failed explicit sync leaves ordinary file bytes
and the checkpoint unchanged. This is Linux-only lifecycle evidence, not a
claim that a system service, another platform, or a remote scheduler was
tested.

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

## TRANSPORT-002 V2 resumable transfer

On 2026-09-04, the focused V2 core suite passed eight unit cases and the
generated transport suite passed three properties. They cover canonical
capability/session fixtures, noncanonical and malformed bitmap rejection,
missing-set planning, range coverage/non-overlap, arbitrary segment order,
idempotent duplicates, wrong length/overlap/gap rejection, session restart,
credential session cap, quota/expiry cleanup accounting, zstd corruption, and
decompression expansion refusal.

The complete 18-case HTTPS transport suite passed in 22.255 seconds on the
Fedora 43 host. It includes actual loopback TLS upload/resume/download of a
multi-range canonical object, default bounded V2 object upload, explicit V1
fallback when V2 negotiation is unavailable, 5xx retry and 401 non-retry,
revocation, existing two-replica receipt/sync failure paths, and an ordinary
source-file sentinel unchanged across V2 success and failure. The fixture uses
a separate plain HTTP relay behind an ephemeral OpenSSL/socat TLS proxy; it is
adapter-boundary evidence, not public deployment evidence.

The documented 64 MiB V2 wire-core scaled measurement is in
[`docs/experiments/099-v2-transfer-wire-benchmark.md`](docs/experiments/099-v2-transfer-wire-benchmark.md).
It reports CPU, memory, wall time, wire bytes, and resume work avoided. It is
not the 5 GiB/100,000-path target and makes no capacity claim.

No semantic sidecar result is used as evidence for the current model, delivery,
or authority. The local fake-server results above establish only the adapter
boundary; future real-server experiments must record language, server/version,
host, useful observations, unavailable cases, and false or stale suggestions
separately from product claims. Git and CI delivery results are likewise not
model evidence.

Source-release verification uses an isolated GnuPG home and disposable Git
repository. It proves a valid annotated signed tag, exact source commit,
full-fingerprint match, and archive SHA-256 route; it also proves primary and
signing-subkey fingerprint matching for a subkey signature. It then rejects
missing input, malformed fingerprints, lightweight and unsigned tags,
mismatched signers, wrong commits, and changed archives. The fixture creates no
`.yeokcham` directory. It is supply-chain adapter evidence only: its temporary
key is not a maintainer key, and passing it does not claim a V4 release, source
hosting, platform support, or opam publication.

## WS-001 explicit projection workspace

On 2026-09-04, `make ci` passed in 17.6 seconds. Its WS-001 coverage includes
the seven-test workspace unit suite (pure plans/refusals and canonical local
records), four workspace property cases, the three-test bootstrap suite, and
the nineteen-test CLI suite. The generated property executes 30 exact
activation cases; each has two regular source paths and an optional symlink,
while the bootstrap fixture separately covers one regular path, one executable
path, and one symlink. It also checks an empty tree, missing snapshot closure,
receipt-stage failure before source output, stale receipt refusal, resumable
pending activation, clean-state replay, and `--replace` safety recovery.

These are small correctness fixtures only. They do not measure object-count,
repository-size, transfer, latency, or concurrency capacity; EVIDENCE-001 owns
any such claim.
