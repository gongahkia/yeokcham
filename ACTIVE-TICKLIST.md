# Active development ticklist

ACTIVE-TICKLIST.md is Yeokcham's sole authoritative development tracker. It records accepted product boundaries, active work, implementation order, and acceptance evidence. GitHub Issues are historical discussion only; do not open, require, or use them as the source of truth for work.

This is a development roadmap, not a release promise. Yeokcham has no public format-compatibility, migration, support, or availability commitment while it remains in development. An unchecked item is a deliberately unimplemented capability, not a claim that the repository already provides it.

## How to use this file

- Start one unchecked milestone only after every listed dependency is complete and its required ADR exists.
- Before code, copy the milestone's vertical slice, types, invariants, tests, and ADR impact into the change description or commit series.
- Check a box only after the listed evidence exists and required verification passes. Add the command and result beside the completed item.
- Update this file in the same change as implementation. Do not create a parallel tracker or close work merely because a prototype exists.
- Record measurements in TESTING_AND_EXPERIMENTS.md. Distinguish local test evidence from deployment, performance, security, or release claims.

## Locked product boundary

| Decision | Chosen boundary |
| --- | --- |
| Product | A model-first, local-first alternative VCS, not Git-compatible or Git-adjacent. Its defining distinction remains separate scratch, intent, and release history. |
| Audience | Trusted technical teams of roughly 2–10 people. Initial practical capacity target: 5 GiB repository, 100,000 paths, 100 Mbps link, and 100 ms RTT. These are targets to measure, not current claims. |
| Intent and conflicts | Never infer intent or auto-merge. Preserve candidate materialisation and require an explicit human resolution. |
| Workspace | Receiving, synchronising, and bootstrap never change ordinary source files. A later explicit projection activation/update is the only shared-work materialisation path. |
| Transport security | HTTPS/TLS plus finite, repository-scoped bearer credentials. The relay is trusted with stored payload bytes; end-to-end payload encryption, mTLS, OIDC, and enterprise identity are outside this roadmap. |
| Transport efficiency | Canonical objects stay byte-identical and uncompressed at rest. Use zstd only on the wire, receiver-aware missing-object negotiation, resumable byte-range transfer, bounded concurrency, and bounded retry. |
| Platforms | Native Linux client is the implementation target. macOS is experimental/deferred; Windows and WSL are unsupported and unplanned. |
| Runtime and delivery | Native Linux client; a signed OCI image for the relay only. Development artifacts are a signed RPM, portable archive, and signed relay OCI image. There is no public release or opam publication plan yet. |
| Operations | Self-hosted single relay node, operator-managed TLS proxy, backups, restore drill, health endpoint, metrics, and quotas. No HA, managed service, or hosted control plane. |
| CLI automation | Human-readable CLI remains primary. New commands expose stable versioned JSON, shell completions, and local post-operation observer hooks. Hooks cannot change VCS success/failure or state. |
| Repository health | verify is read-only. Repair is conservative and human-selected: enumerate all candidates, restore only from explicitly named verified sources, never guess, overwrite, or globally block unrelated work. |
| Interoperability | No Git import/export/bridge. No Subversion, Mercurial, Jujutsu, or other VCS compatibility layer. |

## Cross-cutting invariants

These apply to every milestone below.

- [ ] **Model separation.** Never collapse checkpoint into capsule, capsule into revision, revision into release, conflict into process error, or semantic sidecar into canonical source.
- [ ] **Exact bytes.** Every source operation has a byte-correct canonical representation or explicit fallback; semantic data stays optional sidecar.
- [ ] **Explicit materialisation.** Only an explicitly requested materialise, restore, workspace activation, or workspace update may write ordinary source files. Receipt, receive, sync, bootstrap, relay, verify, and repair planning must not do so.
- [ ] **Immutable publication.** A malformed, partial, unauthenticated, or incorrectly identified object never becomes a canonical local, package, or relay object.
- [ ] **Failure locality.** Damage blocks only the operation requiring the damaged closure. Users can defer repair and continue unrelated work.
- [ ] **Persistent discipline.** Every durable record is explicitly versioned, canonically ordered, feature-gated, fixture-covered, and written without mutating the only valid copy in place. No OCaml Marshal.
- [ ] **Honest interfaces.** Stable JSON has an explicit schema version; unknown mandatory fields/features are rejected; credentials, bearer tokens, and private material are never emitted.

The checkboxes above are verification obligations repeated in each implementation milestone; they do not imply these properties are absent from the current V4 implementation.

## Current milestone — GOV-001: canonical roadmap and tracker migration

**Status:** complete on 2026-09-04. This documentation-only vertical slice established the process required for all subsequent code work. It intentionally changed no V4 model, transport, persistent format, or CLI behaviour. WS-001 is next but must not start until ADR-098 is accepted.

### Scope and invariants

