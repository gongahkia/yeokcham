# ADR-0036: Aggregate bounded distinct tiny blobs in one canonical record

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Storing each tiny Git blob as an independent record creates disproportionate per-record framing and index overhead. The first aggregation slice must preserve every original blob independently, remain deterministic, and prevent a malformed aggregate from creating unbounded entry or body allocations. Storage policy thresholds, compression, segments, and manifests are not defined yet.

## Decision drivers

- Reduce future framing overhead without weakening per-blob verification.
- Ensure one logical set of entries has one canonical byte encoding.
- Bound entry cardinality and decode allocation before trust.
- Retain a content identity for both individual blobs and the aggregate record.
- Avoid silently selecting a policy threshold before benchmark evidence exists.

## Considered options

### Concatenate bodies without per-entry identities

This cannot resolve an individual Git blob safely and makes substitution or entry-boundary corruption hard to diagnose.

### Preserve caller insertion order

Equivalent imports could produce different aggregate bytes and content IDs. Duplicate objects would also become ambiguous.

### Sort distinct verified entries in a bounded aggregate

Strict Git-ID order provides deterministic bytes; per-entry IDs preserve independent reconstruction and verification; explicit caller limits protect decoding.

## Decision

Introduce `TinyBlobAggregation`, encoded as the `YKTA` version-1 record documented in [`serialization.md`](../serialization.md). It contains a SHA-256 aggregate content ID, then 1 through 4,096 entries sorted strictly by Git object ID. Each entry contains its verified Git blob ID, SHA-256 body content ID, exact length, and exact body. Duplicate IDs and non-blob/unverified constructor inputs are rejected.

The aggregate content ID is unkeyed SHA-256 over a fixed domain separator, the `u32` entry count, and every canonical entry field. The domain separator prevents treating an aggregate sequence as an ordinary blob body for content-ID purposes. All tags are the version-1 SHA-256 tag already assigned by ADR-0035.

The decoder accepts an already bounded record slice plus caller limits for entry count and cumulative body size. It rejects zero/excess entries, unsupported features/compression/tags, malformed entry lengths, non-strict order, mismatched entry IDs, mismatched aggregate ID, and trailing bytes before returning any record.

## Consequences

Tiny blobs can share later segment/index framing while retaining independent Git and content verification. The 4,096-entry cap limits one aggregate's metadata and recovery work; it is a format/resource boundary, not a default tiny-byte threshold or performance claim. A later storage policy selects which blobs group together and records that choice in manifests. The aggregate remains plaintext and must pass through later compression/encryption/segment layers before remote upload.

## Invariants

- An aggregation has 1–4,096 entries with strictly ascending unique Git blob IDs.
- Every entry is exactly a verified Git blob body and has a matching unkeyed SHA-256 ID.
- Aggregate identity binds entry count, order, IDs, lengths, and exact body bytes with the fixed domain separator.
- Decode allocations stay within caller-provided entry and cumulative-body bounds.
- No type, compression, feature, tag, order, length, or identity mismatch is repaired or accepted.
- Default diagnostics and `Debug` output redact source bytes and IDs.

## Compatibility and migration

`YKTA` version 1 is immutable once written. Entry sort order, content-tag codes, domain separator, record type, and the 4,096 maximum cannot change in place. Future compression, keyed/BLAKE3 IDs, different capacity, or aggregate semantics require a versioned record/migration contract. The local repository bootstrap and SQLite schema are unchanged.

## Security and recovery

The aggregate has no encryption or durable segment framing yet and is not safe to upload directly to an untrusted backend. Each entry's Git identity protects Git compatibility; entry and aggregate SHA-256 identities protect storage integrity. Unkeyed identities reveal equality if exposed; keyed modes remain deferred under ADR-0020. A corrupt aggregation fails before later reconstruction trusts any entry.

## Verification

Tests assert the complete canonical empty-blob aggregation bytes and aggregate SHA-256 ID; preserve binary bodies; canonicalize differing input orders; redact debug data; reject empty, duplicate, non-blob, and unverified input; reject malformed header, aggregate/entry identity, count, truncation, trailing data, and limits; and assert thread-safety. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
