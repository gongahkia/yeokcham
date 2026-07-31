# Implementation TODO

This roadmap is ordered. Do not start later phases before the current phase's exit criteria are met.

## Milestone 0 — Repository foundation

### Project setup

- [x] Create Rust workspace.
- [x] Add formatting, linting, unit-test, and documentation CI.
- [x] Define supported Rust version.
- [x] Add licence and contribution guide.
- [x] Add `docs/adr/` process.
- [x] Add structured error type strategy.
- [x] Add tracing with source-content redaction rules.
- [x] Add fixture-generation scripts.
- [x] Add benchmark-result schema.
- [x] Add reproducible development commands through `just`, `make`, or `cargo xtask`.

### Core types

- [x] Define `RepositoryId`.
- [x] Define `GitObjectId`.
- [x] Define `yeokchamContentId`.
- [x] Define `SegmentId`.
- [x] Define `ManifestId`.
- [x] Define `DeviceId`.
- [x] Define `RefName` with validation.
- [x] Define repository format version and feature flags.
- [x] Define serialisation policy and canonical encoding rules.

### Exit criteria

- [x] CI passes on macOS and Linux.
- [x] Empty repository format can be created, reopened, and migrated.
- [x] Public types have invariants documented.
- [x] No implementation code depends directly on a cloud backend.

## Milestone 1 — Local storage proof

### Git import

- [x] Open an existing Git repository.
- [x] Enumerate refs.
- [x] Traverse reachable commits, trees, blobs, and tags.
- [x] Read object bytes.
- [x] Recompute and verify Git object IDs.
- [x] Record object metadata in SQLite.
- [x] Reject unsupported repository hash formats clearly.

### Storage representations

- [x] Implement whole-blob record.
- [x] Implement tiny-blob aggregation.
- [x] Implement content-defined chunk storage.
- [x] Select an initial chunking algorithm through an ADR.
- [x] Implement compression abstraction.
- [x] Implement immutable segment writer.
- [x] Implement segment reader.
- [x] Implement segment index.
- [x] Implement blob manifest.
- [x] Record storage-policy decisions per blob.

### Reconstruction

- [x] Resolve a Git blob ID to a manifest.
- [x] Resolve manifest records from segments.
- [x] Reconstruct exact bytes.
- [x] Verify final Git blob ID.
- [x] Reconstruct commit, tree, and tag objects.
- [x] Implement full repository verification.

### Export

- [x] Export loose Git objects or a pack.
- [x] Restore refs.
- [x] Run `git fsck --full`.
- [x] Compare reachable object sets with source repository.
- [x] Compare checkout bytes.

### Tests

- [x] Unit tests for segment format.
- [x] Property tests for chunking and reconstruction.
- [x] Corruption tests.
- [x] Round-trip tests on generated repositories.

## Milestone 2 — Git remote helper

### Remote-helper protocol

- [x] Create `git-remote-yeokcham`.
- [x] Parse helper command stream.
- [x] Advertise minimal capabilities.
- [x] Implement ref listing.
- [x] Implement fetch for a local yeokcham store.
- [x] Stream or generate a valid pack.
- [x] Add useful protocol error messages.
- [x] Add debug tracing mode that does not expose source bytes.

### Clone and fetch

- [x] `git clone yeokcham::/absolute/path`.
- [x] Fetch updated branches.
- [x] Fetch tags.
- [x] Handle deleted refs.
- [x] Verify checkout equivalence.
- [x] Test repeated fetch with no changes.
- [x] Cache synthesised packs where safe.

### Exit criteria

- [x] Ordinary Git can clone a yeokcham local store.
- [x] Ordinary Git can fetch updates.
- [x] Checkout and reachable object IDs match the original.
- [x] Integration suite runs against at least two maintained Git versions.

## Milestone 3 — Push and crash-safe refs

### Push ingestion

