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

The naming key is an in-memory, zeroizing capability. The provider receives only the opaque name. The mapping has no SQLite lookup, plaintext fallback, or configurable algorithm.

Each Drive file begins with a version-1 `YKDO` capsule: magic, version, logical-key length, fresh 192-bit nonce, and XChaCha20-Poly1305 ciphertext of the logical backend key. The capsule's associated data is the opaque Drive file name. Its encryption key is separately HKDF-SHA-256-derived from the naming key using `yeokcham/drive-object-capsule/v1`. The capsule permits bounded paginated listing to recover logical keys without disclosing them to Drive. The payload after the capsule is exact physical-backend bytes and must be supplied by `EncryptedBackend` for repository data.

## Consequences

The same repository key and logical backend key produce the same opaque Drive name. [Inference] Different keys have a cryptographically negligible collision probability under HKDF-SHA-256. Different repository master keys produce unrelated names. The provider still observes object equality, count, timing, and ciphertext sizes. Existing Drive paths need no migration because no Drive backend records have been published yet.

Drive permits duplicate file names and offers no atomic create-if-absent primitive. Yeokcham queries before upload, confirms after finalization, and fails closed on unexplained duplicates. If that confirmation identifies the just-created file alongside one existing file, it deletes only the identified new duplicate and reports `AlreadyExists`; it never overwrites an existing file. A resumable session is private until its final range is accepted. The implementation retries bounded read/list/delete requests for rate-limit and transient-service responses but does not blindly replay session creation.

## Security and recovery

The mapping and capsule key are domain-separated from segment, metadata, and backend-object encryption subkeys. Losing the repository key makes both object ciphertext and opaque name derivation unavailable, consistent with the existing recovery model. Names and derived keys redact through `Debug`. The backend rejects standalone `chunks/` keys: chunks remain packed into immutable segments, so Drive does not receive one file per chunk.

## Verification

Unit tests prove deterministic fixed-length hexadecimal output, distinct names for distinct backend keys, capsule authentication, bounded paginated listing parsing, rate-limit retry, no token/key logging, interrupted-session rejection, resumable range publication, and duplicate-race cleanup. Full workspace CI and fuzz smoke run before acceptance.
