# ADR-0064: Select the initial versioned encryption suite

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Milestone 4 needs a recoverable encrypted backend format, a repository master key, domain-separated subkeys, and passphrase-protected key exports. The design must use maintained implementations rather than construct encryption or password derivation from hashes directly. Existing V1/V2 local repository records remain plaintext and cannot be silently reinterpreted as encrypted bytes.

## Decision drivers

- Authenticate ciphertext and its repository-specific context.
- Make random nonce generation and key derivation explicit.
- Support a versioned, portable passphrase-protected recovery export.
- Keep secret material redacted and zeroized on drop where practical.
- Preserve the workspace Rust 1.85 MSRV.

## Considered options

### Option 1: XChaCha20-Poly1305, HKDF-SHA-256, and Argon2id

Use RustCrypto implementations with explicit domain labels, random 24-byte AEAD nonces, a random 16-byte Argon2id salt, and serialized fixed KDF parameters.

### Option 2: AES-GCM plus PBKDF2

Use an alternative standard AEAD and a broadly deployed password KDF. This does not match the project security design's memory-hard passphrase wrapping and would introduce nonce-management constraints without an existing hardware-acceleration policy.

### Option 3: encrypt each record with the repository master key directly

Avoid a key hierarchy. This binds unrelated formats to one long-lived key and makes domain separation or future key rotation harder to audit.

## Decision

Use the following exact initial suite:

- `chacha20poly1305 = 0.11.0` `XChaCha20Poly1305` for AEAD encryption and authentication, with a unique fresh 24-byte nonce from `getrandom = 0.4.3` for every envelope.
- `hkdf = 0.13.0` over `sha2 = 0.11.0` SHA-256 for 32-byte subkeys. HKDF salt is the repository UUID. Information is canonical ASCII: `yeokcham/<purpose>/v1\0` followed by any fixed-width object identity required by that purpose.
- `argon2 = 0.5.3` Argon2id version 0x13 for passphrase wrapping. Recovery exports record Argon2id `m=65536` KiB, `t=3`, `p=4`, a fresh 16-byte salt, and a 32-byte derived wrapping key. These are RFC 9106's second recommended parameters for memory-constrained environments.
- `zeroize = 1.9.0` for master keys, derived keys, passphrases, and temporary plaintext buffers where API ownership permits.

The initial master key is 32 random bytes. It remains a root secret and is never used directly for AEAD. Distinct segment, metadata, backend-object, and export-wrapping keys use distinct HKDF purpose labels. Envelopes carry a magic, schema version, nonce, plaintext length, and ciphertext with its 16-byte Poly1305 tag; callers supply the external backend-key routing identity. Associated data canonically binds the envelope version, repository UUID, purpose, object identity, and declared plaintext length. A wrong key, modified cleartext header, nonce, ciphertext, tag, or associated-data binding returns `corrupt_data` without plaintext.

## Consequences

The selected RustCrypto crates meet the workspace MSRV at their pinned versions. XChaCha20-Poly1305 exposes detached and in-place authenticated operations and zeroization support. The `getrandom` API fills a requested buffer from the operating system source and reports failures rather than allowing a fallback. HKDF supports a salt plus an `info` context for derived key material. Argon2's key-derivation API accepts a passphrase, salt, and fixed-size output buffer.

Passphrase export/import can allocate up to the recorded Argon2 memory cost. Readers must bound every serialized field and reject unsupported parameters before allocating or deriving a key. The no-passphrase export mode is not implemented: recovery exports are encrypted and require an explicit nonempty passphrase. Key rotation, device authorization, alternate cryptographic suites, and legacy plaintext migration are separate format work.

## Invariants

- Each envelope nonce comes from the system random source and is written with its ciphertext exactly once.
- AEAD associated data includes the repository UUID, purpose, object identity, version, and plaintext length.
- Domain-separated subkeys are distinct by their exact HKDF information fields.
- Recovery export KDF parameters are encoded and verified before passphrase derivation.
- Default diagnostics and `Debug` do not disclose keys, passphrases, nonces, plaintext, or opaque object identities.

## Compatibility and migration

This decision introduces a new encryption-envelope family and recovery-export family, each with schema version 1. Existing local V1/V2 repository format bytes are unchanged. Any change to the suite, labels, associated-data layout, or KDF parameters requires a new envelope/export version and a migration reader; it cannot reinterpret version-1 ciphertext.

## Security and recovery

AEAD authentication is mandatory before decompression, parsing, or Git-ID verification. The encryption layer hides plaintext bytes but does not hide ciphertext size, upload timing, or backend account metadata. A passphrase and exported key bundle are both recovery material; losing them is not recoverable from ciphertext alone. Zeroization reduces residual in-process secret lifetime but cannot erase copies owned by callers, operating-system caches, or previous allocations.

## Verification

Tests will use known deterministic test vectors where the nonce and key are supplied, plus system-random generation checks, wrong-key and tamper rejection, domain-separation checks, export/import round trips, redacted diagnostics, encrypted-filesystem plaintext scans, and clean-machine-style recovery from exported material. The primitive and parameter choices were checked against the RustCrypto documentation, RFC 9106, `getrandom`, and `zeroize` documentation.
