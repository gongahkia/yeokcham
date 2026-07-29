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
- [ ] Define repository format version and feature flags.
- [ ] Define serialisation policy and canonical encoding rules.

### Exit criteria

- [ ] CI passes on macOS and Linux.
- [ ] Empty repository format can be created, reopened, and migrated.
- [ ] Public types have invariants documented.
- [ ] No implementation code depends directly on a cloud backend.

## Milestone 1 — Local storage proof

### Git import

- [ ] Open an existing Git repository.
- [ ] Enumerate refs.
- [ ] Traverse reachable commits, trees, blobs, and tags.
- [ ] Read object bytes.
- [ ] Recompute and verify Git object IDs.
- [ ] Record object metadata in SQLite.
- [ ] Reject unsupported repository hash formats clearly.

### Storage representations

- [ ] Implement whole-blob record.
- [ ] Implement tiny-blob aggregation.
- [ ] Implement content-defined chunking.
- [ ] Select an initial chunking algorithm through an ADR.
- [ ] Implement compression abstraction.
- [ ] Implement immutable segment writer.
- [ ] Implement segment reader.
- [ ] Implement segment index.
- [ ] Implement blob manifest.
- [ ] Record storage-policy decisions per blob.

### Reconstruction

- [ ] Resolve a Git blob ID to a manifest.
- [ ] Resolve manifest records from segments.
- [ ] Reconstruct exact bytes.
- [ ] Verify final Git blob ID.
- [ ] Reconstruct commit, tree, and tag objects.
- [ ] Implement full repository verification.

### Export

- [ ] Export loose Git objects or a pack.
- [ ] Restore refs.
- [ ] Run `git fsck --full`.
- [ ] Compare reachable object sets with source repository.
- [ ] Compare checkout bytes.

### Tests

- [ ] Unit tests for segment format.
- [ ] Property tests for chunking and reconstruction.
- [ ] Corruption tests.
- [ ] Round-trip tests on generated repositories.
- [ ] Round-trip tests on selected real repositories.
- [ ] Benchmark whole-blob versus chunked storage.

### Exit criteria

- [ ] Import then export is object-identical for supported repositories.
- [ ] Full verification detects altered chunks, manifests, and indexes.
- [ ] Repeated binary versions demonstrate measurable deduplication.
- [ ] Tiny-file fixture does not suffer unbounded metadata expansion.

## Milestone 2 — Git remote helper

### Remote-helper protocol

- [ ] Create `git-remote-yeokcham`.
- [ ] Parse helper command stream.
- [ ] Advertise minimal capabilities.
- [ ] Implement ref listing.
- [ ] Implement fetch for a local yeokcham store.
- [ ] Stream or generate a valid pack.
- [ ] Add useful protocol error messages.
- [ ] Add debug tracing mode that does not expose source bytes.

### Clone and fetch

- [ ] `git clone yeokcham::/absolute/path`.
- [ ] Fetch updated branches.
- [ ] Fetch tags.
- [ ] Handle deleted refs.
- [ ] Verify checkout equivalence.
- [ ] Test repeated fetch with no changes.
- [ ] Cache synthesised packs where safe.

### Exit criteria

- [ ] Ordinary Git can clone a yeokcham local store.
- [ ] Ordinary Git can fetch updates.
- [ ] Checkout and reachable object IDs match the original.
- [ ] Integration suite runs against at least two maintained Git versions.

## Milestone 3 — Push and crash-safe refs

### Push ingestion

- [ ] Receive pack data from Git.
- [ ] Validate object graph.
- [ ] Ingest new objects using storage policies.
- [ ] Reject missing required objects.
- [ ] Support branch create, update, and delete.
- [ ] Support tag updates with explicit policy.
- [ ] Validate expected old ref values.

### Ref journal

- [ ] Define canonical ref-event encoding.
- [ ] Implement per-device sequence chain.
- [ ] Implement signatures.
- [ ] Implement local atomic append.
- [ ] Implement ref-state materialisation.
- [ ] Detect divergence.
- [ ] Preserve rejected/divergent events for inspection.
- [ ] Implement ref-log inspection CLI.