- [x] Make this file the only live work tracker, with enough implementation detail for a coding agent to take one future milestone without reopening the product decisions above.
- [x] Migrate the remaining open GitHub issue obligations into the deferred section below; close the issues only with a migration comment, never as a claim that their original acceptance criteria were implemented.
- [x] Change repository contributor instructions from “linked GitHub issue” to “exact active-ticklist item,” while retaining docs/ISSUE_TRACKING.md as a historical record.
- [x] Preserve old issue numbers and ADR references as history rather than rewriting historical claims.

### Acceptance evidence

- [x] ACTIVE-TICKLIST.md contains the complete accepted boundary, completed governance milestone, ordered planned milestones, exact deferred work, dependencies, interfaces, invariants, and test expectations.
- [x] AGENTS.md, CONTRIBUTING.md, TODO.md, and docs/ISSUE_TRACKING.md point contributors to this file and make no claim that GitHub Issues are a live backlog.
- [x] GitHub #242 and #244 have a migration comment and are closed as superseded/deferred roadmap items.
- [x] git diff --check passed; Markdown links and issue references were reviewed on 2026-09-04.

## Planned milestones

Milestones are strictly ordered. Complete the acceptance evidence of one before starting the next; do not combine them into a broad refactor.

### WS-001 — explicit projection workspace

**Depends on:** GOV-001.
**Required ADR:** ADR-098, “explicit projection workspace activation and update.” It must state that an activated working tree is a projection of a verified imported basis, not a clone, branch checkout, delivery, or authority selection.

**Goal:** make a newly bootstrapped, verified project usable without violating the receipt boundary. Bootstrap already imports verified shared state and creates a local draft; this slice adds an explicit action that materialises the latest verified projection into an empty ordinary root. It must not revise bootstrap, receive, or sync to materialise implicitly.

**Public command contract:**

~~~
yeokcham workspace activate [--root PATH]
yeokcham workspace update [--root PATH] [--replace]
~~~

- workspace activate resolves only the project’s currently verified projection baseline. It requires an empty destination except for repository metadata created by bootstrap; it materialises exact bytes, modes, and symlinks, then writes a durable projection receipt.
- It refuses a nonempty destination, missing/corrupt closure, absent verified baseline, unsafe path, or incompatible existing activation. It never contacts a remote, creates a revision, selects authority, or infers a user choice.
- workspace update is explicit and never called by sync or a daemon. It compares the existing projected worktree with its activation receipt and refuses a dirty tree by default.
- workspace update --replace first creates a regular durable safety checkpoint/proof of the local tree, then materialises the selected verified projection with existing crash-safe restore mechanics. It prints the saved checkpoint/proof identifiers. If preparation fails, it writes no ordinary source bytes.

**Types and pure transitions first:**

- [x] Define a Projection_basis that identifies the verified immutable imported basis and exact snapshot/checkpoint being projected; do not reuse a mutable remote alias as identity.
- [x] Define a versioned Workspace_projection_receipt containing repository identity, basis identifier, snapshot/checkpoint identifier, canonical tree identifier, activation generation, and source-byte fingerprint/root needed to recognise a clean projected tree. It contains no credential or remote URL.
- [x] Define pure activate and plan_update transitions returning a complete materialisation plan or a typed refusal: Nonempty_destination, Dirty_workspace, Missing_closure, No_verified_basis, Receipt_mismatch, or Unsafe_path. They have no filesystem or network dependency.
- [x] State and test: a clean projection receipt maps to exactly one verified tree; a receipt never changes authority/shared history; and an update cannot discard uncheckpointed bytes.

**Persistent adapter and CLI:**

- [x] Add a versioned canonical receipt record and golden fixture under test/golden/v4; reject unknown mandatory features, malformed IDs, version mismatch, and noncanonical bytes.
- [x] Build the materialisation plan with Yeokcham_v4_local_service restore primitives rather than a second tree writer. Keep its prepare/publish/recover journal semantics and write the receipt only after completion.
- [x] Add workspace parsing and concise text output in bin/yeokcham_v4.ml; preserve bootstrap, receive, and sync semantics.
- [x] Add JSON output only when CLI-001 establishes the shared envelope; do not invent a one-off schema. No workspace-specific JSON was added.

**Tests and acceptance:**

- [x] Unit: initial activation, clean update, dirty default refusal, --replace safety checkpoint, empty tree, file/mode/symlink exactness, and all typed refusals.
- [x] Generated: random exact snapshots activate then compare byte/mode/symlink trees; replayed activation/update never changes model state beyond the local receipt.
- [x] Failure: interrupted materialisation, receipt write failure, missing closure, stale receipt, malicious path traversal, and --replace recovery. Verify no source mutation on every refusal/failure.
- [x] CLI journey: bootstrap into an empty directory, explicitly activate, make a local edit, observe default update refusal, use --replace, and restore the printed safety checkpoint.
- [x] Run focused tests plus make ci; add measured duration/path-count notes to TESTING_AND_EXPERIMENTS.md without claiming the capacity target unless EVIDENCE-001 measures it.

