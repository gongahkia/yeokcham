# ADR-0019: Represent repository IDs as UUIDv4 bytes

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Repository metadata, encryption associated data, ref events, cache keys, and remote records need one stable repository identity. The identity must be generated offline without backend coordination, have a fixed canonical representation, and remain distinct from Git and Yeokcham content identities.

## Decision drivers

- Generation must work without central registration or source-repository metadata.
- Readers must reject malformed, ambiguous, and unsupported representations.
- The binary form must be fixed-width and broadly interoperable.
- The identifier must reveal no host, path, content, or creation-time data.
- Generation and parsing must use a maintained implementation compatible with the project MSRV.

## Considered options

### Repository path or Git-derived identity

Paths are mutable and disclose metadata. Git object IDs identify content graphs, not a stable Yeokcham repository across ref changes.

### Custom random identifier

A custom format could provide sufficient entropy but would add an unnecessary parser, formatter, and interoperability contract.

### UUIDv4

UUIDv4 provides a standard 128-bit layout, offline random generation, fixed-width storage, and mature implementations without embedding time or node identity.

## Decision

`RepositoryId` stores exactly 16 bytes containing an RFC 9562 UUIDv4 with the RFC variant. New IDs use `uuid` crate generation. Binary construction validates the version and variant. Text parsing accepts only the 36-byte lowercase hyphenated form; formatting emits that form.

The public type is opaque and distinct from all content IDs. `Debug` redacts the value under the observability policy. `Display` deliberately reveals the canonical value for explicit persistence and inspection paths and must not be used in tracing fields.

## Consequences

Repositories can be identified without coordination and use standard UUID tooling. Random UUIDs do not provide chronological ordering. Collisions remain probabilistically possible, so an existing identity must never be silently overwritten. The `uuid` crate becomes a core dependency.

## Invariants

- Every constructed `RepositoryId` has UUID version 4 and the RFC variant bits.
- Repository identity is independent of Git object and Yeokcham content identities.
- One canonical textual representation maps to one 16-byte value.
- Default diagnostic formatting does not expose repository identity.

## Compatibility and migration

This defines the repository ID primitive before a repository format exists. Persistent formats must store its 16-byte representation and declare their own enclosing format version. No migration is required.

## Security and recovery

Repository IDs are metadata, not secrets, authentication tokens, encryption keys, or proof of ownership. UUIDv4 generation depends on the platform randomness used by the `uuid` crate. Recovery reads the stored identity and validates its bits; it does not regenerate an ID for an existing repository.

## Verification

Unit tests validate generated version and variant bits, canonical text and byte round trips, malformed input, noncanonical text, unsupported version and variant values, and redacted `Debug` output. CI checks the dependency and tests on the MSRV and stable Rust.
