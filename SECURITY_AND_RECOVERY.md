# Security and Recovery

## 1. Security objectives

Yeokcham should protect:

- Source and binary content.
- Commit messages.
- Paths and ref names where metadata encryption is enabled.
- Repository topology.
- Authentication credentials.
- Encryption keys.
- Ref integrity.
- Recovery material.

Yeokcham should not claim to hide:

- That a user communicates with Google Drive or GitHub.
- Approximate upload timing and total encrypted object size.
- Source code published intentionally to GitHub.
- Local plaintext from a compromised host.

## 2. Threat model

### In scope

- Curious or compromised cloud storage backend.
- Accidental remote corruption.
- Truncated or replayed uploads.
- Stale or malicious indexes.
- Lost local cache.
- Interrupted write.
- Two devices updating refs independently.
- Malicious Git pack input.
- Malicious repository metadata.
- Compromised mirror state causing unwanted ref movement.
- Operator mistakes.

### Initially out of scope

- A fully compromised local operating system.
- Hardware side-channel attacks.
- Multi-user hostile tenants.
- Anonymous traffic analysis resistance.
- Protecting code intentionally uploaded to GitHub from GitHub.
- Cross-user deduplication.

## 3. Cryptographic design constraints

Use established, audited primitives through maintained libraries.

A reasonable initial design:

- Repository master key generated from a cryptographically secure RNG.
- Optional passphrase wrapping using Argon2id with recorded parameters and random salt.
- Key hierarchy derived with HKDF-SHA-256.
- Record encryption using XChaCha20-Poly1305 or another standard authenticated-encryption construction supported by a mature crate.
- Ed25519 signatures for device ref journal entries.
- Cryptographic hashes for plaintext identities and segment integrity.

ADR-0064 selects the initial suite and versioned parameters. A new format version is required to change any primitive, KDF parameter, nonce size, associated-data field, or domain-separation label.

Current local `YKRE` V1 ref events use SHA-256 checksums and predecessor-state binding to detect corruption, stale transitions, and divergence. V2 records additionally carry an Ed25519 public key and detached signature over their canonical transition fields; decoding verifies that signature before materialization. A valid V2 signature proves possession of its embedded key only: Yeokcham has no persistent key storage, device-key registration, authorization policy, or revocation yet. `sync` and the remote helper therefore remain V1 single-trusted-local-writer workflows.

Do not invent cryptography.

The current local remote-helper pack cache contains conventional plaintext Git objects under `<store>/cache/packs/`. It is neither canonical repository data nor an encrypted backend format. The helper verifies the canonical store before cache use and validates each matching cache entry with exact refs plus `git fsck --full --strict`; a missing or invalid entry is rebuilt. Cache deletion or corruption must never be a recovery dependency.

`FilesystemBackend` is a bounded local object-store implementation and stores the bytes supplied by its caller. `EncryptedBackend` wraps it with versioned XChaCha20-Poly1305 envelopes; the raw filesystem contains ciphertext rather than wrapped object bytes. The wrapper binds repository and object context before decryption, rejects wrong keys and authentication failures, and redacts key material by default. `LocalRepository::backup_to_backend` uses this encrypted boundary for its canonical recovery snapshot, while backend paths remain cleartext and remote-provider synchronization is still later work.

`MetricsBackend` keeps only operation counts and aggregate byte counts in process; it stores no keys, sessions, object bytes, or error sources. These counters can still reveal activity volume, so callers must not emit them in default logs without an explicit telemetry policy. `FaultInjectingBackend` exposes only a configured failure position and operation count through its API; it retains no backend data.

## 4. Key hierarchy

Conceptual hierarchy:

```text
User recovery secret
  -> wraps repository master key

Repository master key
  -> metadata encryption key
  -> segment encryption key generation
  -> filename/key-obfuscation key
  -> device authorisation key material
```

A device should have:

- A device identifier.
- A signing key pair.
- Authorisation signed by the repository owner.
- Revocation state.

## 5. Key backup

Commands should include:

```bash
yeokcham keys export --repository <repo> --output recovery.yeokcham-key
yeokcham keys verify recovery.yeokcham-key
yeokcham keys import recovery.yeokcham-key
yeokcham keys rotate
yeokcham device list
yeokcham device revoke <device-id>
```

The current core API provides `RepositoryEncryptionKey::export_with_passphrase` and `import_with_passphrase`; CLI key commands remain pending. Key exports are:

- Explicit and passphrase-encrypted.
- Versioned.
- Integrity-checked.
- Test-restored during release validation.

The caller must store an export through an explicit recovery workflow. The current key generator does not write master keys into the local repository layout, operating-system credential stores, or backend automatically.

Yeokcham must not promise that lost keys can be recovered from the backend.

## 6. Metadata privacy

Two modes may exist:

### Content encryption only

Opaque content records are encrypted, but some repository structure and object keys may be visible.

### Full metadata encryption

Paths, ref names, commit messages, manifests, indexes, and object mapping metadata are encrypted or keyed with opaque identifiers.

The default remote mode should prefer full metadata encryption unless it materially prevents required operations.

## 7. Remote authentication

Backend credentials must be stored using the operating system credential store where available.