**Verification (2026-09-04):** `opam exec -- dune build @fmt @lint @all`,
`opam exec -- dune exec test/test_v4_workspace.exe`,
`opam exec -- dune exec test/v4_workspace_property_test.exe`,
`opam exec -- dune exec test/test_v4_bootstrap.exe`, and
`opam exec -- dune exec test/test_v4_cli.exe` passed. `make ci` passed in 17.6
seconds: it includes the seven-test workspace unit suite, four workspace
property cases (including 30 generated exact activation cases), three bootstrap
tests, and nineteen CLI journeys. See `TESTING_AND_EXPERIMENTS.md` for the
fixture path-count note; this is not capacity evidence.

### TRANSPORT-002 — V2 efficient, resumable object transfer

**Depends on:** WS-001.
**Required ADR:** ADR-099, “V2 compressed and resumable relay transfer.” It must define raw-object identity, transfer-session lifecycle, quotas, retry classifications, and why per-wire compression has no persistent-format effect.

**Goal:** improve the existing HTTPS relay from whole-object retry to receiver-aware, zstd-compressed, resumable raw-byte transfer while preserving the receive-first, no-working-tree-mutation boundary.

**Vertical slice:** one canonical immutable object is capability-negotiated,
range-transferred, resumed from a relay-only session, fully revalidated, and
then published or returned as staged bytes. No V2 operation has a source-tree
adapter, model transition, or materialisation side effect.

**Invariants:** object IDs name raw canonical bytes; ranges cover one exact raw
object without overlap; progress is monotonic and matching duplicates are
idempotent; only a complete, canonical, identity-matching object is published
or returned; cleanup removes temporary session data only.

**Persistent-format impact:** `transfer-session-v1` is a canonical,
versioned relay-local record with golden bytes. zstd frames are wire-only and
never alter canonical object/package/relay bytes.

**CLI contract:** no V2 command is added. Existing object upload uses V2 only
after explicit capability negotiation; V1 remains isolated for an absent V2
endpoint and for non-object routes.

**Protocol decisions that must not be revisited during implementation:**

- Canonical local/package/relay objects remain uncompressed exact bytes. An object ID always names these raw canonical bytes, never a compressed frame.
- Negotiate a V2 capability document before object transfer. The receiver reports its supported protocol version, zstd support, maximum segment size, maximum in-flight segments, and exact missing object IDs.
- Use raw **byte-range** resumption, not object-boundary resumption. Each segment is exactly 1 MiB of raw bytes except the final segment; compress each segment independently with zstd for transport.
- A temporary session is bound to project ID, object ID, raw total size, credential identifier (never its bearer secret), requested scope, expiry, and segment bitmap. It is not a V4 history record and never appears in a package, feed, bootstrap basis, or canonical object store.
- On upload, the relay decodes each segment into a scoped temporary file, validates claimed raw offset/length and bounded decoded output, and persists progress atomically. Completion revalidates full envelope/canonical bytes and object ID before one atomic immutable publish.
- On download, the client validates each decompressed segment range and revalidates full canonical bytes/object ID before import. No partial data enters the V4 store.
- Default parallelism is 4 segments, configurable only down to 1 and up to 8. Retry transient network failures and HTTP 5xx at most four times after the initial idempotent request (five total attempts), with bounded delays of 250 ms, 1 s, 4 s, and 10 s. Never retry auth, capability, range, decompression, canonical-byte, or identity failures.
- V1 remains available in development until V2 has all acceptance evidence; no public compatibility promise follows from retaining it.

**Types and pure transitions first:**

- [x] Add algebraic types for Capability, Object_offer, Missing_set, Range, Segment, Transfer_session, Session_progress, and typed Transfer_error classifications. Bound all sizes/counts before allocation.
- [x] Implement pure capability intersection, missing-object planning, raw range partitioning, legal-progress transition, retry classification, and completion eligibility. Property-test partition coverage, non-overlap, idempotent repeated segment receipt, and monotonic bitmap progress.
- [x] Version the relay-only session record and add canonical fixtures. Session records require expiry cleanup, per-project temporary-byte quota, per-credential session cap, and recovery that never publishes a partial object.

**Adapters and boundaries:**

- [x] Extend Yeokcham_v4_transport, Yeokcham_v4_transport_http, Yeokcham_v4_relay, and Yeokcham_v4_relay_http; keep current V1 routes isolated until V2 evidence is complete.
- [x] Use an OCaml zstd binding only after its license, reproducible build, and Linux/RPM implications are recorded. Reject frames exceeding the claimed raw range or configured decompression budget.
- [x] Make relay expiration/cleanup explicit and observable without exposing bearer tokens. Cleanup never removes an immutable published object.
- [x] Keep sync, receive, bootstrap, and daemon receipt semantics: they may stage/verify objects but never scan, resolve, or materialise source.

**Tests and acceptance:**

- [x] Golden tests for capability/session encoding and negative decode cases.
- [x] Property/fuzz-style tests for arbitrary segment order, duplicates, overlaps, gaps, wrong length, zstd corruption, decompression expansion, and resume after process restart.
- [x] HTTPS relay integration tests for missing-set negotiation, interrupted upload/download and resume, expiry, quota rejection, credential revocation, retry/nonretry classifications, and V1 fallback.
- [x] Regression guard: every success and failure leaves ordinary source bytes unchanged; incomplete sessions cannot be fetched, fed, bootstrapped, or packaged.
- [x] Benchmark a 5 GiB/100,000-path representative fixture or documented scaled equivalent. Record CPU, memory, wall time, wire bytes, resume work avoided, and test hardware/network conditions in TESTING_AND_EXPERIMENTS.md. Do not call the target met without data.

