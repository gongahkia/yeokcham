# ADR-0023: Represent device IDs as UUIDv4 bytes

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Ref journal events bind a device identity, sequence number, signer identity, and authorisation state. The security model treats a device identifier, signing key pair, repository-owner authorisation, and revocation state as separate concepts. Binding the ID directly to a signing key would prevent independent key lifecycle and revocation records.

## Decision drivers

- Device identity must remain stable across signing-key lifecycle operations.
- IDs must not expose public-key bytes, host data, paths, or timestamps.
- The binary form must be fixed-width and broadly interoperable.
- Authorisation and revocation must be independently verifiable.
- Generation and parsing must use a maintained implementation compatible with the project MSRV.

## Considered options

### Public-key-derived identifier

This makes the ID depend on signing-key lifecycle and exposes a stable public-key correlation value as metadata.

### Host-derived identifier

Host names and hardware values are mutable, privacy-sensitive, and unsuitable for portable recovery.

### UUIDv4

UUIDv4 provides a standard 128-bit layout, offline random generation, fixed-width storage, and mature implementations without embedding time, host, or key data.

## Decision

`DeviceId` stores exactly 16 bytes containing an RFC 9562 UUIDv4 with the RFC variant. Devices generate their ID independently from signing-key generation. Binary construction validates the version and variant. Text parsing accepts only the 36-byte lowercase hyphenated form; formatting emits that form.

The ID is opaque and distinct from a signer identity, public key, authorisation, and revocation state. `Debug` redacts the value under the observability policy. `Display` deliberately reveals the canonical value for explicit persistence and inspection paths and must not be used in tracing fields.

## Consequences

Device identities remain stable through future signing-key rotation or replacement, while authorisation records bind the current key explicitly. Random IDs do not provide chronological ordering. A duplicate device ID must be handled as a conflict and never silently merged with another device's identity.

## Invariants

- Every constructed `DeviceId` has UUID version 4 and the RFC variant bits.
- Device identity is independent from signer and authorisation identity.
- Ref events bind both device ID and signer identity before trust.
- Default diagnostic formatting does not expose device identity.

## Compatibility and migration

This defines the device ID primitive before a device-authorisation format exists. Persistent formats must store its 16-byte representation and declare their own enclosing format version. No migration is required.

## Security and recovery

Device IDs are metadata, not secrets, signing keys, authorisation proofs, or proof of ownership. UUIDv4 generation depends on the platform randomness used by the `uuid` crate. Recovery restores the recorded device ID, verifies its authorisation and signatures, and never regenerates an ID for an existing device.

## Verification

Unit tests validate generated version and variant bits, canonical text and byte round trips, malformed input, noncanonical text, unsupported version and variant values, and redacted `Debug` output. CI checks the dependency and tests on the MSRV and stable Rust.
