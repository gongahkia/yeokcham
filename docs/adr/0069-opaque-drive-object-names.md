# ADR-0069: Derive opaque Drive object names from repository key material

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The generic backend contract uses readable logical keys such as `segments/<id>`. Google Drive file names and app properties are visible provider routing metadata and must not disclose Yeokcham record families, object identities, or ref structure.

## Decision

Derive one `DriveObjectNamingKey` from the repository master key using the existing repository-bound HKDF-SHA-256 hierarchy and the `drive-object-naming/v1` purpose. For every validated backend key, use this derived key as HKDF salt with the backend key as input and `yeokcham/drive-object-name/v1` as expand info. Encode the 32-byte output as a fixed 64-character lowercase hexadecimal `DriveObjectName`.

The naming key is an in-memory, zeroizing capability. The Drive client receives only the opaque name. The mapping has no SQLite lookup, plaintext fallback, or configurable algorithm.

## Consequences

The same repository key and logical backend key produce the same opaque Drive name. [Inference] Different keys have a cryptographically negligible collision probability under HKDF-SHA-256. Different repository master keys produce unrelated names. The provider still observes object equality, count, timing, and ciphertext sizes. Existing Drive paths need no migration because no Drive backend records have been published yet.

## Security and recovery

The mapping is domain-separated from segment, metadata, and backend-object encryption subkeys. Losing the repository key makes both object ciphertext and opaque name derivation unavailable, consistent with the existing recovery model. Names and derived keys redact through `Debug`.

## Verification

Unit tests prove deterministic fixed-length hexadecimal output, distinct names for distinct backend keys, absence of the logical key text, repository-bound derivation, and debug redaction. Full workspace CI and fuzz smoke run before acceptance.