**Verification (2026-09-04):** `opam exec -- dune build @opam`,
`opam lint yeokcham.opam`, `opam exec -- dune build @fmt @lint @all`,
`opam exec -- dune exec test/test_v4_transfer.exe`,
`opam exec -- dune exec test/v4_transport_property_test.exe`, and
`opam exec -- dune exec test/test_v4_transport.exe -- --color never` passed.
The latter ran 18 HTTPS transport cases in 22.255 seconds. `make ci` passed.
`bench/v2_transfer_wire_benchmark.exe` recorded the documented 64 MiB scaled
wire-core result; it is explicitly not the 5 GiB/100,000-path capacity target.

### RELAY-OPS-001 — single-node relay operator product

**Depends on:** TRANSPORT-002.
**Required ADR:** ADR-102, “development relay packaging and operation.” It preserves a separately operated relay and operator-managed TLS boundary.

**Goal:** provide a reproducible, signed OCI relay image for a small trusted team to operate behind its own HTTPS reverse proxy. The image is for the relay, not the native client.

**Vertical slice:** parse one explicit relay configuration, run one non-root
single-node relay with a writable volume, expose liveness/readiness and bounded
aggregate metrics, then back it up and verify a disposable restore. The image
never becomes a V4 receipt or source-materialisation path.

**Types and invariants:** `relay_config`, `config_refusal`, readiness result,
and bounded aggregate counters are operator-only values. Unknown/invalid
configuration fails before serving; non-root runtime writes only its named
volume; health/metrics/logs omit credentials, repository/object identifiers,
payloads, and source paths.

**Persistent-format impact:** no V4 object/package/project format changes.
`relay-config-v1`, if persisted, is local operator configuration; backup and
artifact metadata are external to V4 history.

**CLI/interface contract:** the image entrypoint runs only `relay serve`.
Proxy, Compose/Podman, backup, and signature verification are documented
operator interfaces; no new ordinary source-writing command is authorized.

**Deliverables:**

- [x] A minimal non-root OCI image that runs only the relay service; document its pinned base/toolchain, exposed listen address, writable data volume, read-only root filesystem expectation, and immutable image digest.
- [x] Example Compose/Podman deployment plus Nginx or Caddy TLS proxy example. The relay itself may remain plain HTTP only behind that local proxy; direct public HTTP is not a supported deployment.
- [x] Explicit environment/config schema for storage root, listen address, quotas, session expiry, credential registry location, log level, and health listener. Reject unknown required config keys and never log bearer secrets.
- [x] /healthz liveness and /readyz storage-writability/readiness endpoints; a bounded metrics endpoint reporting aggregate request, object, session, quota, expiration, and failure counters without repository contents or credentials.
- [x] Backup/restore runbook: quiesce or snapshot the volume, checksum the backup, restore to a disposable relay, run read-only verification, then perform a client receive/bootstrap smoke journey. Include an operator retention and restore-drill schedule.
- [x] OCI SBOM/provenance and signature generation/verification in the development artifact pipeline. State signing-key handling and trust root before publishing any image.

**Tests and acceptance:**

- [x] Container integration starts non-root with a mounted empty volume, goes ready through the proxy, performs scoped upload/receive, and persists across restart.
- [x] Negative tests cover no writable volume, invalid config, token redaction, quota/session expiry, health failure, and backup restore corruption.
- [x] Document that this is single-node/self-hosted only; do not imply HA, managed hosting, replication, or end-to-end payload privacy.

**Verification (2026-09-04):** `opam exec -- dune exec
test/test_v4_transport.exe -- --color never` passed 20 cases in 28.060 seconds;
`RELAY_IMAGE=yeokcham-relay:relay-container-test make relay-container-test`
passed the non-root, proxy, restart, backup-corruption, restored-volume
bootstrap, and no-source-mutation journey; and `make ci` passed. Ruby parsed
the artifact workflow YAML and Docker Compose accepted the deployment example
with disposable required path values and a syntactically valid image digest.
The GitHub workflow has not run remotely, so published-image, SBOM,
provenance, and Cosign outputs remain [Unverified]; the checked-in workflow,
not an unpublished artifact, is the completed development-pipeline deliverable.

### HEALTH-001 — read-only verification and human-selected repair

**Depends on:** WS-001 and TRANSPORT-002.
**Required ADR:** ADR-100, “scoped verification and conservative sourced repair.” It must define damage taxonomy, candidate provenance, exact approval binding, and the no-global-block rule.

**Goal:** make local health diagnosable and recoverable without guessed repair or silent loss.

**Public command family:**

~~~
yeokcham verify [--root PATH] [--format text|json]
yeokcham repair plan [--root PATH] --from SOURCE [--format text|json]
yeokcham repair apply [--root PATH] --plan PLAN_ID --select CANDIDATE_ID
  --approve PLAN_DIGEST [--format text|json]
