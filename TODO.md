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

- [ ] Cache indexes.
- [ ] Cache encrypted segments.
- [ ] Cache decrypted chunks with safe local policy.
- [ ] Cache reconstructed Git objects.
- [x] Implement capacity limits.
- [x] Implement LRU or benchmarked replacement policy.
- [x] Add cache verification.
- [x] Add cache statistics.
- [x] Add cache clearing without repository damage.

### Sparse workflow

- [ ] Integrate with Git sparse checkout.
- [ ] Prefetch current sparse paths.
- [ ] Measure time to usable workspace.
- [ ] Document unsupported Git clients or workflows.

### Exit criteria

- [x] A documented clone workflow avoids downloading unrelated historical blobs.
- [x] Cache deletion never changes repository correctness.
- [ ] Benchmark results show transfer and latency behaviour under cold and warm cache.

## Milestone 7 — GitHub mirror

### Configuration

- [ ] Add GitHub remote configuration.
- [ ] Add publication ref rules.
- [ ] Add mirror direction policy.
- [ ] Add force-update policy.
- [ ] Store mirror checkpoints.

### Publication

- [ ] Reconstruct required Git objects.
- [ ] Push selected refs.
- [ ] Confirm remote object IDs.
- [ ] Support pull-request branch publication.
- [ ] Report exactly what code will be uploaded.

### Ingestion

- [ ] Fetch GitHub refs.
- [ ] Detect remote-only commits.
- [ ] Import remote objects.
- [ ] Detect divergence.
- [ ] Require explicit conflict resolution.
- [ ] Avoid silent force updates.

### Exit criteria

- [ ] Selected refs support normal GitHub PR and CI workflows.
- [ ] Unselected refs are not published.
- [ ] Remote-created commits can be imported.
- [ ] Divergence never causes silent data loss.

## Milestone 8 — Local daemon and performance work

### Daemon

- [ ] Define daemon protocol.
- [ ] Add repository discovery.
- [ ] Add filesystem event monitoring.
- [ ] Add persistent file metadata cache.
- [ ] Add shared object cache.
- [ ] Add cancellation and shutdown handling.
- [ ] Default to per-user local-only access.

### Performance

- [ ] Parallelise hashing where measured.
- [ ] Parallelise compression where measured.
- [ ] Add pack-synthesis cache.
- [ ] Add prefetch heuristics.
- [ ] Measure startup overhead.
- [ ] Measure daemon memory.
- [ ] Publish cases where daemon is slower.

### Exit criteria

- [ ] Warm-cache benchmark suite is reproducible.
- [ ] Daemon improves at least one target workload materially.
- [ ] Daemon can be disabled without data-format changes.

## Milestone 9 — Self-hosted HTTP service

- [ ] Add smart HTTP or documented yeokcham-native transport.
- [ ] Bind to loopback by default.
- [ ] Add single-user authentication.
- [ ] Add repository browser.
- [ ] Add commit and tree viewer.
- [ ] Add storage and backend statistics.
- [ ] Add integrity-check UI.
- [ ] Add mirror-state UI.
- [ ] Add export and recovery commands.
- [ ] Publish Docker image only after local binary is stable.

### Exit criteria

- [ ] Single-user server can be deployed without a hosted control plane.
- [ ] Network threat model is documented.
- [ ] No unauthenticated public listener is enabled by default.

## Milestone 10 — Production hardening

- [ ] Stable repository-format specification.
- [ ] Migration framework.
- [ ] Old-format fixtures.
- [ ] Signed release artefacts.
- [ ] SBOM generation.
- [ ] Dependency audit.
- [ ] Security disclosure process.
- [ ] Continuous fuzzing.
- [ ] Full benchmark report.
- [ ] Backup and disaster-recovery guide.
- [ ] Key rotation.
- [ ] Device revocation.
- [ ] SHA-256 Git repository plan.
- [ ] Windows support assessment.
- [ ] Performance regression CI.
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