### Fault handling

- [ ] Add fault-injecting filesystem backend.
- [ ] Inject crashes after each mutation boundary.
- [ ] Verify old-or-new state property.
- [ ] Add restart recovery.
- [ ] Add idempotent push retry.

### Exit criteria

- [ ] Git push works for local yeokcham stores.
- [ ] No injected crash creates an acknowledged but unrecoverable ref state.
- [ ] Divergent device-style events are preserved rather than overwritten.

## Milestone 4 — Backend abstraction and encryption

### Backend interface

- [ ] Define async backend trait.
- [ ] Implement filesystem backend.
- [ ] Implement range reads.
- [ ] Implement resumable upload abstraction.
- [ ] Implement fault-injecting wrapper.
- [ ] Implement metrics wrapper.
- [ ] Document consistency assumptions.

### Encryption

- [ ] Select primitives through ADR.
- [ ] Implement repository key generation.
- [ ] Implement key hierarchy.
- [ ] Encrypt segment records or complete segments.
- [ ] Encrypt sensitive metadata.
- [ ] Bind associated data.
- [ ] Implement key export.
- [ ] Implement key import.
- [ ] Implement clean-machine recovery test.
- [ ] Ensure secrets are redacted from logs.

### Exit criteria

- [ ] Encrypted filesystem backend contains no plaintext fixture strings.
- [ ] Repository can be recovered from backend plus exported key.
- [ ] Wrong keys and tampered records fail safely.

## Milestone 5 — Google Drive backend

### Authentication

- [ ] Implement OAuth flow.
- [ ] Store credentials in OS credential store.
- [ ] Support headless/manual authentication where practical.
- [ ] Implement token refresh.
- [ ] Document required scopes.

### Storage behaviour

- [ ] Map opaque yeokcham keys to Drive files.
- [ ] Implement put-if-absent semantics.
- [ ] Implement resumable upload.
- [ ] Implement metadata cache.
- [ ] Implement paginated listing.
- [ ] Handle rate limiting with backoff.
- [ ] Handle interrupted upload.
- [ ] Avoid one Drive file per chunk.
- [ ] Upload immutable segments and indexes.
- [ ] Add backend verification command.

### Multi-device state

- [ ] Fetch device journals.
- [ ] Reconcile journal heads.
- [ ] Detect stale local state before push.
- [ ] Preserve divergent refs.
- [ ] Add device registration and revocation.

### Exit criteria

- [ ] A repository can be pushed from one machine and cloned on another.
- [ ] Drive contains only encrypted opaque files.
- [ ] Interrupted uploads do not create accepted broken state.
- [ ] Divergent updates are visible and recoverable.

## Milestone 6 — Partial retrieval and cache

### Git filtering

- [ ] Investigate remote-helper support requirements for partial clone.
- [ ] Implement `blob:none` workflow or document required protocol transition.
- [ ] Implement size-filter workflow.
- [ ] Track promisor objects.
- [ ] Hydrate missing blobs.
- [ ] Verify object IDs after hydration.

### Cache

- [ ] Cache indexes.
- [ ] Cache encrypted segments.
- [ ] Cache decrypted chunks with safe local policy.
- [ ] Cache reconstructed Git objects.
- [ ] Implement capacity limits.
- [ ] Implement LRU or benchmarked replacement policy.
- [ ] Add cache verification.
- [ ] Add cache statistics.
- [ ] Add cache clearing without repository damage.

### Sparse workflow

- [ ] Integrate with Git sparse checkout.
- [ ] Prefetch current sparse paths.
- [ ] Measure time to usable workspace.
- [ ] Document unsupported Git clients or workflows.

### Exit criteria

- [ ] A documented clone workflow avoids downloading unrelated historical blobs.
- [ ] Cache deletion never changes repository correctness.
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
- Security-sensitive parsers are fuzzed.
- Users can leave yeokcham without losing history.