yeokcham repair defer [--root PATH] [--format text|json]
~~~

**Shared-output sequencing:** ADR-101 establishes the pure versioned JSON
envelope early because this command family already requires `--format json`.
That limited formatter is a HEALTH-001 adapter, not the start of hooks,
completions, or broad CLI migration; those remain CLI-001 work after Health's
core acceptance evidence passes.

SOURCE is one explicit trusted candidate source: a local GC quarantine ID, an offline package path, a configured relay alias, a bootstrap artifact, or a backup path. verify never modifies repository or ordinary source bytes. repair plan enumerates every verified candidate and its provenance; it makes no selection. repair apply requires the exact plan digest and candidate ID, revalidates source bytes and current damage immediately before write, and never overwrites a divergent immutable object. repair defer records no repair and leaves unrelated commands usable.

**Types and pure transitions first:**

- [x] Define Damage with stable machine codes for missing object, malformed envelope, canonical-ID mismatch, dangling reference, unreadable durable record, restore-proof mismatch, and unreachable temporary state. Include affected closure and blocked operations.
- [x] Define Repair_source, Repair_candidate, Repair_plan, Selection, and Repair_outcome. A plan is an immutable snapshot of damage, candidate byte identity, source provenance, and expiry/digest.
- [x] Implement pure closure verification, candidate matching, and apply eligibility. Invariants: verification has no writes; repair never invents bytes; all source candidates are fully canonical-verified; repair can only add a missing exact object or explicitly quarantine an invalid copy.

**Adapters and behaviour:**

- [x] Reuse Yeokcham_v4_gc quarantine, Yeokcham_v4_package, relay fetch, bootstrap artifacts, Yeokcham_v4_store, and restore-proof readers through narrow read-only adapters. Do not create an alternate object format.
- [x] Persist repair plans only if needed for cross-process apply; version and expire them outside canonical history. A stale plan refuses and requires a fresh repair plan.
- [x] Local repair writes stage into a new temporary file, validates byte identity, atomically publishes only if the object is still missing, and preserves invalid originals/quarantine evidence. It never overwrites.
- [x] Return structured text and JSON damage/candidate lists. No repair, including a deferred one, may block status, unrelated local saves, inspection of intact history, or work in other repositories.

**Tests and acceptance:**

- [x] Fixtures for every damage code and plan encoding, plus decode corruption and unknown-feature rejection.
- [x] Generated corrupted/missing-closure cases verify stable diagnosis and prove verify produces no file writes.
- [x] Integration journeys restore an exact missing object from each permitted source; test all multiple-candidate selections, stale approval, divergent source, source disappearance, write interruption, and defer/continue work.
- [x] Assert malformed/mismatched candidates never become visible and source/destination ordinary worktrees remain unchanged throughout.

**Verification (2026-09-04):** `opam exec -- dune exec test/test_v4_health.exe`,
`opam exec -- dune exec test/test_v4_health_store.exe`,
`opam exec -- dune exec test/test_v4_health_repository.exe`,
`opam exec -- dune exec test/v4_health_repository_property_test.exe`,
`opam exec -- dune exec test/test_v4_repair.exe`,
`opam exec -- dune exec test/test_v4_cli_data.exe`, and
`opam exec -- dune exec test/test_v4_cli.exe` passed. The focused suites cover
the seven stable damage codes, create-only/canonical repair-plan persistence,
40 generated clean-or-missing closure cases with byte-for-byte no-write
verification, no-global-block behaviour, a target staging-write failure, and
an injected post-fsync staging interruption, and all five explicit repair
sources. The relay-source integration uses an
ephemeral loopback OpenSSL/socat TLS proxy. `make ci` passed (format, lint, and
the complete test suite). This is local adapter evidence only; it makes no
deployment, availability, or capacity claim.

### CLI-001 — dependable machine interface, completions, and observer hooks

**Depends on:** WS-001 and HEALTH-001 for the new commands it exposes.
**Required ADR:** ADR-101, “versioned CLI data and post-operation observers.”

**Goal:** make the native CLI dependable in terminals and scripts without letting scripting alter VCS decisions or outcomes.

**Vertical slice:** one static, pure command specification names every
documented command path, option, option-value kind, and hook eligibility. It
generates Bash, Zsh, and Fish scripts and drives parser-completeness tests.
One local `hooks-v1` record stores explicit argv-list observers; a command
result adapter renders typed public results through ADR-101's existing envelope.
No completion or hook lookup contacts a relay, opens a credential provider, or
changes a V4 model decision.

**Types and invariants:** `command_spec`, `option_spec`, `command_result`,
`command_error`, `hook_id`, `hook_event`, `hook_argv`, `hook_record`,
`hook_registry`, and `hook_event_v1` are algebraic types. A hook event names a
committed local outcome only; it has no authority, intent, checkpoint, capsule,
revision, release, conflict, or semantic-sidecar meaning. The dispatcher uses
an argv-list process launch with a cleared/minimal environment and a bounded
30-second wait. A hook outcome is an ordered public warning, never a VCS
transition or command-status override.

