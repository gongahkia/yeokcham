# ADR-0066: Export and import repository keys with Argon2id

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

`RepositoryEncryptionKey` is intentionally in-process and does not persist the master key. Recovery requires a portable, integrity-checked representation that can survive a clean-machine installation while avoiding plaintext master-key export by default.

## Decision drivers

- Require an explicit nonempty passphrase for every export.
- Encode the repository identity and KDF inputs canonically.
- Authenticate KDF parameters, salt, nonce, and encrypted master key together.
- Reject unsupported work factors before Argon2 allocates memory.
- Keep exported bytes and key values redacted by default.

## Considered options

### Option 1: canonical Argon2id plus XChaCha20-Poly1305 export

Record the fixed selected Argon2id parameters, fresh salt/nonce, repository UUID, and AEAD ciphertext in one `YKRK` record.

### Option 2: plaintext recovery key with operator warning

Allow a minimal raw 32-byte export. This has a smaller implementation but exposes the repository root key to accidental copies and shell history.

### Option 3: store the key in the backend automatically

Upload a wrapped key alongside data. This needs a user-key distribution and authorization model not yet designed, and it does not replace an offline recovery copy.

## Decision

Use Option 1. `RepositoryEncryptionKey::export_with_passphrase` requires a nonempty passphrase up to 1,024 bytes, creates a fresh 16-byte salt and 24-byte nonce from `getrandom`, derives a 32-byte wrapping key with Argon2id v0x13 `m=65536 KiB`, `t=3`, `p=4`, and encrypts the 32-byte master key using XChaCha20-Poly1305. `import_with_passphrase` parses and bounds the export, rejects any format, algorithm, ciphertext length, or KDF parameters other than version 1 before deriving, then authenticates and restores the exact key.

`YKRK` version 1 fields are magic `YKRK`, `u16` version `1`, one-byte KDF algorithm `1`, one-byte AEAD algorithm `1`, raw repository UUIDv4, `u32` Argon memory KiB, iterations, and lanes, raw 16-byte salt, raw 24-byte nonce, and a 48-byte AEAD ciphertext as a canonical byte string. Associated data is every cleartext field before the ciphertext. `RepositoryKeyExport` accepts or returns exact bytes but redacts `Debug`.

## Consequences

Export and import require an Argon2 allocation of 64 MiB and deliberate passphrase input. The core does not write the export, prompt for a passphrase, place it in an operating-system keychain, or emit it in logs; callers select storage. A wrong passphrase and ciphertext/header tampering both produce the same redacted `corrupt_data` authentication failure.

The export carries only repository UUID and encrypted master key. It is not a repository snapshot, backend credential, device authorization, key rotation format, or automatic recovery mechanism. A full clean-machine repository recovery still needs encrypted repository data to be published through the backend abstraction.

## Invariants

- An export never contains the raw 32-byte master key as a direct field.
- KDF parameters are parsed and matched before Argon2 runs.
- The export's repository UUID, KDF algorithm/parameters, salt, and nonce are authenticated associated data.
- Import returns a key only after AEAD authentication and exact 32-byte plaintext validation.
- Export bytes, master keys, wrapping keys, passphrases, salt, and nonce have redacted default diagnostics.

## Compatibility and migration

`YKRK` is an independent recovery format. It does not alter existing local repository, backend envelope, Git, or ref-event formats. Future KDF work factors or cryptographic suites require a new export version/algorithm tag and a reader migration; version 1 values cannot be silently downgraded or tuned at import.

## Security and recovery

The output remains sensitive recovery material even though its master key is encrypted. Passphrase bytes are caller-owned and cannot be erased by the core; derived wrapping keys and export buffers use `zeroize` where ownership permits. The design does not provide a lost-passphrase recovery path. Operators need an offline copy of both the export and its passphrase through their own recovery process.

## Verification

Tests prove export/import key equivalence through derived segment keys, rejection of wrong passphrases, tampered ciphertext, and empty passphrases, no raw master-key window in the encoded export, redacted export diagnostics, and thread safety. Full workspace CI, rustdoc with warnings denied, and fuzz smoke run before acceptance.
