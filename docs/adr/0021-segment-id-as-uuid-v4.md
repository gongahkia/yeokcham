# ADR-0021: Represent segment IDs as UUIDv4 bytes

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Segments are sealed immutable containers. Their IDs appear in indexes, remote object keys, and encryption associated data before payload encryption, while segment integrity is checked by a separate checksum. A segment identity therefore cannot depend on its final encrypted bytes without a circular construction.

## Decision drivers

- Segment identity must be available before encryption and upload.
- IDs must not expose source content, paths, host data, or timestamps.
- The binary form must be fixed-width and broadly interoperable.
- Integrity verification must remain independent of object naming.
- Generation and parsing must use a maintained implementation compatible with the project MSRV.

## Considered options

### Content-derived segment hash

This can support deduplication but cannot bind the final segment ID into encryption associated data before computing the final encrypted bytes. It also duplicates the separate segment integrity checksum role.

### Timestamp-ordered identifier

This can improve insertion locality but exposes segment creation timing in remote object names.

### UUIDv4

UUIDv4 provides a standard 128-bit layout, offline random generation, fixed-width storage, and mature implementations without embedding time or host identity.

## Decision

`SegmentId` stores exactly 16 bytes containing an RFC 9562 UUIDv4 with the RFC variant. New segments generate their ID before encryption. Binary construction validates the version and variant. Text parsing accepts only the 36-byte lowercase hyphenated form; formatting emits that form.

The ID is opaque and distinct from the segment integrity checksum and all content identities. `Debug` redacts the value under the observability policy. `Display` deliberately reveals the canonical value for explicit persistence and inspection paths and must not be used in tracing fields.

## Consequences

Segment IDs can be allocated offline before encryption and uploads can use put-if-absent semantics. Random IDs do not provide chronological ordering. A pre-existing remote object under the same ID must be verified as identical or treated as a conflict; it must never be overwritten.

## Invariants

- Every constructed `SegmentId` has UUID version 4 and the RFC variant bits.
- Segment identity is available before encryption and remains stable after sealing.
- Segment ID and integrity checksum have independent purposes.
- Default diagnostic formatting does not expose segment identity.

## Compatibility and migration

This defines the segment ID primitive before a segment format exists. Persistent formats must store its 16-byte representation and declare their own enclosing format version. No migration is required.

## Security and recovery

Segment IDs are metadata, not secrets, encryption keys, integrity proofs, or proof of ownership. UUIDv4 generation depends on the platform randomness used by the `uuid` crate. Recovery validates the stored ID and segment checksum independently; it never regenerates an ID for an existing segment.

## Verification

Unit tests validate generated version and variant bits, canonical text and byte round trips, malformed input, noncanonical text, unsupported version and variant values, and redacted `Debug` output. CI checks the dependency and tests on the MSRV and stable Rust.
