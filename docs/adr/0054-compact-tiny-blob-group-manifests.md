# ADR-0054: Publish compact mappings for tiny-blob aggregations

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

`YKTA` bounded up to 4,096 tiny Git blobs in one segment record, but import persisted one `YKMF` file for every entry. This retained unbounded per-file metadata growth across a repository even though the payload record was aggregated.

## Decision

Publish one immutable checksum-protected `YKTG` mapping for each `YKTA` aggregation. The mapping records its repository, manifest, segment, checksum, aggregation content identity, and sorted entry identities, SHA-256 body identities, and lengths. It is created lazily in `manifests/tiny-groups/`. Reconstruction converts a validated selected entry to an in-memory tiny `YKMF` shape; it does not write a per-object mapping.

## Consequences

New imports create one mapping per configured aggregation (512 entries under the initial policy), rather than one metadata file per tiny blob. `verify` and export validate every mapping entry against its one sealed aggregation. This adds a second resolver scan but preserves old `YKMF` tiny mappings and rejects duplicate Git IDs across both formats.

## Invariants

- A group mapping references exactly one verified aggregation record in one checksum-matched segment.
- Every group entry has a unique sorted Git ID and exact SHA-256 body identity and length.
- A reconstructed entry still passes final Git object-ID verification.
- Mapping publication is immutable, idempotent for identical bytes, and never replaces data.

## Compatibility and migration

`YKTG` is a new self-versioned immutable file under an optional directory, so the V1 bootstrap is unchanged and no migration is required. Existing repositories with only `YKMF` files remain readable. Future writers may leave legacy mappings untouched.

## Security and recovery

Readers bound mapping size and entry count before work, reject symlinks and unexpected directory entries, verify the mapping checksum, then independently verify the sealed aggregation and every selected Git ID. Recovery remains possible from immutable records without SQLite or a hosted service.

## Verification

Unit tests cover canonical mapping decoding, corruption, bounds, and thread safety. A 513-tiny-blob Git fixture proves import writes two compact mappings and no per-object `YKMF` files, then resolves, verifies, exports, and `git fsck`s the result. The manifest fuzz target includes `YKTG` decoding.
