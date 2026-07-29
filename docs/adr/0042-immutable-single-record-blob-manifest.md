# ADR-0042: Reference one verified segment record per blob manifest

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Segments and rebuildable indexes now hold verified whole-blob and tiny-blob-aggregation records, but no portable record names the representation required to reconstruct one Git blob. A manifest must bind the Git blob, its plaintext identity and length, and its immutable storage record without making an index authoritative. The current segment format has no persistent chunk record, so a chunk-list manifest would name unavailable storage.

## Decision drivers

- Preserve exact Git blob reconstruction and final Git-ID verification.
- Reference only already verified immutable records and segments.
- Keep indexes disposable acceleration metadata.
- Bind the manifest to one exact segment checksum.
- Use a small versioned format with no unbounded decoding allocation.

## Considered options

### Map a Git ID directly to a segment ID

This omits representation type, content identity, plaintext length, and the exact record inside a multi-record segment.

### Add a general chunk-list manifest now

No chunk payload record or segment reader exists yet. Naming speculative records would not provide a recovery path.

### Reference one verified current record

Whole blobs can reference their body identity. Tiny blobs can reference their enclosing aggregation while the manifest Git ID selects the independently verified entry. This meets the current storage boundary and leaves chunk lists to a later version.

## Decision

Define `YKMF` version 1 for one immutable Git SHA-1 blob representation. It stores repository ID, opaque manifest ID, Git blob ID, SHA-256 body content ID, exact plaintext length, representation tag, segment ID, segment checksum, and outer record content ID. It ends with `YKBF` and an unkeyed SHA-256 checksum over all preceding bytes.

Version 1 permits only `WholeBlob` and `TinyBlobAggregation` representations. A whole-blob manifest requires identical body and outer-record content IDs. A tiny-aggregation manifest stores the selected blob's ID/content/length plus the aggregation content ID. Constructors accept only a fully verified `ReadSegment` and an equal typed record already present in it; a tiny selection must exist in that aggregation. Decode validates format, UUIDs, SHA-256 tags, caller plaintext bound, representation, whole-record identity equality, footer, checksum, and trailing bytes.

The manifest contains no body, location, or index assertion. Resolution later verifies the referenced segment's repository ID, segment ID, checksum, typed record, exact blob bytes, content identity, length, and Git ID before returning data.

## Consequences

One blob can have multiple immutable manifests as storage policy evolves. A manifest does not include a policy decision or resolve a Git ID by itself; local mappings and resolution are separate work. Indexes remain rebuildable because manifests identify an outer record by content identity rather than copying an offset. Chunked manifests, multiple record references, and new record types require a format evolution.

## Invariants

- A manifest names one Git SHA-1 blob and one exact sealed segment checksum.
- The selected body identity and exact length are explicit.
- A whole-blob manifest's lookup identity equals its body identity.
- A tiny-aggregation manifest names its enclosing aggregation and one verified entry.
- Constructors never reference a record absent from the supplied verified segment.
- Decode returns no manifest before all structure, bounds, and checksums validate.
- An index never replaces segment verification during reconstruction.

## Compatibility and migration

`YKMF` version 1 is immutable. Its magic values, field order, SHA-256 tag requirement, representation tags, and checksum domain cannot change in place. Existing segments and indexes remain unchanged. Future chunk lists, compression, encryption, keyed/BLAKE3 body IDs, multiple references, or Git SHA-256 object IDs require a new version or required feature and copy-on-write manifests.

## Security and recovery

Manifest bytes are hostile metadata and default diagnostics redact identities. The manifest has no plaintext body and decoding makes no variable-sized allocation; the caller still supplies a plaintext-length bound before accepting a record. SHA-256 detects accidental corruption but does not authenticate a backend. Recovery can discard a corrupt manifest only when another manifest or metadata mapping reaches the sealed segment; it must never trust a manifest, index, or segment independently of final blob/Git-ID verification.

## Verification

Tests cover canonical whole-manifest round-trip, verified tiny-entry references, absent records and entries, malformed magic/version/features/tags/representation/footer/checksum/trailing bytes, plaintext bounds, redacted diagnostics, and thread-safety. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
