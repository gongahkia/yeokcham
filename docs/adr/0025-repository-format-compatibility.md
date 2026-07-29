# ADR-0025: Version repository formats with required and optional flags

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Every persistent Yeokcham record needs a format version, feature flags, and a clear reader-compatibility outcome. Readers must reject unsupported mandatory features instead of silently misinterpreting data. No optional repository feature is implemented yet, but the first repository format must reserve a forward-compatible mechanism before persistent files are created.

## Decision drivers

- A reader must fail closed on an unknown mandatory semantic.
- A reader must preserve unknown ignorable metadata through read-modify-write paths.
- Initial repository creation needs a single unambiguous compatibility declaration.
- Persistent numeric values must remain bounded and straightforward to encode later.
- Feature allocation must not claim support before a capability exists.

## Considered options

### Version number only

This makes every additive optional capability require a format-version migration and prevents forward-compatible metadata.

### One undifferentiated flag set

This either rejects harmless future metadata or risks silently accepting data whose semantics are mandatory.

### Version with required and optional flag sets

This allows readers to reject unknown mandatory bits while retaining optional bits that they do not interpret.

## Decision

The initial persistent repository format is version 1. `RepositoryFormat` combines a validated `RepositoryFormatVersion` and `RepositoryFeatureFlags`, represented by bounded `u16` and two `u64` bit sets. Version 1 defines no feature bits.

`required` bits change interpretation or correctness and are rejected unless the reader explicitly supports every bit. `optional` bits are retained exactly, including unknown bits, but must not affect correctness when ignored. Writers must never place a mandatory semantic in the optional set. A format declaration with version 1 and no bits is the initial repository format.

## Consequences

Initial repository creation has one explicit compatibility declaration. Future features can be allocated without changing the core type, but each new bit requires an ADR, reader/writer implementation, fixtures, and migration implications. Readers may open records containing unknown optional bits, but must preserve those bits on rewrite.

## Invariants

- Unknown required feature bits always fail with `Unsupported`.
- Unknown optional bits are never discarded by the feature-flag type.
- No known required or optional feature bit exists until its capability is implemented.
- A repository format declaration always has a supported version and validated required flags.

## Compatibility and migration

This introduces version 1 before any repository record exists. The following serialization-policy decision must specify field order, byte order, canonical encoding, and per-record inclusion of version and flags. Incompatible changes use a new format version or a new required feature bit with copy-on-write, resumable, verifiable migration; the only valid prior generation remains until finalisation.

## Security and recovery

Failing closed on unknown required semantics prevents readers from trusting bytes they cannot interpret. Preserving optional bits prevents an older recovery tool from silently erasing forward-compatible metadata. Version and feature bits are structural metadata and contain no source or key material.

## Verification

Unit tests cover the initial declaration, unsupported versions, unknown required-bit rejection, unknown optional-bit preservation, propagated failures, and Send/Sync. CI checks the types on the MSRV and stable Rust.