**Persistent-format impact:** `hooks-v1` is a versioned, canonical,
create-or-replace local configuration record below `.yeokcham/hooks/`, outside
canonical history, package, bootstrap, relay, repair-plan, and source trees.
It has golden and negative-decode fixtures; no hook configuration is the sole
copy of a V4 object or authority record.

**CLI additions:**

~~~
yeokcham completion bash|zsh|fish
yeokcham hook add [--root PATH] --event EVENT -- PROGRAM [ARGUMENT ...]
yeokcham hook list [--root PATH] [--format text|json]
yeokcham hook remove [--root PATH] --id HOOK_ID
yeokcham hook test [--root PATH] --id HOOK_ID
~~~

**CLI contract:**

- [x] Add --format text|json to every user-facing successful/result command touched by this roadmap, preserving existing text output until its versioned replacement is documented. JSON top-level is a canonical envelope with schema_version, command, ok, result, warnings, and typed error.
- [x] Define stable error codes, not parsable prose. JSON goes to stdout; diagnostics remain on stderr; exit status remains the command outcome.
- [x] Generate and test Bash, Zsh, and Fish completion scripts from a single command/option specification. Completion never contacts a relay, reads a secret, or mutates a repository.
- [x] Provide yeokcham hook add|list|remove|test for local, versioned hook configuration. A hook is a post-operation observer invoked only after a successful eligible local command has committed state. It gets a versioned JSON event on stdin with public identifiers and paths only.
- [x] Hooks never run for receive, sync, bootstrap, daemon actions, relay server/access commands, verification, repair planning, or a failed operation. Hook nonzero exit, timeout, malformed output, and signal become a warning and never reverse or change VCS success/state.
- [x] Strip bearer tokens, credentials, private keys, secret-service values, passphrases, and raw unredacted configuration from event payloads/logs. Default hook timeout is 30 seconds; run with minimal inherited environment and no shell interpolation.

**Implementation/tests:**

- [x] Define typed command result/event/error records and one canonical JSON encoder/decoder fixture set. Do not hand-assemble JSON in every parser.
- [x] Add parser and completion-generation tests for every command/flag, shell syntax checks, JSON goldens, stdout/stderr/exit-code tests, and text-output regression tests.
- [x] Use an argv-list process launcher, not sh -c. Test spaces, quotes, timeout, signal, missing executable, adversarial environment, and secret redaction. Prove no hook invocation on excluded receipt/daemon paths.

**Verification (2026-09-04):** `opam exec -- dune exec test/test_v4_cli_data.exe`,
`opam exec -- dune exec test/test_v4_cli_spec.exe`,
`opam exec -- dune exec test/test_v4_hook.exe`,
`opam exec -- dune exec test/test_v4_hook_store.exe`,
`opam exec -- dune exec test/test_v4_hook_runner.exe`, and `opam exec -- dune
exec test/test_v4_cli.exe` passed. The focused suites cover canonical JSON and
`hooks-v1` bytes, strict decoder/refusal cases, every documented help path and
completion candidate, Bash/Zsh/Fish syntax, argv quoting, minimal environment,
secret-shaped event refusal, output/nonzero/signal/missing-executable/timeout
warnings, unchanged-save and excluded-verify non-invocation, and JSON
stdout/stderr/exit behavior. The focused command sequence passed in 6.379
seconds; the final `make ci` passed in 2.349 seconds with Dune reusing unchanged
test actions. The optional PKCS#11 hardware case was skipped by its existing
availability guard; it is not CLI-001 evidence.

### DIST-001 — signed development artifacts

**Depends on:** RELAY-OPS-001 and CLI-001.
**Required ADR:** ADR-102 amendment or dedicated distribution ADR if artifact trust boundary differs from relay image.

**Goal:** make development builds reproducible enough for trusted Linux testers without representing them as a stable public release.

**Vertical slice:** a source-commit-pinned Linux x86_64 build emits one
relocatable client archive, one Fedora RPM, one relay OCI build record, SBOMs,
SHA-256 manifest, and CI-only keyless signing bundles. The local test path
verifies layout, checksums, archive/RPM install-uninstall, and disposable
client/relay smoke journeys; it does not publish, mint a maintainer key, or
claim remote OIDC execution.

**Types and invariants:** `development_build_record_v1`, `artifact_digest`,
`artifact_kind`, `signing_bundle`, `signing_identity`, and `smoke_receipt` are
explicit artifact-domain records, never V4 model values. Each artifact binds one
source commit, timestamp, architecture, toolchain/lock inputs, SHA-256, SBOM,
and signing-bundle reference. RPM lifecycle has no service, user, scriptlet, or
source-tree action. A failure may leave only the named disposable artifact
directory; it never materialises ordinary source or rewrites V4 records.

**Persistent-format impact:** `development-build-record-v1.json` and detached
Cosign bundles are external delivery records outside `.yeokcham`, canonical
history, packages, bootstrap, relay storage, and repair plans. They have strict
decoder and golden fixtures. No artifact record is an authority or source of V4
truth.

