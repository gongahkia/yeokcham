# Product Requirements Document

## 1. Product summary

Relay is a Git-compatible, local-first, encrypted repository accelerator and sovereign remote.

Users keep using ordinary Git. Relay stores the canonical repository on local disk, a self-hosted Relay server, Google Drive, or another backend. It preserves Git object identities while internally representing file content through manifests, chunks, compressed segments, and indexes.

## 2. Product objectives

### O1 — Preserve Git interoperability

A user must be able to import, clone, fetch, push, mirror, and fully export a repository without rewriting its Git history.

### O2 — Reduce storage growth

Relay should materially reduce storage growth for repositories containing repeated or locally modified large content, while avoiding excessive overhead for tiny source files.

### O3 — Reduce time to a usable workspace

A user should be able to retrieve repository metadata and the current working set without downloading all historical large blobs.

### O4 — Provide repository sovereignty

The canonical remote must be able to run without GitHub or a Relay-operated service.

### O5 — Keep the backend replaceable

Local disk, Google Drive, and future backends should implement the same minimal object-store contract.

### O6 — Make failure recoverable

Interrupted writes, corrupt remote objects, stale local caches, and concurrent device activity must have explicit detection and recovery behaviour.

## 3. User personas

### P1 — Ordinary developer

Uses GitHub and Git daily. Wants a private, user-controlled canonical remote with an optional public GitHub mirror.

### P2 — Monorepo developer

Needs fast metadata operations and sparse working sets.

### P3 — Binary-heavy developer

Works with game assets, datasets, media, machine-learning artefacts, or generated outputs that change incrementally.

### P4 — Independent maintainer

Wants an inexpensive encrypted backup and remote without administering a complex forge.

## 4. Core user journeys

### J1 — Import an existing repository

1. User runs `relay init --from-git .`.
2. Relay scans reachable Git objects.
3. Relay stores metadata objects.
4. Relay selects a storage policy for each blob.
5. Relay writes manifests, chunks, segments, and indexes.
6. Relay verifies that every reachable Git object can be reconstructed.
7. Relay records refs transactionally.

Acceptance condition: a full export produces a repository accepted by `git fsck`.

### J2 — Clone through Relay

1. User runs `git clone relay://path-or-remote/repo`.
2. Git invokes `git-remote-relay`.
3. Relay advertises refs and capabilities.
4. Relay resolves requested objects.
5. Relay reconstructs or synthesises a valid Git pack.
6. Git completes the clone normally.

Acceptance condition: checked-out bytes and reachable object IDs match a clone from the original Git repository.

### J3 — Push through Relay

1. Git sends updates and a pack.
2. Relay validates the pack and proposed ref changes.
3. Relay ingests objects into its storage representation.
4. Relay writes immutable data first.
5. Relay commits ref updates through a journaled transaction.
6. Relay reports success only after durable state is visible.

Acceptance condition: a crash at any injected point leaves the old or new valid ref state, never an invalid mixture.

### J4 — Store remotely on Google Drive

1. User authenticates with Google Drive.
2. Relay creates or selects a repository folder.
3. Relay uploads encrypted immutable segments and indexes.
4. Relay writes per-device ref journal entries.
5. Another device retrieves and reconciles state.
6. All content is decrypted locally.

Acceptance condition: Drive never contains plaintext source, path names, commit messages, or ref names unless the user explicitly opts out of metadata encryption.

### J5 — Mirror selected refs to GitHub

1. User configures a GitHub remote.
2. User selects refs or publication rules.
3. Relay converts or reconstructs standard Git objects.
4. Relay pushes selected refs.
5. Relay records the last mirrored Git state.
6. Relay detects remote changes and imports them.

Acceptance condition: GitHub pull requests and CI operate on the published commits, while unpublished refs remain absent from GitHub.

### J6 — Recover without Relay cloud services

1. User obtains the local key material and remote repository folder.
2. User runs `relay recover`.
3. Relay validates segments, indexes, manifests, journals, and signatures.
4. Relay reconstructs refs.
5. Relay exports a conventional Git repository.

Acceptance condition: recovery succeeds using only open-source Relay binaries, repository data, and user-held keys.

## 5. Functional requirements

### FR-001 Repository import

Relay shall import all reachable Git commit, tree, blob, and tag objects.

### FR-002 Object identity preservation

Relay shall preserve the original Git object ID for each imported object.

### FR-003 Conventional export

Relay shall export a repository that passes `git fsck --full`.

### FR-004 Remote helper

Relay shall provide a `git-remote-relay` executable compatible with Git remote-helper invocation.

### FR-005 Clone and fetch

Relay shall support clone and fetch for local Relay stores before network backends are implemented.

### FR-006 Push

Relay shall support push with atomic ref updates.

### FR-007 Adaptive blob representation

Relay shall support at least:

- Whole-blob storage.
- Aggregated tiny-blob storage.
- Content-defined chunked storage.

### FR-008 Chunk integrity

Every chunk and segment shall be independently integrity-checked.

### FR-009 Immutable segments

Uploaded content segments shall be immutable.

### FR-010 Backend interface

Relay shall define a backend interface with operations equivalent to:

- `put_if_absent(key, bytes)`
- `get(key, range?)`
- `head(key)`
- `list(prefix, cursor?)`
- `delete(key)` for maintenance only
- Optional multipart or resumable upload

### FR-011 Local backend

Relay shall provide a filesystem backend.

### FR-012 Google Drive backend

Relay shall provide a Google Drive backend that stores opaque immutable files rather than a live `.git` directory.

### FR-013 Encryption

Relay shall encrypt repository content and sensitive metadata before remote upload.

### FR-014 Key export and recovery

