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

The final choice must be documented in an ADR and reviewed before declaring a stable format.

Current local `YKRE` V1 ref events use SHA-256 checksums and predecessor-state binding to detect corruption, stale transitions, and divergence. They do not authenticate a writer; only one trusted local sync writer is supported until the planned Ed25519 device-authorisation design exists.

Do not invent cryptography.

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

Key exports should be:

- Explicit.
- Encrypted or clearly marked as sensitive.
- Versioned.
- Integrity-checked.
- Test-restored during release validation.

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