**CLI contract:** no new V4 command. The archive installs `yeokcham`; package
operations do not invoke the CLI. `yeokcham --version` remains development-only.

**Tests:** pure build-record canonical/negative tests; archive/RPM checksums and
file-list checks; Fedora-container install/uninstall/smoke with an explicit
test signer; OCI layout/SBOM/provenance command checks; and failure assertions
for absent signing bundle, checksum mismatch, and no ordinary-source mutation.

- [x] Produce a portable Linux archive and Fedora RPM for the native client; publish a signed OCI relay image separately. Pin/build-record compiler, Dune/OCaml, OS base, dependency-lock inputs, source revision, artifact SHA-256, SBOM, and signer fingerprint.
- [x] Decide and document development signing root, rotation/revocation process, signature verification commands, and how test users obtain keys. Do not call a tag, artifact, or format stable merely because it is signed.
- [x] Add install/uninstall/smoke verification in clean Fedora containers or VMs. Include init, save, restore, explicit workspace activation, relay sync, and verify journeys. Test that package scripts do not autostart a daemon or alter source outside explicit commands.
- [x] Publish operator/client installation, upgrade, downgrade, backup, and uninstall guidance. Downgrade may refuse incompatible development records; that is preferable to guessed conversion because no migration promise exists.
- [x] Keep opam publication, public source-release tags, support matrix, and format migration policy deferred until an explicit future product decision.

**Verification (2026-09-04):** `make development-artifact-test` passed on the
Fedora 43 Docker host. It built the pinned Linux x86_64 archive and Fedora RPM
with BuildKit SBOM/provenance output, checked the SHA-256 manifest and archive
layout, installed and removed the RPM in a clean Fedora 43 container, and ran
the disposable relay journey through `init`, `save`, `restore`, explicit
workspace activation, `sync`, and `verify`. It also proved the package has no
RPM scriptlets or systemd units and that `sync` did not alter an activated
ordinary source file. `make development-build-record-test`, `make ci`, and a
Ruby YAML parse of `.github/workflows/development-client-artifact.yml` passed.
The local record test covers canonical bytes plus missing-bundle,
checksum-mismatch, and repository-output refusal. The checked-in workflow
implements keyless SHA256SUMS and build-record signing/verification; its
remote OIDC execution, artifact upload, and third-party availability remain
[Unverified] until a maintainer-controlled GitHub Actions run completes.

### EVIDENCE-001 — release-readiness evidence, not a release

**Depends on:** TRANSPORT-002, RELAY-OPS-001, HEALTH-001, CLI-001, and DIST-001.
**Required ADR:** none unless measurement changes product policy; update TESTING_AND_EXPERIMENTS.md, not product claims, with raw conditions/results.

**Goal:** collect evidence needed to decide whether Yeokcham can leave development-only status. This milestone does not authorize a public release.

**Vertical slice:** reproducible, external-only evidence harnesses exercise the
existing WS-001 and TRANSPORT-002 boundaries, while the CI matrix runs the
existing model, golden, fault, package, and OCI checks. Capacity paths stream
one verified package object at a time from the unchanged package-manifest-v1
directory layout; no artifact, staged validation, or import transition may
retain the complete closure's object bytes in process memory. A field-exercise
guide records observations without converting them into model, compatibility,
or support claims.

**Evidence inputs and invariants:** a benchmark profile explicitly names path
count, logical bytes, iterations, transport conditions, and source revision.
Every reported median/tail derives from retained per-run measurements; a
missing condition, failed run, or unavailable external service is recorded as
incomplete evidence, never interpolated. An artifact either owns validated
in-memory test bytes or borrows an on-disk package whose manifest and exact
object-file names were checked; its iterator validates each object identity and
canonical encoding immediately before use.
Harnesses create fixtures only under an explicitly supplied external directory
and never materialise ordinary source through receipt paths. Field observations
name participant count and exercise version but contain no credentials, private
keys, bearer tokens, or payload bytes.

**Persistent-format impact:** none. Streaming changes only the in-process
adapter over the existing canonical package-manifest-v1 and object bytes; it
does not add or alter `.yeokcham` records, history, packages, relay objects,
repair plans, semantic sidecars, or V4 authority. Evidence profiles, raw
measurements, security-review records, and field observations are operational
documents or external files.

**Interface:** no V4 CLI command. Maintainer-only scripts must require an
absolute external output directory and must refuse a repository path. Their
documented output is inspectable plain text or JSONL only.

**Tests:** parser/argument-refusal tests for the evidence harness; a scaled
fixture self-check; streaming package-artifact identity/canonicality and
bounded-retention tests; source-tree non-mutation checks for receipt-oriented
paths; workflow syntax/static-pin checks; and the existing protocol-fault,
package, and OCI smoke suites. Full-capacity runs and human field observations
are separate measurements, not routine CI tests.

