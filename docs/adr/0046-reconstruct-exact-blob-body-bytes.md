# ADR-0046: Reconstruct exact blob body bytes from a verified manifest record

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

After a `YKMF` manifest names a verified `YKSG` record, callers need the exact Git blob body to export or build an object. Version-1 whole-blob and tiny-aggregation records already retain raw bodies, but the selected tiny entry must not be confused with its enclosing aggregate or another entry.

## Decision drivers

- Preserve every raw body byte, including NUL and non-UTF-8 values.
- Reuse the complete bounded segment-verification path.
- Select exactly the manifest-named tiny entry.
- Keep final Git-object verification explicit and separately testable.

## Considered options

### Return a decoded record to every caller

This leaks representation handling into export and recovery callers and makes tiny-entry selection easy to repeat incorrectly.

### Reconstruct a `GitObject` immediately

That combines byte extraction with the next final-identity task and obscures its error boundary.

### Return selected raw bytes after verified record resolution

The current records preserve the exact bytes. A small representation-aware method centralizes selection while leaving final Git-object construction to the next slice.

## Decision

`LocalRepository::reconstruct_blob_bytes` accepts a manifest, a maximum segment-file size, and `SegmentReadLimits`. It first resolves the manifest record through `resolve_manifest_record`; all repository, segment, checksum, typed-record, selected-entry, and caller-bound checks occur before copying output. A whole-blob manifest returns that record's raw body. A tiny-aggregation manifest returns only the entry whose Git ID equals the manifest Git ID. A missing expected typed record or tiny entry is corrupt data.

The method returns `Vec<u8>` containing only raw Git blob body bytes. It neither creates nor returns a `GitObject` and introduces no new persistent bytes or path convention. Final Git object ID verification remains the next explicit operation.

## Consequences

Export and recovery callers receive one representation-independent body API. The copied result duplicates the selected body in memory; the existing bounded segment reader already owns the decoded record, and its limits bound this allocation in version 1. Streaming and chunk-list reconstruction require a later format and API contract.

## Invariants

- Returned bytes equal the selected stored Git blob body byte-for-byte.
- No bytes are returned before complete segment and manifest-record verification.
- Tiny aggregation reconstruction selects the manifest Git ID, never aggregate order or the first entry.
- NUL and non-UTF-8 bytes are preserved.
- This boundary does not silently substitute final Git-ID verification.

## Compatibility and migration

No persistent format changes. Future compressed, encrypted, chunk-list, or streaming records may extend reconstruction behind a versioned representation contract while retaining exact-body semantics.

## Security and recovery

The method accepts hostile manifest and segment data only through the prior bounded resolver. It exposes raw source bytes to its direct caller by design and does not log them. Missing or malformed storage fails without returning a partial body.

## Verification

Tests reconstruct exact binary whole and selected tiny bodies, reject a missing segment, and confirm the error does not disclose a body. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
