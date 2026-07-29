# ADR-0026: Use fixed-width canonical binary serialization

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Yeokcham stores byte-sensitive Git and cryptographic metadata in persistent, recoverable records. Native-memory layout, generic serializer defaults, JSON text, and non-deterministic maps would make reconstruction, hashing, signing, recovery, or cross-version comparison ambiguous. Valid Git ref names can contain non-UTF-8 bytes. A canonical policy must be simple enough to audit and parse with bounded allocation.

## Decision drivers

- One logical record must have one byte encoding.
- Every persistent scalar must have an explicit stable width and byte order.
- Arbitrary bytes, including Git ref names, must survive exactly.
- Parsers must fail closed on truncation, overflow, invalid typed fields, and trailing data.
- The initial implementation must not depend on an unpinned serializer's canonicalization behaviour.

## Considered options

### JSON or generic `serde` binary formats

These are convenient but do not inherently define byte ordering, map ordering, non-UTF-8 text handling, unknown-field policy, or one encoding per value.

### Deterministic CBOR

[RFC 8949](https://datatracker.ietf.org/doc/html/rfc8949) defines deterministic encoding, but available Rust implementations vary in deterministic map handling and MSRV. A generic map-based format would also add complexity before Yeokcham has record schemas.

### Fixed-width canonical binary fields

Fixed big-endian scalars, raw fixed bytes, and length-delimited byte strings provide a small, byte-preserving, directly auditable foundation without bit packing or implicit serializer behaviour.

## Decision

Persistent records use the policy in [`serialization.md`](../serialization.md). Unsigned integers use fixed-width big-endian bytes; fixed identities use raw validated bytes; variable byte strings use a big-endian `u64` length followed by exact bytes. Record-specific fields have a documented fixed order. Records use four-byte ASCII family magic, `u16` schema version, and `u64` required and optional feature bit sets before payload fields.

Maps, unordered sets, floats, varints, native widths, implicit defaults, duplicate singular fields, and trailing bytes are prohibited. Decoders operate on a caller-bounded slice, allocate no data for byte-string fields, and reject malformed or surplus input. Future record schemas define their own limits before decoding untrusted streams into memory.

## Consequences

Record bytes are deterministic across platforms and preserve raw Git-compatible bytes. The format is verbose for small integers but has no ambiguous alternate encoding. New record families must document their field sequence and limits. The core codec is deliberately minimal; it does not serialize a repository or perform I/O by itself.

## Invariants

- A logical record has one field order and one byte sequence.
- Fixed-width numeric values always use the stated big-endian width.
- Valid non-UTF-8 bytes are never converted through text.
- Decoders reject truncation, invalid lengths, and trailing bytes before trust.
- Unknown required semantics never become silently ignorable.

## Compatibility and migration

This defines encoding rules before any repository record exists. Every new persistent record declares a family magic, schema version, feature flags, field order, and bounds. Incompatible changes create a new schema version or required feature bit. Migration is copy-on-write, resumable, verifiable, and reversible until finalisation; old record bytes remain readable.

## Security and recovery

The decoder borrows byte strings from a caller-bounded slice and uses checked length arithmetic. Record parsers must set field and record limits before reading hostile storage or remote data. Canonical bytes support unambiguous checksum, signature, and associated-data construction but do not replace cryptographic verification or authenticated encryption.

## Verification

Unit tests assert exact known bytes, round-trip fixed fields and non-UTF-8 byte strings, and reject truncation and trailing data. CI checks the codec on the MSRV and stable Rust. Each future record family adds golden canonical-byte fixtures and malformed-input tests.
