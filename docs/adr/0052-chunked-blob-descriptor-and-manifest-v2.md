# ADR-0052: Store chunked blobs through immutable descriptors and `YKMF` version 2

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: ADR-0042
- Superseded by: None

## Context

ADR-0037 defines deterministic FastCDC boundaries, but those boundaries were not connected to persistent storage. ADR-0042 reserves `YKMF` version 1 for one whole-blob or tiny-aggregation record. A chunked blob needs ordered references to independently verified chunks while preserving a single manifest-to-segment relationship and exact final Git-object reconstruction.

## Decision drivers

- Deduplicate immutable chunk bytes within one repository.
- Preserve the exact Git blob body and SHA-1 identity.
- Keep every resolved chunk independently integrity-checked.
- Retain a compact, portable, bounded manifest lookup path.
- Make existing version-1 manifests immutable and fail closed in old readers.

## Considered options

### Expand `YKMF` version 1 with a chunk list

This contradicts ADR-0042's immutable version-1 contract and risks older readers misinterpreting new semantics.

### Make each manifest reference every chunk directly

This removes the existing single-record manifest invariant, makes manifests grow with every chunk, and requires a new multi-segment resolution format immediately.

### Store a chunked-blob descriptor as the single manifest record

The descriptor retains ordered immutable chunk references, while the manifest continues to bind one exact descriptor segment and checksum. Each referenced chunk resides in an immutable segment and is checked during reconstruction.

## Decision

Add `YKCK` version-1 `ChunkRecord` records, each containing one nonempty plaintext chunk and its tagged unkeyed SHA-256 identity. Add `YKCB` version-1 `ChunkedBlobRecord` descriptors, each containing the repository ID, final Git blob ID, full-blob SHA-256 identity, plaintext length, and ordered chunk references. A chunk reference binds the chunk ID, exact length, segment ID, and segment checksum.

Add segment record tags `4` (`Chunk`) and `5` (`ChunkedBlob`). New chunked manifests write `YKMF` version 2 with required feature bits `storage_policy` and `chunked_blob`; version 2 accepts only the `ChunkedBlob` representation and policy tag. Existing whole and tiny manifests remain byte-for-byte version 1. Readers that do not implement version 2 or its required feature fail with `Unsupported`.

The local store writes one immutable chunk record per new content identity in this initial correctness slice, publishes a rebuildable index, and reuses an existing verified chunk record when its identity matches. It then writes a descriptor segment and publishes the manifest. Segment packing is a later benchmark-driven compaction concern; no performance claim is made here.

## Consequences

Chunked blobs now have a complete recovery path and repeated immutable chunk bytes can share storage. A single logical blob can require several segments, even though its manifest still resolves a single descriptor record. Initial one-record chunk segments create overhead and are deliberately not a remote-storage design claim.

## Invariants

- Every chunk record recomputes SHA-256 over its exact nonempty bytes before use.
- Every descriptor reference binds one segment ID, checksum, chunk ID, and exact length.
- Descriptor chunk lengths sum exactly to the recorded blob length.
- Reconstruction verifies every referenced segment, chunk record, final SHA-256 body identity, and final Git blob ID.
- New immutable chunks and descriptor segments publish before the manifest; interrupted imports leave only unreachable immutable records.
- Indexes remain rebuildable acceleration data and never replace segment verification.

## Compatibility and migration

`YKMF` v1 remains unchanged. `YKMF` v2 is a new write format only for `ChunkedBlob`; v1 readers reject it. Existing blobs need no migration. Repacking or changing chunk parameters must write new records and manifests, never alter historical chunk references in place. `YKCK` and `YKCB` v1 readers reject unknown mandatory features, versions, tags, malformed references, trailing data, and checksum mismatches.

## Security and recovery

Chunk identities are unkeyed SHA-256 under ADR-0020 and therefore expose equality within the repository's local trust domain. Each chunk, descriptor, manifest, and segment checksum is verified before bytes are returned; final Git SHA-1 verification remains mandatory. A corrupt, missing, duplicated, or mismatched referenced chunk fails reconstruction without emitting trusted blob bytes. SQLite remains non-canonical and is not used to recover chunk locations.

## Verification

Tests cover canonical chunk and descriptor decoding, malformed/corrupt/oversized records, segment-reader support, cross-blob chunk reuse, exact reconstruction of two related binary blobs, full immutable-storage verification, and final Git-ID verification. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