Relay shall provide explicit backup and restore commands for key material.

### FR-015 Ref journal

Relay shall represent remote mutable state using append-only, verifiable journal entries.

### FR-016 Multi-device reconciliation

Relay shall detect divergent ref updates from different devices and preserve both states for manual or policy-driven resolution.

### FR-017 Partial retrieval

Relay shall support metadata-first retrieval and deferred blob hydration.

### FR-018 Local cache

Relay shall cache reconstructed objects, chunks, and indexes locally with integrity validation.

### FR-019 GitHub mirror

Relay shall push selected standard Git refs to GitHub through ordinary Git transport.

### FR-020 GitHub ingestion

Relay shall be able to fetch and ingest commits created outside Relay on a configured GitHub remote.

### FR-021 Integrity verification

Relay shall expose `relay verify` with fast and full verification modes.

### FR-022 Garbage collection

Relay shall identify unreachable manifests, chunks, and segments subject to retention and backend safety rules.

### FR-023 Repository diagnostics

Relay shall expose storage statistics, cache statistics, backend health, and mirror state.

### FR-024 Self-hosted server

Relay shall provide a single-user HTTP service for repository access and inspection after the local remote is stable.

## 6. Non-functional requirements

### NFR-001 Correctness

No operation may report success before durable data and ref state are recoverable.

### NFR-002 Determinism

Given the same configuration and input objects, pack reconstruction and export should be deterministic where protocol constraints allow.

### NFR-003 Portability

Initial supported platforms:

- macOS arm64.
- Linux x86_64.

Windows support is desirable but not required for the first usable release.

### NFR-004 Performance visibility

All benchmark claims must include:

- Relay version and commit.
- Git version.
- Hardware.
- Filesystem.
- Warm or cold cache state.
- Repository fixture.
- Configuration.
- Median and tail latency.
- Bytes transferred.
- Peak memory.
- Storage consumed.

### NFR-005 No mandatory hosted control plane

Repository access must not require a Relay-operated account.

### NFR-006 Open format

Repository storage formats shall be versioned and documented.

### NFR-007 Forward compatibility

Readers shall reject unsupported mandatory features clearly rather than silently misinterpreting data.

### NFR-008 Observability

The CLI and daemon shall emit structured logs suitable for debugging without logging decrypted source content.

## 7. Release scope

### Prototype release

- Local import.
- Local filesystem backend.
- Clone/fetch through remote helper.
- Full export.
- Verification.
- Benchmark harness.

### Usable alpha

- Push.
- Crash-safe refs.
- Adaptive chunk storage.
- Encryption.
- Google Drive backend.
- Basic recovery tooling.

### Public beta

- Partial retrieval.
- Local cache daemon.
- GitHub mirror.
- Multi-device reconciliation.
- Stable documented repository format.
- Published benchmark suite.

### Production-quality target

- Fuzzed parsers.
- Crash-injection suite.
- Upgrade and migration tooling.
- Key rotation.
- Audited recovery process.
- Backward-compatibility policy.
- Stable CLI.
- Signed releases.
- Security review.

## 8. Explicit non-goals

- Replacing all Git commands.
- Hiding all Git concepts from users.
- Perfect performance on every repository class.
- Transparent GitHub PRs without uploading the relevant code to GitHub.
- Treating Google Drive as a database.
- Multi-user authorisation in the first production target.
- Cross-user deduplication.
- AST-based source merging.

## 9. Success metrics

### Adoption metrics

- A developer can install Relay and create a sovereign remote in under ten minutes.
- An existing repository can be imported without history rewriting.
- A user can export and remove Relay without losing repository history.

### Correctness metrics

- Zero unexplained object mismatches in differential round-trip tests.
- All supported crash-injection points preserve a valid recoverable repository.
- Corruption is detected before corrupted bytes are returned as trusted content.

### Performance goals

Performance targets are research hypotheses until benchmarked.

- Repeated modifications to large binary files should consume substantially less incremental storage than whole-file external storage.
- Metadata-first clones should reach a usable sparse workspace without downloading unrelated historical large blobs.
- Warm-cache fetch and checkout should be competitive with modern Git for the supported repository profile.
- Tiny-file workloads should not regress catastrophically due to chunk-index overhead.

## 10. Major risks

### R1 — Protocol scope

Git protocol and pack compatibility can consume the project.

Mitigation: use mature libraries and initially implement the remote-helper surface against local storage.

### R2 — Chunking overhead

Content-defined chunking can waste space and CPU on small source files.

Mitigation: adaptive representation and benchmark-driven thresholds.

### R3 — Google Drive semantics

Drive listing, consistency, quotas, and API behaviour may be unsuitable for fine-grained operations.

Mitigation: large immutable segment files, local indexes, resumable uploads, and minimal remote mutations.

### R4 — Encryption and deduplication tension

Encryption can prevent deduplication if applied before chunk identity is established.

Mitigation: deduplicate inside a single user's trust domain, then encrypt immutable stored records.

### R5 — GitHub mirror ambiguity

Bidirectional changes can create divergent ref histories.

Mitigation: explicit mirror policies, last-observed state, conflict preservation, and no silent force-push.

### R6 — Unprovable universal superiority

No storage model wins every workload.

Mitigation: publish a workload matrix and state where Relay is slower.

## 11. Open product questions

These should be answered by experiments, not assumptions:

- Should source blobs be chunked by default or stored whole below a threshold?
- Should chunk boundaries be repository-global or segmented by file class?
- How much metadata should remain locally cached for cold Drive repositories?
- Should users configure publication rules by ref, path, repository, or capsule-like release profiles?
- What is the safest default for multi-device divergent pushes?
- Is a daemon necessary before partial clone delivers sufficient value?
