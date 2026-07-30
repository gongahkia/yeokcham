# ADR-0067: Recover canonical repository files from encrypted backend storage

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Encrypted backend envelopes and recovery-key exports existed independently. Milestone 4 requires proof that canonical repository data can be recovered to a fresh machine from authenticated backend records and imported key material, without SQLite, a cache, or a hosted Yeokcham service.

## Decision drivers

- Require the encryption wrapper at the repository backup API boundary.
- Publish immutable recovery files before the manifest that acknowledges them.
- Bound source traversal, individual files, cumulative bytes, and manifest bytes.
- Revalidate every recovered file before writing it into a fresh repository layout.
- Keep SQLite coordination data and caches out of recovery evidence.

## Considered options

### Option 1: encrypted canonical-file snapshot plus manifest

Upload every regular canonical repository file as an immutable encrypted backend object and publish a checksum manifest last. Restore from that manifest into a fresh layout.

### Option 2: encrypted SQLite backup

Treat the local metadata database as recovery authority. This conflicts with the existing disposable-SQLite invariant and omits canonical records.

### Option 3: export Git then encrypt the Git repository

Use a temporary Git export as the recovery representation. This loses Yeokcham's native append-only records and requires an import step before normal recovery.

## Decision

Use Option 1. `LocalRepository::backup_to_backend` takes only `EncryptedBackend<B>`, validates its local layout/bootstrap, recursively collects bounded regular files except `metadata.sqlite3` and recognized interrupted staging files, and publishes them as `recovery/<repository-uuid>/files/<relative-key>`. Every other source name must be a currently canonical repository filename. A canonical `YKRM` version-1 manifest sorts file keys and records each exact plaintext length and SHA-256 checksum. It is published only after all files return `Created` or exact-byte `AlreadyExists`; a different existing file or manifest returns `conflict`.

`restore_from_backend` takes the expected repository UUID from imported recovery material, fetches/decrypts `recovery/<repository-uuid>/manifest`, bounds/parses `YKRM`, creates a fresh required layout, fetches/decrypts every listed file, verifies length and SHA-256 before create-new local publication, then opens the repository through normal bootstrap validation. The caller must explicitly clean up a destination left by a failed restore. Existing local SQLite metadata is excluded because canonical manifest/segment resolution remains sufficient for verification and Git export.

## Consequences

Recovery snapshots currently leave backend path names, repository UUID, per-file ciphertext size, timing, and number of files visible. The encrypted contents and recovery manifest itself are protected by `EncryptedBackend`. Snapshot publication is create-only, so an already-published manifest represents one exact immutable repository state; a later state needs a future generation/discovery design rather than replacement.

The current snapshot wrapper copies whole files into bounded memory and encrypted backend envelopes reject caller-managed range/resumable requests. It is correctness-first recovery, not a benchmarked transfer or incremental synchronization design. The Drive physical backend now performs resumable transport beneath complete-object encryption, derives opaque paths, and supports recovery CLI backup, restore, and verification. Direct remote-helper clone/fetch, generations, garbage collection, and multi-device journal reconciliation remain later work.

## Invariants

- Repository backup APIs cannot accept an unencrypted backend type.
- A `YKRM` manifest names only bounded, strictly ordered canonical relative files and excludes SQLite metadata and interrupted staging files.
- Every restored file matches both manifest length and SHA-256 before local create-new write.
- The restored bootstrap UUID must equal the UUID used to discover the manifest.
- Recovery does not trust encrypted backend header metadata or cache contents as canonical evidence.

## Compatibility and migration

`YKRM` is a new independent encrypted recovery manifest family. It changes no existing local record encoding. Existing repository roots may be backed up without migration. Future generation pointers, opaque paths, record streaming, or new checksums require a new manifest version or an additional versioned discovery record.

## Security and recovery

Authentication in `EncryptedBackend` precedes access to manifest and file plaintext. The manifest's SHA-256 checks accidental corruption and binds exact source files, while existing segment, manifest, checksum, signature, and Git-ID checks remain necessary after restoration. A malicious backend without the key cannot substitute accepted records; a key holder can create valid data and remains inside the repository trust boundary. Incomplete local restores are not automatically deleted to avoid destructive cleanup of an operator-selected path.

## Verification

One integration test imports a real Git repository, generates and exports a repository key, publishes an encrypted canonical recovery snapshot, imports that key into a fresh backend wrapper, restores to a new path, runs Yeokcham verification, exports a new bare Git repository, and passes `git fsck --full`. Unit tests also cover ciphertext-only files, wrong keys, tampering, export authentication, and Drive opaque resumable publication. Full workspace CI, rustdoc with warnings denied, and fuzz smoke run before acceptance.