- [ ] CI matrix: Linux build/test/format/lint, golden fixture compatibility, package smoke, OCI smoke, protocol fault tests, and a documented optional integration matrix for unavailable hardware/software.
  - Verification (2026-09-05): local `make ci` passed. GitHub-hosted jobs for
    [run 33896347742](https://github.com/gongahkia/yeokcham/actions/runs/33896347742)
    were not started because GitHub reported a failed account payment or
    exhausted spending limit; hosted Linux/macOS and package/OCI evidence remains
    incomplete until billing is restored and a current-revision run completes.
- [x] Security review: bearer-token lifetime/revocation, TLS proxy deployment, relay path traversal/object-ID/range/decompression limits, hook redaction, repair provenance, backup exposure, and image supply chain. Track findings as ticklist items; do not silently accept them.
  - Verification (2026-09-05): Experiment 103 records each boundary, its
    automated evidence, and its explicit limits; `make workflow-security-test`
    and local `make ci` passed. EVIDENCE-SEC-001 resolves the mutable-action
    finding. Hosted build artifacts, external TLS/DNS automation, and off-site
    backup operations remain [Unverified] gaps with stated re-entry conditions,
    not accepted deployment claims.
- [x] EVIDENCE-SEC-001: pin every third-party GitHub Action to the reviewed,
  full commit SHA and record its release tag/SHA mapping. GitHub Actions
  references were mutable tags when this review began; no workflow with
  credentials or OIDC may retain a mutable action reference.
  - Verification (2026-09-04): `make workflow-security-test` passed; Ruby
    parsed all checked-in workflow YAML files and `make workflow-ci-test`
    passed after adding the package-and-OCI smoke job.
- [ ] Benchmark WS-001 and TRANSPORT-002 against capacity target with reproducible fixture generation, stated hardware/network, median and tail results, resource consumption, failure/resume behaviour, and V1 comparison. No cross-VCS performance claim without equivalent public workload/methodology.
  - Verification (2026-09-05): a full WS-001 streaming preflight was
    intentionally terminated after 3h 42m without a measurement row; see
    Experiment 106 for that incomplete preflight, the preceding OOM failure,
    and reduced-profile regression. The required `tc netem` tool is unavailable
    locally: Fedora offers `iproute-tc-6.14.0-2.fc43`, but installing it requires a sudo
    password that is not available to this run. No shaped TRANSPORT-002 row is
    recorded or inferred.
  - Implementation verification (2026-09-05): `make format` and
    `make evidence-workspace-benchmark-test` passed after adding retained
    per-phase scenario diagnostics for interrupted capacity preflights.
- [ ] Run a two-to-ten-person controlled Linux field exercise: bootstrap, activate, concurrent work/explicit resolution, sync interruption, repair/defer, backup restore, credential rotation/revocation, and operator recovery. Record defects/usability observations separately from compatibility or production-support claims.
- [ ] At the end, make a new explicit decision: continue development, define public compatibility/migration policy, or retire/defer. Do not infer it from passing tests.

## Explicitly deferred or out of scope

| ID | Item | Re-entry condition |
| --- | --- | --- |
| DEFER-GIT-001 | Git import, export, bridge, Git hosting integration, or Git-compatible command/format workflow. | Separate product decision and ADR that does not erase Yeokcham's model boundary. |
| DEFER-MERGE-001 | Automatic merge, semantic merge, conflict auto-resolution, or inferred intent. | New proposal with explicit human-choice preservation; not part of this roadmap. |
| DEFER-SEC-001 | End-to-end payload encryption, mTLS, OIDC/SSO, enterprise identity, and hardware fleet management. | New threat model, operator model, ADR, and dedicated tests. |
| DEFER-OPS-001 | HA, replication, managed relay service, hosted control plane, or multi-region operation. | Separate operational product decision and failure model. |
| DEFER-PLATFORM-001 | macOS product support, Windows, and WSL. | Native-platform design/evidence and explicit support policy. macOS remains experimental only. |
| DEFER-UI-001 | GUI, TUI, IDE workflow, web UI, or background auto-sync/materialisation. | Stable native CLI/JSON and separate UX/state-safety design. |
| DIST-OPAM-001 | opam publication and public source package. Migrated from GitHub #244. | Yeokcham adopts public release, source-package, compatibility, and support policy; then re-scope old criteria. |
| MACOS-001 | macOS source-release field trial. Migrated from GitHub #242. | A real signed public source-release candidate and explicit macOS support decision exist. It is not a release gate while development-only. |

## Migrated GitHub issues

| Historical issue | New tracker item | Disposition |
| --- | --- | --- |
| [#242](https://github.com/gongahkia/yeokcham/issues/242) | MACOS-001 | Close after noting that field-trial work is deferred, not completed. Its prior requirement for a real signed source-release candidate is incompatible with current development-only policy. |
| [#244](https://github.com/gongahkia/yeokcham/issues/244) | DIST-OPAM-001 | Close after noting that opam publication is deferred, not completed. It requires a public signed source release and macOS evidence, neither currently intended. |

## Historical references

docs/ISSUE_TRACKING.md remains a historical map of already closed V4 work and ADR evidence. It is not a queue. Existing ADRs and commit messages may continue to mention historical GitHub issue numbers; do not rewrite history to conceal their origin.
