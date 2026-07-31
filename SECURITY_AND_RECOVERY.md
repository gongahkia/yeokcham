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

Current local `YKRE` V1 ref events use SHA-256 checksums and predecessor-state binding to detect corruption, stale transitions, and divergence. V2 records additionally carry an Ed25519 public key and detached signature over their canonical transition fields; decoding verifies that signature before materialization. The remote multi-device core adds immutable root-signed `YKDR` device-registry records. The caller pins the registry root public key out of band; the backend never establishes trust. A device registration binds one device UUID to one verifying key. A root revocation commits the final accepted `(sequence, event ID)` for that device, so reconciliation accepts only the checked chain prefix and rejects later delayed or pre-signed entries. Registry mutation races and journal divergence fail closed and remain visible to the caller. The root signing secret remains caller-managed and is not persisted by Yeokcham. `sync` and the remote helper remain V1 single-trusted-local-writer workflows until their Drive command surface owns explicit device-key and root-anchor handling.

Do not invent cryptography.

The current local remote-helper pack cache contains conventional plaintext Git objects under `<store>/cache/packs/`. It is neither canonical repository data nor an encrypted backend format. The helper verifies the canonical store before cache use and validates each matching cache entry with exact refs plus `git fsck --full --strict`; a missing or invalid entry is rebuilt. Every hit or publication writes a local last-used timestamp containing no repository content. `yeokcham cache inspect <repo>` bounds directory traversal and reports only counts and bytes. `yeokcham cache verify <repo>` verifies canonical storage, validates cache entry names against their refs, and runs strict Git fsck with output suppressed. `yeokcham cache trim --max-bytes <bytes> <repo>` removes least-recently-used snapshots only when explicitly invoked, so it is not run concurrently with helper serving. `yeokcham cache clear <repo>` reopens the canonical bootstrap, refuses a symlink or non-directory cache path, and removes only `<repo>/cache`. Cache deletion or corruption must never be a recovery dependency.

`yeokcham-server` V1 is a read-only native HTTP service, not Git smart HTTP. It serves an authenticated HTML repository/ref/commit/tree metadata browser, verified ref metadata, and exact Git object bodies only through loopback TCP. Commit/tree pages reconstruct and verify the selected object, validate their bounded binary/text structure, escape or hexadecimal-encode dynamic labels, cap rendered parents, entries, and previews, and never render blobs. Its parser accepts one ASCII `GET` request without a body per connection, limits headers to 8 KiB, response bodies to 64 MiB, I/O phases to five seconds, active workers to four, and queued sockets to eight. The CLI and server API reject every non-loopback address, so V1 cannot accidentally bind `0.0.0.0` or a LAN interface. Every endpoint requires one exact 256-bit token from a regular non-symlinked file with no group or other permission bits; `token create` writes such a create-new mode-0600 file using OS randomness and prints no token. Native clients use Bearer; browser Basic uses username `yeokcham` and the same token. Basic is Base64 encoding rather than encryption, so it is permitted only because non-loopback binds, proxies, tunnels, and port forwarding remain prohibited. The server stores and parses token buffers with zeroization and uses constant-time equality. Loopback plus this token reduces same-host exposure, but a process that can read the token file, process memory, or a compromised account can still read served objects. TLS termination, non-loopback deployment, token reload, per-client revocation, and sessions remain unavailable. Default errors and logs omit repository paths, storage details, raw source bytes, and credentials; only the documented authenticated native raw-object endpoint returns an exact object body. Server termination cannot mutate canonical data. The wire contract is [`docs/native-http-v1.md`](docs/native-http-v1.md).

The core `CiphertextCache` stores only full `segments/` and `indexes/` reads when positioned beneath `EncryptedBackend`. Its opaque filename is SHA-256 of the backend key; each record contains a checksum and length. A malformed, truncated, oversized, or symlinked entry is discarded as a cache miss and the immutable backend remains authoritative. The cache never serves range reads, manifests, refs, or plaintext data.

`LocalRepository` may retain decrypted chunk bytes and reconstructed Git-object bodies only in its process memory. Each cache is independently bounded to 32 MiB and 1,024 entries with LRU eviction; oversized entries are not retained. A chunk entry binds its complete reference and an object entry its complete canonical manifest. A cache hit is reconstructed and identity-verified before use. Invalid entries are discarded and resolved again from immutable storage. This plaintext is never written to a cache file, so process exit, repository-handle drop, cache deletion, and clean-machine recovery do not depend on it.

`FilesystemBackend` is a bounded local object-store implementation and stores the bytes supplied by its caller. `EncryptedBackend` wraps it with versioned XChaCha20-Poly1305 envelopes; the raw filesystem contains ciphertext rather than wrapped object bytes. The wrapper binds repository and object context before decryption, rejects wrong keys and authentication failures, and redacts key material by default. `DriveBackend` is a physical backend: it requires an `EncryptedBackend` wrapper for repository payload confidentiality, uses a repository-key-derived opaque file name, and prefixes each file with an authenticated encrypted logical-key capsule. It validates that capsule before reads/listing, accepts only completed resumable files, and rejects standalone chunk keys. `LocalRepository::backup_to_backend` uses this encrypted boundary for its canonical recovery snapshot; full repository-to-Drive synchronization remains later work.

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

GitHub publication uses no Yeokcham credential API. `github publish --apply --transport https` delegates authentication to the operator's standard preconfigured Git credential helper; `--transport ssh` delegates to the standard SSH agent. The command never persists, prints, or traces a GitHub token. It removes inherited Git configuration, askpass, and SSH-command override variables, leaves default Git configuration and `SSH_AUTH_SOCK` available, and disables terminal prompting. A helper or agent must therefore already be configured. The canonical `mirrors/github.ykgm` record contains only selected-ref policy, target metadata, and checkpoints; it is checksummed, repository-ID-bound, bounded, atomically replaced, and included only through encrypted recovery snapshots. Local filesystem access exposes that configuration metadata. Configuration and inspection output omit target and ref names by default.

`github fetch` uses the same credential boundary. It lists and fetches only bounded selected standard refs into a temporary bare Git repository, verifies fetched IDs against the preflight remote listing, imports verified immutable objects, and removes that repository. It does not print ref metadata without `--show-refs`, mutate canonical Git refs, or silently choose a divergence. The temporary bare repository contains ordinary Git objects while it exists and is not canonical or recoverable data; an interrupted process can leave it under the operating system temporary directory for operator cleanup.

`github resolve --apply` is the only GitHub ingestion command that mutates canonical refs. It requires an explicitly supplied selected local-to-remote mapping, fresh remote read/fetch verification, and an expected-state checked journal append. A concurrent local mutation fails without replacing a ref. The final checkpoint write occurs after the durable event; a filesystem failure can leave a valid accepted ref transition with a stale checkpoint, which a retry must repair rather than conceal.

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

The local upload-pack bridge enables C Git filtering only with command-scoped configuration on the helper-created verified snapshot. `uploadpack.allowFilter` allows standard `blob:none` and `blob:limit` requests; `uploadpack.allowReachableSHA1InWant` permits later hydration only for objects reachable from advertised refs. It does not enable arbitrary object-ID wants. Filtered packs are marked promisor by C Git and a later hydration reconnects through the same helper. The canonical Yeokcham store remains complete and verified before this disposable bridge is entered.

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