- [x] Receive pack data from Git.
- [x] Validate object graph.
- [x] Ingest new objects using storage policies.
- [x] Reject missing required objects.
- [x] Support branch create, update, and delete.
- [x] Support tag updates with explicit policy.
- [x] Validate expected old ref values.

### Ref journal

- [x] Define canonical ref-event encoding.
- [x] Implement per-device sequence chain.
- [x] Implement signatures.
- [x] Implement local atomic append.
- [x] Implement ref-state materialisation.
- [x] Detect divergence.
- [x] Preserve rejected/divergent events for inspection.
- [x] Implement ref-log inspection CLI.

### Fault handling

- [x] Add fault-injecting filesystem backend.
- [x] Inject crashes after each mutation boundary.
- [x] Verify old-or-new state property.
- [x] Add restart recovery.
- [x] Add idempotent push retry.

### Exit criteria

- [x] Git push works for local yeokcham stores.
- [x] No injected crash creates an acknowledged but unrecoverable ref state.
- [x] Divergent device-style events are preserved rather than overwritten.

## Milestone 4 — Backend abstraction and encryption

### Backend interface

- [x] Define async backend trait.
- [x] Implement filesystem backend.
- [x] Implement range reads.
- [x] Implement resumable upload abstraction.
- [x] Implement fault-injecting wrapper.
- [x] Implement metrics wrapper.
- [x] Document consistency assumptions.

### Encryption

- [x] Select primitives through ADR.
- [x] Implement repository key generation.
- [x] Implement key hierarchy.
- [x] Encrypt segment records or complete segments.
- [x] Encrypt sensitive metadata.
- [x] Bind associated data.
- [x] Implement key export.
- [x] Implement key import.
- [x] Implement clean-machine recovery test.
- [x] Ensure secrets are redacted from logs.

### Exit criteria

- [x] Encrypted filesystem backend contains no plaintext fixture strings.
- [x] Repository can be recovered from backend plus exported key.
- [x] Wrong keys and tampered records fail safely.

## Milestone 5 — Google Drive backend

### Authentication

- [x] Implement OAuth flow.
- [x] Store credentials in OS credential store.
- [x] Support headless/manual authentication where practical.
- [x] Implement token refresh.
- [x] Document required scopes.

### Storage behaviour

- [x] Map opaque yeokcham keys to Drive files.
- [x] Implement put-if-absent semantics.
- [x] Implement resumable upload.
- [x] Implement metadata cache.
- [x] Implement paginated listing.
- [x] Handle rate limiting with backoff.
- [x] Handle interrupted upload.
- [x] Avoid one Drive file per chunk.
- [x] Upload immutable segments and indexes.
- [x] Add backend verification command.

### Multi-device state

- [x] Fetch device journals.
- [x] Reconcile journal heads.
- [x] Detect stale local state before push.
- [x] Preserve divergent refs.
- [x] Add device registration and revocation.

### Exit criteria

- [x] A repository can be pushed from one machine and cloned on another.
- [x] Drive contains only encrypted opaque files.
- [x] Interrupted uploads do not create accepted broken state.
- [x] Divergent updates are visible and recoverable.

## Milestone 6 — Partial retrieval and cache

### Git filtering

- [x] Investigate remote-helper support requirements for partial clone.
- [x] Implement `blob:none` workflow or document required protocol transition.
- [x] Implement size-filter workflow.
- [x] Track promisor objects.
- [x] Hydrate missing blobs.
- [x] Verify object IDs after hydration.

### Cache

- [x] Cache indexes.
- [x] Cache encrypted segments.
- [x] Cache decrypted chunks with safe local policy.
- [x] Cache reconstructed Git objects.
- [x] Implement capacity limits.
- [x] Implement LRU or benchmarked replacement policy.
- [x] Add cache verification.
- [x] Add cache statistics.
- [x] Add cache clearing without repository damage.

### Sparse workflow

- [x] Integrate with Git sparse checkout.
- [x] Prefetch current sparse paths.
- [x] Measure time to usable workspace.
- [x] Document unsupported Git clients or workflows.

