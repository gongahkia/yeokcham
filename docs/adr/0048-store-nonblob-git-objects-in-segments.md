# ADR-0048: Store non-blob Git objects in segments and direct manifests

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Blob manifests and records reconstruct only blobs. SQLite retains non-blob object ID, kind, and size, but deliberately contains no canonical body and cannot support recovery. Trees, commits, and annotated tags require durable exact bodies and a direct Git-ID-to-record mapping before conventional export or full verification can be correct.

## Decision drivers

- Preserve exact bodies and final Git identities for trees, commits, and tags.
- Keep canonical recovery data independent of SQLite.
- Reuse sealed segment verification instead of adding a second object container.
- Avoid O(number of segments) metadata lookup in normal reconstruction.
- Make older readers fail as unsupported before interpreting new segment types.

## Considered options

### Retain bodies only in SQLite

This makes local coordination state a recovery dependency and violates the repository recovery model.

### Scan every segment for a Git ID

This can recover data without a new mapping but is unsuitable for metadata-heavy histories and leaves ambiguity handling on every caller.

### One ad hoc raw file per Git object

It bypasses segment integrity, duplicates publishing logic, and creates a separate persistent format.

### Metadata-object records in segments plus direct immutable manifests

Segments retain one common integrity and publication boundary. A direct manifest identifies the exact segment and record without scanning normal storage.

## Decision

Use `YKMO` version-1 records for verified Git trees, commits, and annotated tags. Each record stores its non-blob kind, Git SHA-1 ID, a domain-separated SHA-256 plaintext identity, and exact body bytes. Segment record type `3` carries `YKMO` payloads. Segment required feature bit `0` is set exactly when a type-3 record is present; the matching index required feature bit is also set. Readers reject unsupported feature bits and reject a missing or extraneous metadata-object feature as corrupt data.

Use `YKOM` version-1 manifests for direct Git-ID lookup. A manifest binds repository ID, Git ID, kind, plaintext identity and length, segment ID, and segment checksum. Its local immutable path is `manifests/objects/<lowercase-git-sha1>.ykom`. The directory is optional for existing version-1 repositories, created lazily on first publication, and validated when present. Publication uses same-directory staging, file synchronization, hard-link creation without replacement, and directory synchronization. Byte-identical republishing is idempotent; a different value at one Git ID conflicts.

Reconstruction resolves the direct manifest, completely verifies the referenced segment, finds exactly one matching type-3 record, rechecks every manifest binding, and recomputes canonical Git SHA-1 before returning a `GitObject`.

## Consequences

Metadata objects receive the same immutable storage and recovery boundary as blobs. Direct per-object manifests increase file count in this correctness-first slice, but avoid normal-path segment scans. A future packed object map may replace or supplement direct manifests only through a documented versioned migration. Existing SQLite metadata remains an optional local index.

## Invariants

- A metadata record never represents a blob.
- Its Git kind, exact body, Git ID, and domain-separated content identity verify together.
- A type-3 segment or index entry is never accepted without required feature bit `0`.
- One direct manifest names one exact repository, non-blob Git ID, segment checksum, and record identity.
- No metadata object is returned before complete segment and final Git-ID verification.
- A conflicting same-ID manifest is never overwritten or selected implicitly.

## Compatibility and migration

Existing segments and indexes with zero required features remain readable. New metadata-object segments and indexes set required bit `0`, so older readers reject them as unsupported. `YKOM` is a new record family; existing repositories retain no objects directory until first metadata-object publication. Git SHA-256 repositories remain unsupported under the existing compatibility policy.

## Security and recovery

Segment bytes and manifests are hostile. Callers provide manifest, segment, and nested-record bounds; regular-file checks reject direct symlinks; checksums detect corruption before record selection; final Git identity protects reconstruction. SHA-256 checksums and content identities do not authenticate a backend. The direct filename exposes a Git SHA-1 ID until later metadata encryption and opaque naming work.

## Verification

Unit tests cover `YKMO` tree, commit, and tag round trips; malformed, oversized, corrupt, blob, and unverified records; `YKOM` round trips and record absence; feature-gated segment and index records; direct publish, idempotence, resolution, reopen, final reconstruction, conflicts, caller limits, tampered segments, redacted errors, and symlinked manifest-directory rejection. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
