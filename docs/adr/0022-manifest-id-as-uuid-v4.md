# ADR-0022: Represent manifest IDs as UUIDv4 bytes

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

A manifest describes one immutable representation of a Git object and is persisted after its referenced immutable segments. The same Git object may have distinct valid representations as storage policy evolves. Manifest correctness is established by validating its ordered record references, content identity, and original Git object ID; no canonical manifest encoding exists yet from which to derive a content-addressed name.

## Decision drivers

- A representation record needs an opaque stable identity independent of Git object identity.
- IDs must not expose source content, paths, host data, policy, or timestamps.
- The binary form must be fixed-width and broadly interoperable.
- Integrity verification must remain independent of object naming.
- Generation and parsing must use a maintained implementation compatible with the project MSRV.

## Considered options

### Git object ID

This cannot distinguish two valid representation manifests for the same Git object and exposes a Git compatibility identifier as remote metadata.

### Canonical manifest hash

This could provide content addressing but requires a settled canonical manifest encoding and exposes equality. Neither exists before the serialization-policy decision.

### UUIDv4

UUIDv4 provides a standard 128-bit layout, offline random generation, fixed-width storage, and mature implementations without embedding time or host identity.

## Decision

`ManifestId` stores exactly 16 bytes containing an RFC 9562 UUIDv4 with the RFC variant. New manifests generate their ID before persistence. Binary construction validates the version and variant. Text parsing accepts only the 36-byte lowercase hyphenated form; formatting emits that form.

The ID is opaque and distinct from Git object, content, segment, and integrity identities. `Debug` redacts the value under the observability policy. `Display` deliberately reveals the canonical value for explicit persistence and inspection paths and must not be used in tracing fields.

## Consequences

Multiple immutable representations of one Git object can coexist without identifier conflict. Random IDs do not deduplicate equal manifest bytes or provide chronological ordering. A pre-existing remote object under the same ID must be verified as identical or treated as a conflict; it must never be overwritten.

## Invariants

- Every constructed `ManifestId` has UUID version 4 and the RFC variant bits.
- Manifest identity is independent of its Git object and content identities.
- Manifest validation verifies representation references and reconstructed Git bytes separately from the ID.
- Default diagnostic formatting does not expose manifest identity.

## Compatibility and migration

This defines the manifest ID primitive before a manifest format exists. Persistent formats must store its 16-byte representation and declare their own enclosing format version. No migration is required.

## Security and recovery

Manifest IDs are metadata, not secrets, encryption keys, integrity proofs, or proof of ownership. UUIDv4 generation depends on the platform randomness used by the `uuid` crate. Recovery validates the stored ID, manifest structure, record identities, and reconstructed Git object ID independently; it never regenerates an ID for an existing manifest.

## Verification

Unit tests validate generated version and variant bits, canonical text and byte round trips, malformed input, noncanonical text, unsupported version and variant values, and redacted `Debug` output. CI checks the dependency and tests on the MSRV and stable Rust.
