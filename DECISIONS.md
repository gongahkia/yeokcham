# Architecture Decision Records

## Process

The ADR lifecycle, numbering rules, and template are defined in [`docs/adr/README.md`](docs/adr/README.md). ADR-001 through ADR-015 are accepted legacy records. New records start at ADR-016 and live in `docs/adr/`.

## ADR-001 — Three distinct histories

**Decision:** Yeokcham models scratch, intent, and release histories separately.

**Reason:** Recovery, collaboration, and release auditing have different retention and usability requirements.

**Consequence:** The CLI and storage model must expose all three rather than disguising them as one commit graph.

## ADR-002 — OCaml implementation

**Decision:** Implement Yeokcham in OCaml.

**Reason:** The core project is an algebraic model of immutable state transitions, composition, conflicts, and compaction.

**Consequence:** Persistent formats must remain portable and must not use OCaml `Marshal`.

## ADR-003 — Exact bytes are canonical

**Decision:** File bytes and filesystem structure are authoritative.

**Reason:** A general VCS must preserve comments, formatting, invalid source, generated files, binaries, and unsupported languages.

**Consequence:** AST or semantic data is always a sidecar with textual or exact fallback.

## ADR-004 — Automatic scratch history is bounded

**Decision:** Scratch checkpoints are subject to explicit retention and compaction.

**Reason:** Saving everything forever recreates the historical growth problem.

**Consequence:** Pinning and compaction invariants are core features, not later maintenance work.

## ADR-005 — Stable capsule ID, immutable revisions

**Decision:** Logical capsule identity remains stable while each revision is immutable.

**Reason:** Humans think of a feature or fix as one continuing unit even while implementation changes.

**Consequence:** References must distinguish capsule ID from revision ID.

## ADR-006 — Conflicts are persistent values

**Decision:** Conflicts are stored repository objects.

**Reason:** A conflict may require deferred resolution and should not globally block unrelated work.

**Consequence:** Commands must operate in repositories containing unresolved conflicts.

## ADR-007 — Composition is explicit and deterministic

**Decision:** Workspace materialisation depends on a declared base, revision set, dependency graph, order, and policies.

**Reason:** Hidden or environment-dependent ordering makes capsules unpredictable.

**Consequence:** Yeokcham must explain composition order.

## ADR-008 — Semantic replay exposes uncertainty

**Decision:** Semantic operations carry confidence and may yield uncertainty conflicts.

**Reason:** A clean-looking automatic application can still be incorrect.

**Consequence:** The system must not silently convert uncertain matches into exact success.

## ADR-009 — Git is an interchange layer

**Decision:** Git import/export does not define Yeokcham's internal model.

**Reason:** Recreating Git concepts would undermine the experimental purpose.

**Consequence:** Imported Git history may be represented opaquely, and export policies must be explicit.

## ADR-010 — Local model before distributed sync

**Decision:** Do not implement remote synchronisation until scratch, capsule, workspace, conflict, and release invariants are stable.

**Reason:** Distribution multiplies ambiguity and failure states.

**Consequence:** The first useful product is entirely local.

## ADR-011 — Polling scan before filesystem watcher

**Decision:** Begin with deterministic explicit or debounced scans.

**Reason:** Platform-specific watcher semantics add complexity before the history model is validated.

**Consequence:** Early prototypes may use more I/O.

## ADR-012 — Portable canonical encoding

**Decision:** Persistent objects use a versioned portable encoding such as canonical CBOR, selected after library validation.

**Reason:** Repository longevity must not depend on OCaml runtime representation.

**Consequence:** Encoding is part of the tested specification.

## ADR-013 — Hash abstraction

**Decision:** Internal IDs use a hash abstraction; SHA-256 is acceptable initially.

**Reason:** Hash choice should not permeate the model, and implementation availability matters.

**Consequence:** Encodings record the algorithm.

## ADR-014 — No semantic compaction initially

**Decision:** Scratch compaction uses only provable byte- or graph-level transformations in the initial prototype.

**Reason:** Inferring that two semantic edit sequences are equivalent is unsafe.