Do not place OAuth refresh tokens in plaintext repository configuration.

Drive uses a user-supplied Google Desktop OAuth client ID with the non-sensitive `https://www.googleapis.com/auth/drive.file` scope. Desktop authorization uses PKCE S256 and a `127.0.0.1` loopback callback with state verification; it does not embed an OAuth client secret or use deprecated copy/paste authorization. `yeokcham drive auth` intentionally prints the one-time authorization URL only to its interactive stdout and never emits it through tracing. A fixed `--redirect-port` permits SSH forwarding for a headless host; it retains the same loopback, PKCE, and state checks. Authorization URLs, callback codes, access tokens, refresh tokens, and token endpoint responses must not appear in default logs.

The default `drive.file` scope covers only folders/files created or explicitly opened with the application. The Drive backend must create its dedicated visible root and must not infer access to an arbitrary pre-existing folder from a supplied ID. `drive.appdata` is unsuitable for canonical repository data because it is hidden and cannot share/move its files; broad Drive scope is not a default escape hatch.

`KeyringDriveCredentialStore` persists only the Drive refresh token in the OS credential store. It derives the credential account label from SHA-256 of the non-secret client ID and does not use a local-file fallback. Missing or inaccessible credential storage fails closed and requires explicit reauthorization.

An access token is renewed only by posting the stored refresh token and client ID to Google's fixed HTTPS token endpoint. The refresh response supplies a new in-memory Bearer token and lifetime; it does not replace a stored refresh token. Rejected or malformed refresh responses fail closed and require reauthorization rather than a plaintext credential fallback.

GitHub tokens should follow least privilege and repository-specific scope where possible.

## 8. Input validation

Treat all external bytes as hostile.

Required defences:

- Bounded allocations.
- Length validation before buffer allocation.
- Integer overflow checks.
- Path traversal rejection.
- Symlink and filesystem boundary checks.
- Pack delta depth limits.
- Decompression ratio limits.
- Chunk count limits.
- Manifest recursion limits.
- Signature and hash verification before trust.
- Timeouts and cancellation.

## 9. Ref integrity

A ref event must bind:

- Repository ID.
- Device ID.
- Sequence number.
- Previous event hash.
- Expected old values.
- New values.
- Timestamp or logical time.
- Signer identity.

Rejected or divergent events must remain inspectable rather than disappearing.

## 10. Recovery scenarios

### Scenario A — Local cache deleted

Expected behaviour:

- Rebootstrap from repository metadata.
- Download indexes and necessary segments.
- Reconstruct refs.
- Verify data.
- Resume lazily.

### Scenario B — Interrupted segment upload

Expected behaviour:

- Unsealed or partial uploads are ignored.
- Upload resumes or restarts.
- No ref event points to an unavailable segment.

### Scenario C — Missing remote segment

Expected behaviour:

- Verification identifies affected objects and refs.
- Yeokcham checks alternate mirrors or local caches.
- Repository remains read-only for affected operations.
- No reconstructed object is returned without complete verification.

### Scenario D — Divergent device pushes

Expected behaviour:

- Both device journal branches remain.
- Yeokcham reports divergence.
- User selects, merges, or publishes a resolution event.
- No last-writer-wins data loss.

The local remote-helper push bridge uses a deterministic repository-derived V1 journal writer only to serialize one trusted local service. It compares the staged predecessor against the canonical state before publication and fails closed on conflicts. The V2 signature foundation does not change this: unregistered signers are not authorized, and unsigned V1 events remain unsuitable for untrusted writers.

The local ref transaction has a test-only fault-injecting filesystem wrapper. It simulates abrupt termination after every bootstrap-upgrade and journal-publication mutation boundary, then reopens and verifies the repository. The tests accept only the complete prior or complete successor ref state; immutable records written before the journal may remain unreachable and are not an acknowledged ref update.

### Scenario E — Lost local machine

Expected behaviour:

- User installs Yeokcham elsewhere.
- Imports recovery key.
- Authenticates to backend.
- Rebuilds local metadata.
- Exports or clones repository.

### Scenario F — Yeokcham project discontinued

Expected behaviour:

- Published storage-format specification and open-source implementation remain sufficient.
- User can build the recovery binary.
- `yeokcham recover --export-git` reconstructs a conventional Git repository.

## 11. Backup policy

Yeokcham remote storage is not automatically a backup if:

- The same credentials can delete every generation.
- Encryption keys exist only on one device.
- Backend corruption is undetected.
- A malicious actor can replace journal state.

Recommended production guidance:

- At least two independent backends or one backend plus offline recovery bundle.
- Separate key backup.
- Periodic `yeokcham verify --full`.
- Periodic conventional Git export.
- Retention window before remote garbage collection.
- Optional immutable or versioned backend storage.

## 12. Security release gates

Before public beta:

- Pack and manifest parsers fuzzed.
- Dependency audit automated.
- Secrets excluded from logs.
- Key import/export tested on clean machines.
- Corruption fixtures included.
- Threat model reviewed.
- Cryptographic format documented.
- No unauthenticated network listener by default.
- All network binds default to loopback.
- Security contact and disclosure process published.
