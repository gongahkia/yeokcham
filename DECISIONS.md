# Architecture Decision Records

This file contains initial decisions. They may change only through an explicit ADR update with rationale and migration implications.

## ADR-001 — Preserve Git object identities

**Decision:** Relay preserves Git object IDs at the compatibility boundary.

**Reason:** Existing Git history, GitHub interoperability, verification, and conventional export depend on stable identities.

**Consequence:** Relay may chunk blob content internally, but must reconstruct exact Git object bytes.

## ADR-002 — Rust implementation

**Decision:** Use stable Rust for Relay.

**Reason:** The project requires binary parsing, cryptography, concurrency, filesystem work, streaming, fuzzing, and cross-platform static binaries.

**Consequence:** Prefer established crates and avoid unsafe code unless a measured bottleneck justifies it.

## ADR-003 — Use mature Git primitives

**Decision:** Use gitoxide or another mature implementation for low-level Git functionality where appropriate.

**Reason:** Reimplementing the full Git object and pack ecosystem is not Relay's differentiation.

**Consequence:** Wrap dependencies behind Relay-owned interfaces to preserve testability and future replacement.

## ADR-004 — Remote helper first

**Decision:** Implement `git-remote-relay` before smart HTTP or SSH.

**Reason:** It provides a narrow integration surface and allows local end-to-end validation.

**Consequence:** Initial repositories are accessed through an installed helper rather than generic Git hosting.

## ADR-005 — SQLite as local metadata database

**Decision:** Use SQLite for local coordination, indexes, migration state, and cache metadata.

**Reason:** It provides transactions, inspection, portability, and mature tooling.

**Consequence:** SQLite is not the only canonical copy of remote repository metadata.

## ADR-006 — Immutable remote data

**Decision:** Segments, indexes, manifests, and journal entries are immutable once published.

**Reason:** Generic object stores do not provide repository-wide transactions or locking.

**Consequence:** Updates create new generations and small append-only events.

## ADR-007 — Adaptive storage policy

**Decision:** Do not content-defined-chunk every blob.

**Reason:** Chunking overhead can be worse than whole-blob compression for tiny source files.

**Consequence:** Policies must be explicit, measurable, and recorded in manifests.

## ADR-008 — Deduplicate before encryption

**Decision:** Compute content identities and deduplicate within a user's trust domain before encrypting records for remote storage.

**Reason:** Encrypting first removes useful equality information.

**Consequence:** Cross-user deduplication is not supported because it complicates privacy and threat boundaries.

## ADR-009 — Google Drive as dumb blob storage

**Decision:** Never place a live `.git` directory inside a synchronised Drive folder.

**Reason:** Git ref and object updates require semantics generic file sync does not guarantee.

**Consequence:** Relay uploads immutable opaque files and manages transactions itself.

## ADR-010 — Explicit GitHub publication

**Decision:** GitHub receives only selected refs under explicit mirror policies.

**Reason:** Source uploaded to GitHub is no longer private from GitHub, and GitHub should not be the canonical source by default.

**Consequence:** Pull requests require publication of relevant commits.

## ADR-011 — No silent force pushes

**Decision:** Bidirectional GitHub synchronisation shall not silently force-update refs.

**Reason:** Divergence must be visible and recoverable.

**Consequence:** Users may need to resolve mirror conflicts manually.

## ADR-012 — Recovery before optimisation

**Decision:** Full verification and conventional Git export are required before remote performance work.

**Reason:** Lock-in and silent corruption would invalidate the product thesis.

**Consequence:** Early milestones may be slower than Git.

## ADR-013 — SHA-1 first

**Decision:** Initial compatibility targets ordinary SHA-1 Git repositories.

**Reason:** Supporting multiple Git hash algorithms increases scope before the storage model is validated.

**Consequence:** SHA-256 repositories are a later milestone and must fail clearly before support exists.

## ADR-014 — Single-user first

**Decision:** Initial self-hosting is single-user.

**Reason:** Multi-user authorisation, tenancy, quotas, and collaboration would obscure the core storage work.

**Consequence:** Server interfaces should not imply production multi-tenancy.

## ADR-015 — No universal performance claim

**Decision:** Relay publishes workload-specific benchmark results and regressions.

**Reason:** Storage and retrieval strategies have unavoidable trade-offs.

**Consequence:** Marketing and documentation must say where Relay loses.