### Exit criteria

- [x] A documented clone workflow avoids downloading unrelated historical blobs.
- [x] Cache deletion never changes repository correctness.
- [x] Benchmark results show transfer and latency behaviour under cold and warm cache.

## Milestone 7 — GitHub mirror

### Configuration

- [x] Add GitHub remote configuration.
- [x] Add publication ref rules.
- [x] Add mirror direction policy.
- [x] Add force-update policy.
- [x] Store mirror checkpoints.

### Publication

- [x] Reconstruct required Git objects.
- [x] Push selected refs.
- [x] Confirm remote object IDs.
- [x] Support pull-request branch publication.
- [x] Report exactly what code will be uploaded.

### Ingestion

- [x] Fetch GitHub refs.
- [x] Detect remote-only commits.
- [x] Import remote objects.
- [x] Detect divergence.
- [x] Require explicit conflict resolution.
- [x] Avoid silent force updates.

### Exit criteria

- [x] Selected refs support normal GitHub PR and CI workflows.
- [x] Unselected refs are not published.
- [x] Remote-created commits can be imported.
- [x] Divergence never causes silent data loss.

## Milestone 8 — Local daemon and performance work

### Daemon

- [x] Define daemon protocol.
- [x] Add repository discovery.
- [x] Add filesystem event monitoring.
- [x] Add persistent file metadata cache.
- [x] Add shared object cache.
- [x] Add cancellation and shutdown handling.
- [x] Default to per-user local-only access.

### Performance

- [x] Parallelise hashing where measured. The [2026-07-31 paired 2-worker result](benchmarks/results/2026-07-31-parallel-import-two-workers/) has a 5% lower median but worse p95, while 8 workers are slower; retain serial default.
- [x] Parallelise compression where measured. V1 has only the exact-copy `none` codec, so no compression operation exists to parallelise; ADR-0038 keeps compressed codec and format selection separate.
- [x] Add pack-synthesis cache.
- [x] Add prefetch heuristics. Opt-in canonical C Git cone sparse-checkout-file selections refresh without worktree discovery; helper integration and workload improvement remain separate.
- [x] Measure startup overhead.
- [x] Measure daemon memory.
- [x] Publish cases where daemon is slower.

### Exit criteria

- [x] Warm-cache benchmark suite is reproducible.
- [x] Daemon improves at least one target workload materially. The [2026-07-31 W5 daemon-prebuilt checkout](benchmarks/results/2026-07-31-daemon-prewarmed/) is 57% lower at median and 46% lower at p95 than its cold helper case; startup and prewarm cost are excluded.
- [x] Daemon can be disabled without data-format changes.

## Milestone 9 — Self-hosted HTTP service

- [x] Add smart HTTP or documented yeokcham-native transport. Native HTTP V1 serves bounded verified health, refs, and raw Git objects; it is not Git smart HTTP.
- [x] Bind to loopback by default. V1 rejects every non-loopback address and defaults to ephemeral `127.0.0.1:0`.
- [x] Add single-user authentication. Every V1 endpoint requires one private generated 256-bit bearer token loaded from a regular non-symlinked file with no group or other permission bits.
- [x] Add repository browser. Authenticated `GET /` renders bounded HTML repository, regular-ref, and `HEAD` metadata with escaped or hexadecimal ref names; commit and tree views remain separate.
- [x] Add commit and tree viewer. Authenticated pages reconstruct and verify objects, render bounded escaped commit/tree metadata, link verified commit/tree navigation, and never render blobs.
- [x] Add storage and backend statistics. Authenticated `GET /storage` reports only verified canonical-record counts plus one local provider and zero attached remote backends; it performs no provider request or credential lookup.
- [x] Add integrity-check UI. Authenticated `GET /integrity` reruns bounded verification, renders only a successful read-only result, and otherwise returns a generic failure without partial inventory or repair action.
- [x] Add mirror-state UI. Authenticated `GET /mirror` renders only redacted local GitHub policy direction/count state, never target/ref/object metadata, and performs no provider or credential operation.
- [x] Add export and recovery commands. `yeokcham recover --export-git` fully verifies a local canonical repository before creating a conventional bare Git export; Drive snapshot recovery remains `yeokcham drive restore`.
- [ ] Publish Docker image only after local binary is stable. Deferred by operator choice: V1 supports the standalone loopback release binary; container publication requires an approved host-network policy and registry/image namespace.

