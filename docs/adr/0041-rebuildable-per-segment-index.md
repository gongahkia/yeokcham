# ADR-0041: Use a rebuildable canonical index per immutable segment

- Status: Superseded by ADR-0049
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: ADR-0049

## Context

Verified segments contain typed payloads in insertion order, but resolving content by ID needs a compact lookup structure. An index is local/remote acceleration metadata, not the canonical source: it must be bound to one exact segment checksum and rebuildable by scanning that segment. The segment reader therefore exposes validated payload locations only after verifying the entire segment.

## Decision

Define a `YKIX` version-1 index for exactly one `YKSG` segment. Its header stores repository ID, segment ID, segment checksum, and entry count. Entries are strictly sorted by tagged content ID and store record type, compression method, payload offset, plaintext length, and stored length. A `YKIF` footer stores aggregate lengths and an unkeyed SHA-256 checksum over all preceding index bytes. `SegmentIndex::from_segment` builds this index only from a verified `ReadSegment`; decode validates all fields, bounds, order, totals, checksum, and trailing bytes before lookup is available.

The index is not published, treated as authoritative, or used to bypass segment reader verification in this slice. A missing, stale, or corrupt index is recoverable by scanning its bound segment.

## Consequences

Future manifest resolution can locate content in a segment without parsing every payload. Indexes duplicate metadata and need separate integrity checks, but have no irreplaceable state. New record types, compression, encryption, or location semantics require a versioned evolution.

## Invariants

- Every index binds one repository ID, segment ID, and segment checksum.
- Entries are unique and strictly sorted by full tagged content identity.
- Entry locations and lengths are copied only from a verified segment reader result.
- Decoding checks bounds, totals, tags, sort order, checksum, and trailing bytes before returning entries.
- An index never substitutes for verifying segment bytes during recovery.

## Compatibility and migration

`YKIX` version 1 is immutable once written. The segment format remains `YKSG` version 1. Future indexes need a new version/feature and can be rebuilt beside existing indexes; no rewrite of a segment is permitted.

## Security and recovery

Index bytes are hostile/cacheable metadata. Caller bounds and checked arithmetic limit decoding. SHA-256 detects corruption but does not authenticate a backend; later encryption/authentication covers both segments and indexes. Recovery can discard any index and rebuild from verified segment bytes.

## Verification

Tests cover canonical bytes, lookup, sorted order, segment-checksum binding, decode limits, malformed fields, duplicate/out-of-order entries, footer/checksum/trailing corruption, redacted diagnostics, and thread-safety. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
