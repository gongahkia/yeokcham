# ADR-0040: Read and verify bounded `YKSG` version-1 segments

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The `YKSG` writer now creates immutable segment files, but recovery and future indexes cannot trust those bytes without a bounded reader. Segment payloads contain nested `YKWB` or `YKTA` records, each with its own identity checks. The reader must validate framing, declared identities, lengths, totals, nested content identities, checksum, and trailing bytes before any result becomes available.

## Decision drivers

- Treat every segment byte sequence as hostile.
- Bound all outer and nested allocations before copying payload bytes.
- Preserve exact writer-reader compatibility through a canonical fixture.
- Return typed verified whole-blob and tiny-aggregation records to later resolvers.
- Keep checksum verification distinct from future authenticated encryption.

## Considered options

### Trust an index to locate records

The index does not exist yet and will itself be untrusted/cacheable. Recovery must be able to rebuild it from segments.

### Return opaque payload slices after checking only the outer framing

This would defer nested corruption to every caller and lets an outer content identity disagree with its actual record.

### Fully validate nested records before returning a typed segment

This centralizes limits and rejects mismatched metadata once, while preserving later resolver simplicity.

## Decision

Introduce `SegmentReader::decode` with explicit `SegmentReadLimits`. The caller supplies an already-bounded byte slice plus limits for record count, aggregate stored/plaintext bytes, whole-blob body bytes, tiny-aggregation entry count, and tiny-aggregation body bytes.

The reader parses `YKSG` version 1 in strict field order. It validates zero feature bits, UUIDv4 repository/segment IDs, nonzero bounded count, recognized record/content/compression tags, `none` plaintext/stored length equality, checked aggregate totals, exact record payload lengths, `YKSF` footer, SHA-256 checksum, and no trailing bytes. For each record it decodes the typed nested `YKWB` or `YKTA` payload under its own limits and requires its content ID to equal the outer metadata. Only then does it return `ReadSegment` with typed records.

Malformed declared data is `CorruptData`; a recognized but unavailable format version, feature, compression, or content algorithm is `Unsupported`. The checksum is unkeyed integrity detection and does not authenticate an attacker.

## Consequences

Indexes and manifests can later consume typed verified records and segment locations without reimplementing record parsing. The reader copies nested record bodies but has explicit limits for every allocation path. Segment version 1 is readable only for its current two payload families; later record types must add both writer and reader handling under a new format decision.

## Invariants

- No segment, payload, identity, or checksum is returned before all outer and nested checks succeed.
- Record insertion order is preserved in the returned sequence.
- Every returned typed record has an outer content ID equal to its independently verified nested content ID.
- Declared lengths, counts, and totals are checked before consuming or allocating corresponding data.
- A byte appended, removed, reordered, or changed in a sealed segment causes rejection.
- `Debug` and public errors redact payload bytes and identifiers by default.

## Compatibility and migration

The reader implements exactly `YKSG` version 1 from ADR-0039 and does not alter stored bytes. Future versions/features/codecs require explicit reader support and copy-on-write migration. The V1 bootstrap, SQLite metadata, and record encodings remain unchanged.

## Security and recovery

The reader is a recovery boundary and depends only on segment bytes and caller limits, not SQLite or a hosted service. Bounds cover length conversion, total arithmetic, nested whole-blob decoding, and tiny-aggregation decoding. SHA-256 checks accidental corruption but not source authenticity; encryption/authentication and final Git-object verification remain later mandatory layers.

## Verification

Tests round-trip a writer-produced canonical segment; preserve typed record order and content IDs; reject malformed magic/version/features/IDs/tags/lengths/totals/footer/checksum/truncation/trailing bytes and caller limits; verify nested outer-ID mismatch rejection; redact debug/errors; and assert thread-safety. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