### Exit criteria

- [x] Single-user server can be deployed without a hosted control plane. `make server-release` builds a standalone binary that requires only the local canonical repository and a private token file; the binary startup integration test serves authenticated loopback health traffic.
- [x] Network threat model is documented. V1 documents loopback-only unauthenticated exposure, local-process risk, parser and resource bounds, and prohibited public forwarding.
- [x] No unauthenticated public listener is enabled by default. V1 rejects every non-loopback bind, including explicit public addresses.

## Milestone 10 — Production hardening

- [x] Stable repository-format specification. `docs/repository-format.md` now defines supported V1/V2 bootstrap compatibility, canonical layout, recovery boundaries, and reader rules; `docs/serialization.md` defines every current local, backend, and remote record family.
- [x] Migration framework. `yeokcham migrate <source-v1-repo> <destination-v2-repo>` performs bounded copy-on-write V1-to-V2 migration: it verifies and scans the source before target creation, preserves the V1 source for rollback, excludes disposable state, writes the V2 bootstrap last, and verifies the target; failed targets require explicit discard before retry.
- [x] Old-format fixtures. Retained canonical `fixtures/pinned/repository-format-v1/` and `repository-format-v2/` fixtures import the pinned SHA-1 history; core coverage opens, verifies, exports, and compares both reader paths to the pinned Git graph and refs.
- [ ] Signed release artefacts.
- [x] SBOM generation. `make sbom SBOM_OUTPUT=<absent-directory>` generates one CycloneDX 1.5 JSON SBOM per workspace package outside the source tree using pinned `cargo-cyclonedx` 0.5.9, validates each output, and records SHA-256 checksums.
- [x] Dependency audit. `make audit` uses pinned `cargo-audit` 0.22.2 to deny RustSec warnings for both the workspace and fuzz lockfiles; it fetches the advisory database by default and supports only explicit `YEOKCHAM_AUDIT_OFFLINE=1` use of an existing database.
- [ ] Security disclosure process.
- [ ] Continuous fuzzing. Local `make fuzz-campaign FUZZ_SECONDS=<seconds> FUZZ_OUTPUT=<absent-directory>` now provides an isolated bounded all-target campaign with retained logs, copied corpora, and crash artifacts; a scheduled runner, retention, and response owner remain required before claiming continuous operation.
- [ ] Full benchmark report.
- [x] Backup and disaster-recovery guide. `docs/backup-and-disaster-recovery.md` now specifies separated recovery material, immutable Drive snapshot rollover, source/snapshot verification, absent-destination restore/export, interrupted-operation handling, local Git export, and non-secret drill evidence.
- [ ] Key rotation.
- [ ] Device revocation.
- [ ] SHA-256 Git repository plan.
- [ ] Windows support assessment.
- [x] Performance regression CI. Provider-neutral `make performance-check BENCHMARK_BASELINE=<file> BENCHMARK_CANDIDATE=<file> MAX_REGRESSION_PERCENT=<percent>` rejects measurements that differ in fixture/configuration/stable environment or exceed the explicit operator-selected threshold for wall/CPU/RSS/network/storage metrics; `make benchmark-results` validates every committed result.
- [ ] Restore drills on clean machines.

### Production-quality definition

yeokcham is not production-quality until:

- Conventional export is reliable.
- Recovery is documented and tested.
- Data formats are versioned.
- Remote corruption is detected.
- Key loss implications are explicit.
- Push is crash-safe.
- Benchmarks are reproducible.
- Users can leave yeokcham without losing history.