**Consequence:** Semantic research focuses on capsule replay, not deleting recovery history.

## ADR-015 — TypeScript first semantic adapter

**Decision:** Prototype semantic sidecars for TypeScript before Rust.

**Reason:** TypeScript provides common source structures and a broad demonstration audience; Rust follows to test a stricter and macro-heavy language.

**Consequence:** The byte model must remain language-neutral.

## File-backed ADRs

- [ADR-016 — Initial SHA-256 implementation](docs/adr/016-initial-sha256-implementation.md) — Accepted.
- [ADR-017 — Restricted deterministic CBOR encoding](docs/adr/017-restricted-deterministic-cbor.md) — Accepted.
- [ADR-018 — Fixed object envelope](docs/adr/018-fixed-object-envelope.md) — Accepted.
- [ADR-019 — Object format versions and mandatory features](docs/adr/019-object-format-versions-and-mandatory-features.md) — Accepted.
- [ADR-020 — Stored-object identity and immutable publication](docs/adr/020-stored-object-identity-and-publication.md) — Accepted.
- [ADR-021 — Persisted snapshot object schemas](docs/adr/021-persisted-snapshot-object-schemas.md) — Accepted.
- [ADR-022 — Large-content chunks and file manifests](docs/adr/022-large-content-chunks-and-file-manifests.md) — Accepted.
- [ADR-023 — Scratch records, retention, and mutable refs](docs/adr/023-scratch-records-retention-and-mutable-refs.md) — Accepted.
- [ADR-024 — Compacted scratch generations](docs/adr/024-compacted-scratch-generations.md) — Accepted.
- [ADR-025 — Durable capsules and revisions](docs/adr/025-durable-capsules-and-revisions.md) — Accepted.
- [ADR-026 — Persistent workspaces, conflicts, and resolutions](docs/adr/026-persistent-workspaces-conflicts-and-resolutions.md) — Accepted.
- [ADR-027 — Validation evidence, immutable releases, and attestations](docs/adr/027-validation-evidence-releases-and-attestations.md) — Accepted.
- [ADR-028 — Git interchange mapping records](docs/adr/028-git-interchange-mapping-records.md) — Accepted.
- [ADR-029 — Opaque Git imported transitions](docs/adr/029-opaque-git-imported-transitions.md) — Accepted.
- [ADR-030 — Opaque Git tag imports](docs/adr/030-opaque-git-tag-imports.md) — Accepted.
- [ADR-031 — Opaque Git commit metadata imports](docs/adr/031-opaque-git-commit-metadata.md) — Accepted.
- [ADR-032 — Deterministic Git release commit export](docs/adr/032-git-release-commit-export.md) — Accepted.
- [ADR-033 — Deterministic linear Git capsule-revision export](docs/adr/033-linear-git-capsule-revision-export.md) — Accepted.
- [ADR-034 — Configured Git release-export metadata](docs/adr/034-configured-git-release-export-metadata.md) — Accepted.
- [ADR-035 — Optional Rust parser sidecar](docs/adr/035-optional-rust-parser-sidecar.md) — Accepted.
- [ADR-036 — Snapshot-local Rust module paths](docs/adr/036-snapshot-local-rust-module-paths.md) — Accepted.
- [ADR-037 — Rust macro textual fallback](docs/adr/037-rust-macro-textual-fallback.md) — Accepted.
- [ADR-038 — Bounded immutable object exchange](docs/adr/038-immutable-object-exchange.md) — Accepted.
- [ADR-039 — Verifiable ref events without implicit trust](docs/adr/039-verifiable-ref-events.md) — Accepted.
- [ADR-040 — Local device identities without implicit authority](docs/adr/040-local-device-identities.md) — Accepted.
- [ADR-041 — Immutable divergent ref-head sets](docs/adr/041-divergent-ref-head-sets.md) — Accepted.
- [ADR-042 — Encrypted offline object bundles](docs/adr/042-encrypted-offline-object-bundles.md) — Accepted.
- [ADR-043 — Shared-directory encrypted bundle workflow](docs/adr/043-shared-directory-encrypted-bundle-workflow.md) — Accepted.
- [ADR-044 — Inspectable repository operations and exact durable retargeting](docs/adr/044-inspection-and-exact-durable-retargeting.md) — Accepted.
- [ADR-045 — V2 canonical encrypted-object envelope](docs/adr/045-v2-canonical-encrypted-object-envelope.md) — Accepted.
- [ADR-046 — V2 keyed opaque object addresses](docs/adr/046-v2-keyed-opaque-object-addresses.md) — Accepted.
- [ADR-047 — Explicit V1 archive and V2 cutover boundary](docs/adr/047-v1-archive-and-v2-cutover.md) — Accepted.
- [ADR-048 — V2 encrypted causal ref-ledger with external key verification](docs/adr/048-v2-encrypted-causal-ref-ledger.md) — Accepted.
- [ADR-049 — V2 durable object transaction journals without implicit ref authority](docs/adr/049-v2-durable-object-transaction-journals.md) — Accepted.
- [ADR-050 — Local V2 daemon runtime boundary](docs/adr/050-local-v2-daemon-runtime-boundary.md) — Accepted.
- [ADR-051 — Linux inotify as an advisory watcher source](docs/adr/051-linux-inotify-advisory-watcher.md) — Accepted.
- [ADR-052 — V2 local bootstrap authority and role-separated capabilities](docs/adr/052-v2-local-bootstrap-authority.md) — Superseded by ADR-053.
- [ADR-053 — Linux Secret Service custody and bootstrap key handles](docs/adr/053-linux-secret-service-custody.md) — Accepted.
- [ADR-054 — V2 typed encrypted object frames](docs/adr/054-v2-typed-encrypted-objects.md) — Accepted.
- [ADR-055 — V2 local scratch snapshot publication](docs/adr/055-v2-local-scratch-publication.md) — Accepted.
- [ADR-056 — V2 opaque restore journal](docs/adr/056-v2-opaque-restore-journal.md) — Accepted.
- [ADR-057 — V2 daemon-owned scratch scheduling](docs/adr/057-v2-daemon-scratch-scheduling.md) — Accepted.
- [ADR-058 — V2 scratch retention and immutable generation activation](docs/adr/058-v2-scratch-retention-generations.md) — Accepted.
- [ADR-059 — V2 exact capsule curation and initial bindings](docs/adr/059-v2-exact-capsule-curation.md) — Accepted.
- [ADR-060 — V2 immutable capsule revisions and explicit composition plans](docs/adr/060-v2-immutable-capsule-revisions.md) — Proposed.
- [ADR-061 — V2 deterministic workspaces and explicit conflict records](docs/adr/061-v2-workspace-composition.md) — Accepted.
- [ADR-062 — V2 immutable releases and exact validation linkage](docs/adr/062-v2-immutable-releases.md) — Accepted.
- [ADR-063 — V2 local cache reclamation from complete reachable roots](docs/adr/063-v2-cache-reclamation.md) — Accepted.
- [ADR-064 — V2 user, repository, and device authority hierarchy](docs/adr/064-v2-user-repository-device-authority.md) — Superseded by ADR-065.
- [ADR-065 — V2 authority record causality](docs/adr/065-v2-authority-record-causality.md) — Accepted.
- [ADR-066 — macOS Keychain device custody and explicit enrollment](docs/adr/066-macos-keychain-device-custody.md) — Accepted.
- [ADR-067 — browser passkey PRF vault and origin-bound local custody](docs/adr/067-browser-passkey-prf-vault.md) — Accepted.
- [ADR-068 — offline recovery package and explicit replacement-device proposal](docs/adr/068-offline-recovery-package.md) — Accepted.
- [ADR-069 — bounded local secure-runtime IPC contract](docs/adr/069-v2-secure-runtime-ipc.md) — Accepted.
- [ADR-070 — V2 repository MLS bootstrap](docs/adr/070-v2-repository-mls-bootstrap.md) — Accepted.
