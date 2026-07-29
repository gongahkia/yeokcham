# ADR-0037: Use bounded FastCDC v2016 chunk boundaries

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Large related Git blobs need stable content-defined boundaries before they can share chunk records. Fixed-size chunks are displaced by inserted bytes and do not meet this use case. The storage policy, chunk records, manifests, compression, and segment format remain later Milestone 1 work, so this decision must define only the deterministic boundary function and its resource limits.

## Decision drivers

- Produce the same ordered boundaries for identical bytes and parameters.
- Bound chunk count and avoid caller-provided values that make the implementation invalid.
- Keep the first implementation small, maintained, and independently testable.
- Do not make unmeasured throughput or deduplication claims.
- Leave persistent policy thresholds and format commitments to their dedicated work items.

## Considered options

### Fixed-size chunking

This is simpler but boundary positions change after an insertion and it does not satisfy the required content-defined-chunking slice.

### Rabin-fingerprint chunking

This is an established CDC approach, including in LBFS, but requires selecting and maintaining a rolling-window polynomial implementation and its parameters now.

### FastCDC v2016 through a pinned dependency

The 2016 [FastCDC paper](https://www.usenix.org/system/files/conference/atc16/atc16-paper-xia.pdf) specifies a Gear-hash CDC algorithm with minimum, average, and maximum chunk sizes. A version-pinned Rust implementation supplies the algorithm while Yeokcham owns validation, output bounds, SHA-256 chunk identities, and test fixtures.

## Decision

Use `fastcdc = 4.0.1` exactly, with its `v2016::FastCDC` implementation and normalization level 1. It uses the unseeded, published Gear table. The non-cryptographic Gear value only selects boundaries; every emitted chunk receives the tagged unkeyed SHA-256 content identity defined by ADR-0020.

The public API requires explicit minimum, average, and maximum sizes plus a maximum output chunk count. It rejects values outside the dependency's documented supported ranges, values not ordered `minimum <= average <= maximum`, and a zero chunk limit. It returns ordered byte ranges and identities without retaining source bytes. Empty input returns no chunks. A preflight rejects an input that cannot fit in the requested count even at the maximum chunk size; iteration stops and fails before allocating past that limit.

No default sizes, blob-selection threshold, seed, persistent chunk encoding, or chunking-policy setting is introduced here. The selected algorithm and parameter values must later be recorded with chunked representations so recovery does not infer them from mutable configuration.

## Consequences

The first chunker is deterministic for fixed bytes, dependency version, normalization, and parameters. Cargo pins the dependency exactly, and golden boundary fixtures detect unintended implementation changes. Future algorithms, normalization levels, seeds, or parameter encodings need a new ADR and versioned manifest representation; no existing chunked data may be reinterpreted under a new setting.

`fastcdc` is a boundary selector, not an integrity primitive. The implementation remains plaintext-only until later compression, segment, encryption, and manifest layers exist.

## Invariants

- Output ranges are contiguous, ordered, non-overlapping, and cover input exactly.
- Every non-final chunk respects the configured minimum and every chunk respects the configured maximum.
- Every emitted content ID is SHA-256 of exactly its returned byte range.
- Invalid configuration and output-limit exhaustion fail without source bytes in public diagnostics.
- The Gear fingerprint never serves as a content identity or integrity check.

## Compatibility and migration

There is no persistent chunk record or manifest in this slice. Once a manifest stores chunked data, it must record an immutable algorithm identifier and parameters. Migrating to any other CDC choice requires writing new records and manifests; it cannot alter historical boundaries in place.

## Security and recovery

The input is caller-owned and may be hostile. Explicit parameters and chunk-count bounds prevent invalid dependency calls and unbounded output-vector growth. SHA-256 content identities are recomputed from chunk bytes, but they do not replace later final Git-object verification. Unkeyed identities reveal equality when exposed; ADR-0020 governs future keyed modes and recovery keys.

## Verification

Tests cover empty and binary input, exact golden boundaries, deterministic repeated chunking, coverage and size invariants, content-ID correctness, invalid configurations, early count-limit rejection, limit exhaustion, redacted diagnostics, and thread-safety. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
