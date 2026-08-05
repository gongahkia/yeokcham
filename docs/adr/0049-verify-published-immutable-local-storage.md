# ADR-0049: Publish and fully verify immutable local storage

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: ADR-0041
- Superseded by: None

## Context

`YKSG`, `YKIX`, `YKMF`, and `YKOM` now have local encodings, but no single operation validates the repository's persisted recovery material. `YKIX` was deliberately unpublished in ADR-0041; that leaves a full verification pass unable to bind any persisted index to its segment. SQLite remains local coordination state and must not become a verification dependency.

## Decision

Publish one rebuildable `YKIX` file per sealed segment at `indexes/<lowercase-segment-uuid>.ykix`. Accept publication only when the supplied index exactly equals `SegmentIndex::from_segment` for a verified matching segment. Stage `.<segment-uuid>.partial`, synchronize it, create the final name with a hard link without replacement, synchronize the directory, and verify identical existing bytes for idempotence.

Add a caller-bounded `LocalRepository::verify` operation. It revalidates the opened layout and bootstrap, scans every sealed segment, scans every published index, scans blob and metadata-object manifests, and reconstructs every manifest-referenced Git object through the existing segment verification boundary. It records only segment IDs and checksums between scan stages, so decoded payload bodies are not retained for the whole repository. It ignores only exact interrupted staging-file patterns and rejects every other entry in a scanned immutable directory. SQLite is excluded.

## Consequences

Verification is intentionally scan-based and may decode a segment more than once: once for the segment scan, once per index, and once for each referring manifest. This preserves simple independent trust boundaries. A missing or corrupt index fails verification when present, but deleting an index remains recoverable because indexes are rebuildable and not required for object reconstruction.

## Invariants

- A published index filename, embedded repository ID, segment ID, checksum, and canonical entries all bind one verified segment.
- Segments, indexes, and manifests are read under caller-selected directory, file, record, and plaintext limits.
- A successful report means every published manifest reconstructed to its final Git SHA-1 identity.
- Staging files are never trusted or reported as published data.
- SQLite success or failure is not evidence about recovery material.

## Compatibility and migration

Existing repositories with empty `indexes/` remain valid. `YKIX`, `YKSG`, `YKMF`, and `YKOM` bytes do not change. The flat local index path is a V1 publication convention; future sharding, encrypted names, or a different index format require a documented copy-on-write migration that retains this path reader.

## Security and recovery

All persistent bytes and names are hostile. Verification rejects symlinks, non-regular files, malformed names, identity mismatches, unknown entries, corrupt checksums, and final Git-ID mismatches without disclosing object bodies. The scan is not a filesystem snapshot; concurrent mutation returns an error when detected but callers needing a stable snapshot must coordinate writers externally. Cryptographic checksums detect corruption but do not authenticate a hostile backend before the later encryption/authentication design.

## Verification

Tests cover empty and populated scans, idempotent index publication, altered bootstrap, segment, index, both manifest families, missing segments, recognized staging files, unexpected entries, and directory/file limits. Full formatting, lint, tests, docs, and Linux Rust 1.85 CI must pass before acceptance.
