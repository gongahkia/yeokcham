# Architecture

## 1. System overview

yeokcham is organised around a compatibility boundary and an internal storage engine.

```text
Git CLI / IDE / CI
        |
        | Git remote-helper or smart HTTP
        v
Protocol Adapter
        |
        v
Repository Service
  |        |        |
  |        |        +--> Ref Transaction Manager
  |        +-----------> Pack Import / Pack Synthesis
  +--------------------> Object Resolver
                              |
                              v
                    yeokcham Object Database
                     |       |        |
                     |       |        +--> Local Cache
                     |       +----------> Chunk/Segment Store
                     +------------------> Metadata Store
                                              |
                                              v
                                      Backend Interface
                                      /       |       \
                                  Local     Drive    HTTP/S3-like
```

## 2. Proposed Rust workspace

```text
yeokcham/
  Cargo.toml
  crates/
    yeokcham-cli/
    yeokcham-remote-helper/
    yeokcham-core/
    yeokcham-git/
    yeokcham-store/
    yeokcham-chunking/
    yeokcham-segments/
    yeokcham-refs/
    yeokcham-crypto/
    yeokcham-backend/
    yeokcham-backend-local/
    yeokcham-backend-drive/
    yeokcham-cache/
    yeokcham-mirror/
    yeokcham-server/
    yeokcham-testkit/
    yeokcham-bench/
  docs/
  fixtures/
  scripts/
```

Keep crate boundaries coarse at first. Split only when interfaces are understood.

## 3. Core modules

### 3.1 Protocol adapter

Responsibilities:

- Parse remote-helper commands.
- Advertise capabilities.
- Translate fetch and push requests into repository-service operations.
- Stream packs without unnecessary full buffering.
- Map internal failures to useful Git-facing errors.

Initial strategy:

- Implement the minimum remote-helper protocol required for local clone/fetch.
- Prefer delegation to mature Git pack readers and writers.
- Add smart HTTP only after local end-to-end correctness.

Current local bridge: `git-remote-yeokcham` advertises only `connect`, accepts `connect git-upload-pack` and `connect git-receive-pack`, and verifies the effective local ref state before C Git sees it. Upload-pack uses a local bare snapshot-pack cache keyed by the SHA-256 identity of that complete state. A cache hit requires exact ref-state equality and `git fsck --full --strict`; cache corruption, partial publication, or an incorrect state is discarded and rebuilt from a verified export. C Git still performs every client-specific upload-pack negotiation, so the cache is not a protocol-response cache. The helper invokes only this disposable verified export with `uploadpack.allowFilter=true` and `uploadpack.allowReachableSHA1InWant=true`. C Git therefore advertises native filter support for `blob:none` and `blob:limit=<bytes>`, marks omitted objects as promisor objects, and reconnects through the helper to hydrate a missing reachable blob. It does not enable arbitrary object-ID wants or give Yeokcham's persistent store partial-object semantics. Receive-pack uses a private temporary export instead: it relays the initial advertisement, collects the final protocol response, verifies and imports the staged repository with an exact predecessor state, then releases success only after a checked canonical journal append. C Git enforces advertised old refs and non-fast-forward branch rejection; an isolated hook makes tags create-only. This proves local Git compatibility before native pack synthesis; it is not a performance path. Signed multi-device journal authorization remains separate work.

`yeokcham-server` adds a separate read-only Yeokcham-native HTTP V1 boundary: `GET /v1/health`, `GET /v1/refs`, and `GET /v1/objects/<sha1>`. Ref names are exact hexadecimal bytes; object bodies are reconstructed and Git-ID-verified before response. It is deliberately not Git smart HTTP, so Git continues to use the local remote helper. Every endpoint requires one exact bearer token loaded from an operator-managed private regular file; the server compares it in constant time and does not log it. The server accepts only a loopback numeric socket address, defaults to `127.0.0.1:0`, permits no request body or persistent connection, and bounds headers, body construction, deadlines, workers, and accepted-socket backlog. See [`docs/native-http-v1.md`](docs/native-http-v1.md), ADR-0092, and ADR-0093.

### 3.2 Repository service

The repository service is the central orchestration layer.

Responsibilities:

- Resolve refs.
- Compute reachable object sets.
- Import Git objects.
- Choose blob representation.
- Reconstruct requested Git objects.
- Coordinate durable object writes and ref updates.
- Enforce repository format version and feature flags.
- Expose verification, export, and maintenance operations.

### 3.3 Git compatibility module

Responsibilities:

- Parse and validate object headers.
- Calculate and verify Git object IDs.
- Read and write packfiles.
- Handle commit, tree, blob, and tag objects.
- Perform reachability traversal.
- Support relevant hash algorithms only when explicitly added.

Initial scope:

- SHA-1 Git repositories.
- SHA-256 repository support is a later compatibility milestone.
- Do not implement shallow clone, alternates, or every protocol feature in the first prototype.

### 3.4 Storage policy engine

The policy engine selects one of several representations.

Inputs may include:

- Blob size.
- Entropy estimate.
- File extension or MIME hint.
- Whether the bytes appear already compressed.
- Prior versions and similarity signals.
- Access frequency.
- User overrides.

Initial policies:

```text
size <= tiny_threshold:
    aggregate whole blob

tiny_threshold < size <= chunk_threshold:
    store whole blob in compressed segment

size > chunk_threshold:
    content-defined chunking
```

Do not add machine learning. Use transparent heuristics and benchmark them.

### 3.5 Metadata store

Suggested initial implementation: SQLite.

Responsibilities:

- Repository configuration.
- Git object ID to yeokcham representation mapping.
- Blob manifests.
- Segment inventory.
- Chunk location index.
- Ref state and local journal index.
- Backend upload state.
- Cache state.
- Mirror state.
- Schema migrations.

SQLite is not the canonical remote data format. It is a local acceleration and coordination database. Canonical remote metadata must also exist in portable versioned records.

### 3.6 Chunk and segment store

#### Chunk identity

A chunk ID is a cryptographic hash of plaintext chunk bytes within the user's repository or deduplication domain.

#### Segment

A segment is an immutable container holding many records.

Possible layout:

```text
SegmentHeader
RecordDirectory
RecordPayloads
SegmentFooter
```

Each record includes:

- Record type.
- Plaintext content ID.
- Compression method.
- Uncompressed length.
- Compressed length.
- Authentication metadata or encrypted envelope.
- Payload offset.

The segment itself should have:

- Format version.
- Repository or deduplication-domain ID.
- Segment ID.
- Record count.
- Integrity checksum.
- Optional encryption envelope metadata.

#### Index

Indexes map content IDs to:

- Segment ID.
- Offset.
- Stored length.
- Plain length.
- Compression.
- Record type.

Indexes should be independently verifiable and reconstructable from segments.

### 3.7 Blob manifest

A chunked Git blob maps to an ordered list of chunk references.

Conceptual form:

```text
BlobManifest {
  version,
  git_object_id,
  plaintext_length,
  representation,
  chunks: [
    { chunk_id, plaintext_length },
    ...
  ],
  full_content_hash,
}
```

For whole-blob storage, the manifest may reference one record.

The manifest must provide enough information to reconstruct the exact Git blob bytes and verify the original Git object ID.

### 3.8 Ref transaction manager

Ref updates are small mutable operations and must not be embedded inside large mutable repository files.

Use an append-only journal entry concept:

```text
RefEvent {
  repository_id,
  device_id,
  sequence,
  previous_event_hash,
  timestamp,
  updates: [
    { ref_name, expected_old, new_value }
  ],
  signer,
  signature,
}
```

Local state applies events only when:

- Signature is valid.
- Sequence and previous hash are coherent for that device.
- Preconditions are satisfied or divergence is explicitly preserved.

A consolidated manifest may periodically summarise accepted journal heads.

### 3.9 Backend interface

The backend should be intentionally weak. The current core contract is runtime-neutral and object-safe: it returns boxed sendable futures rather than using native `async fn` trait methods. It accepts bounded in-memory reads and bytes, create-only immutable publication, opaque slash-delimited keys, paginated listing, maintenance-only deletion, and explicit resumable-upload sessions. Key syntax is intentionally limited to safe opaque ASCII path components; encryption and provider-specific opaque-key derivation are separate layers.

```rust
trait Backend {
    fn put_if_absent(&self, key: &BackendKey, data: &[u8]) -> BackendFuture<BackendPutResult>;
    fn get(&self, key: &BackendKey, request: BackendReadRequest) -> BackendFuture<Vec<u8>>;
    fn head(&self, key: &BackendKey) -> BackendFuture<BackendObjectMetadata>;
    fn list(&self, prefix: &BackendPrefix, cursor: Option<&BackendCursor>, limits: BackendListLimits) -> BackendFuture<BackendListPage>;
    fn delete(&self, key: &BackendKey) -> BackendFuture<()>;
    fn start_resumable_put_if_absent(&self, key: &BackendKey, total_length: u64) -> BackendFuture<BackendResumablePutStart>;
    fn write_resumable(&self, session: &BackendUploadSession, offset: u64, data: &[u8]) -> BackendFuture<()>;
    fn complete_resumable(&self, session: &BackendUploadSession) -> BackendFuture<BackendPutResult>;
    fn abort_resumable(&self, session: &BackendUploadSession) -> BackendFuture<()>;
}
```

Backend-specific consistency behaviour must be documented.

`FilesystemBackend` maps each backend key under a caller-owned root and reserves `.yeokcham-uploads/` for resumable staging. It uses create-new staging files, hard-link publication without replacement, and file/directory synchronization on Unix. Its own list implementation returns lexically ordered pages, but callers must not generalize that order or local visibility guarantee to remote providers. Reads reject ranges outside the exact current file length and caller byte limits. The implementation is runtime-neutral but performs filesystem I/O when its future is polled; callers that require nonblocking scheduling must use an appropriate blocking executor.

The Drive authorization foundation uses an operator-supplied Google Desktop OAuth client ID, the non-sensitive `drive.file` scope, PKCE S256, and a fresh listener bound only to `127.0.0.1`. The core builds the authorization URL, verifies the callback state, exchanges the code through a bounded non-redirecting HTTPS transport, and holds redacted access/refresh tokens only in memory. `KeyringDriveCredentialStore` persists only the refresh token in the platform Keychain/keyring under a SHA-256-derived account label; missing or inaccessible OS storage fails rather than falling back to repository configuration or a plaintext file. A stored credential exchanges that token for a new redacted in-memory access token through the same bounded transport; a refresh response never needs to return or overwrite the stored refresh token. `yeokcham drive auth` prints the authorization URL instead of launching a browser. Its optional fixed loopback port supports SSH forwarding to a browser-capable machine. The implementation neither embeds an OAuth client secret nor writes token material into repository configuration.

`DriveBackend` restricts every URL to Google Drive HTTPS endpoints and routes through an injectable bounded transport. It derives a deterministic opaque name per logical key, prefixes each provider file with an authenticated encrypted `YKDO` logical-key capsule, validates it before reads or listing, and treats duplicate names as conflicts except when it can safely remove the newly identified duplicate from its own completed race. Google list order is ignored: full bounded Drive pages are scanned and logical keys are ordered locally. A bounded positive metadata cache avoids repeat name searches for confirmed files; it never caches absence, every create check is fresh, and local deletes invalidate the entry. It retries only bounded read/list/delete requests for rate limits and transient service errors, and uses resumable upload sessions with 256 KiB non-final ranges. A final session is accepted only after a successful file confirmation; incomplete sessions never produce a backend result. The backend rejects standalone `chunks/` keys so content-defined chunks remain within immutable segment uploads. It is a physical backend and must sit below `EncryptedBackend` for repository bytes.

`FaultInjectingBackend` returns one configured injected I/O error before it delegates that one-based global operation attempt. It is deterministic only when callers serialize operations, and it simulates a pre-call failure rather than a crash after a backend mutation. `MetricsBackend` records in-process, saturating atomic counts per operation plus supplied put/write and returned get bytes. Its snapshot is not a transaction boundary: concurrent calls can make related counters observe different instants. Neither wrapper adds locks, retries, ordering, durability, authentication, or cross-object consistency.

A successful `put_if_absent` or resumable completion only establishes the backend's result for that one key. A later list can omit it, a returned cursor can race other writers, and an `AlreadyExists` result cannot authenticate existing bytes. A recovery workflow must enumerate with bounded retries appropriate to its provider, fetch the exact immutable record, and verify higher-level checksums, signatures, and Git identities before advancing any ref.

The repository layer must not assume:

- Atomic directory rename.
- Cross-object transactions.
- File locks.
- Ordered listing.
- Immediate global visibility.

### 3.10 Encryption layer

Encryption occurs after chunking and compression, before remote persistence. ADR-0064 fixes the initial suite as XChaCha20-Poly1305 with fresh 192-bit nonces, HKDF-SHA-256 domain-separated subkeys, Argon2id passphrase wrapping, system entropy through `getrandom`, and `zeroize`-backed secret storage. These values are format inputs, not runtime preferences.

`EncryptedBackend` seals each complete backend object in a version-1 `YKCE` envelope. Canonical associated data binds the repository UUID, encrypted-object domain, backend key, segment UUID when applicable, and plaintext length. `segments/<uuid>` derives a segment subkey; `indexes/`, `manifests/`, `refs/`, and `format/` derive metadata subkeys; other keys derive backend-object subkeys. The wrapper preserves create-only publication and returns plaintext lengths for head/list, but complete-object AEAD currently rejects direct range reads and caller-managed resumable uploads rather than silently buffering an unbounded object. Drive's physical backend performs its own resumable transport beneath complete-object encryption.

`RepositoryEncryptionKey::export_with_passphrase` produces a canonical `YKRK` recovery export and `import_with_passphrase` verifies and restores it. The export records fixed Argon2id parameters, salt, nonce, and authenticated encrypted master key. The core API accepts explicit passphrase bytes and never persists the master key automatically; command-line key management is a later CLI surface.

`LocalRepository::backup_to_backend` requires `EncryptedBackend` and publishes each bounded canonical recovery file under `recovery/<repository-id>/files/` before a canonical `YKRM` manifest is acknowledged. Recognized interrupted staging files and SQLite metadata are excluded; every other noncanonical source file fails the backup. `restore_from_backend` accepts only those canonical relative names from the manifest, verifies each encrypted file's SHA-256 checksum and length, writes and synchronizes a fresh layout, and opens it through normal repository validation. The recovery APIs do not remove an incomplete destination after failure.

The CLI's `key create-export` generates a new repository-bound master key and writes one create-new passphrase-encrypted `YKRK` export. `drive init` creates an opaque app-owned folder; `drive backup` wraps `DriveBackend` in `EncryptedBackend` and publishes the canonical recovery snapshot, including immutable segment and index files, through `YKRM`. `drive restore` requires an absent destination and runs ordinary repository verification after recovery. `drive verify` restores into a unique temporary directory, verifies it, then removes only that generated directory. Passphrases are accepted only from stdin and are not command-line options or repository configuration.

Remote multi-device ref coordination is a separate encrypted logical namespace, `replication/<repository-id>/device-registry/` and `replication/<repository-id>/ref-journal/`. Root-signed fixed-width `YKDR` records form one immutable registration chain. The root public key is supplied by the operator out of band, not discovered from the backend. A registration binds a UUIDv4 device ID to one Ed25519 verifying key. A revocation records the final accepted journal sequence and immutable event ID for that device: reconciliation accepts only that verified chain prefix, so a later delayed or pre-signed event is rejected. Remote journals accept only signed `YKRE` V2 records from registered keys. A publisher reads and reconciles the remote state, compares the successor's expected state ID, publishes create-only, then refetches. Multiple viable successors, missing predecessors, and concurrent registry changes remain explicit conflicts with every unresolved event retained in the fetch result. This core layer does not yet publish repository content or expose Drive clone/push CLI commands.

Suggested envelope structure:

```text
EncryptedRecord {
  format_version,
  key_id,
  nonce,
  associated_data,
  ciphertext,
  authentication_tag,
}
```

Associated data should bind:

- Repository ID.
- Segment ID.
- Record identity.
- Format version.
- Record type.

Never log plaintext keys, nonces paired with keys in unsafe ways, decrypted paths, or source bytes.

### 3.11 Local cache

Cache layers:

1. Remote metadata cache.
2. Segment/index cache.
3. Decrypted chunk cache.
4. Reconstructed Git object cache.
5. Synthesised pack cache.

Every cache entry must be treated as disposable and integrity-checked.

`CiphertextCache` is a persistent read-through layer for complete immutable `segments/` and `indexes/` backend reads. It names local files by SHA-256 of the opaque backend key, verifies an independent local checksum and length before every hit, and treats malformed cache data as a miss. It must be placed beneath `EncryptedBackend`, so it retains only authenticated envelopes rather than plaintext. Range reads and metadata/manifests deliberately bypass it.

Each opened `LocalRepository` also keeps separate in-memory LRU caches for decrypted chunks and reconstructed Git objects. Each cache is capped at 32 MiB and 1,024 entries; an entry exceeding its byte cap is not retained. A chunk cache key binds the complete reference; hits are reconstructed from their bytes and rechecked against the requested content ID and length. An object cache key binds the complete canonical manifest; hits are rebuilt and rechecked against their requested Git ID and kind. A malformed or mismatched entry is discarded, then canonical immutable storage is consulted. These plaintext caches are process-local only: they have no files, no recovery role, and disappear when the repository handle is dropped.

The initial local helper cache is a complete packed bare Git snapshot under `cache/packs/<effective-ref-state-sha256>`. It has no canonical or recovery role and is recreated from verified Yeokcham records if its exact state or C Git fsck check fails. Every successful cache hit or publication records a durable local last-used timestamp. `yeokcham cache inspect <repo>` reports bounded counts and bytes. `yeokcham cache verify <repo>` verifies canonical storage, then checks every entry's ref-state-derived name and runs strict Git fsck with no cache data emitted. `yeokcham cache trim --max-bytes <bytes> <repo>` applies an explicit LRU byte ceiling; it is intentionally not concurrent with helper serving. `yeokcham cache clear <repo>` reopens the repository bootstrap, rejects a symlink or non-directory cache path, removes only that `cache/` directory, and synchronizes the repository directory. It cannot cache a negotiated upload-pack response because wants, haves, and capabilities vary per client connection.

Receive-pack staging is never cached. A push-specific private bare export starts at one effective ref state, and the later canonical import uses that state as a compare-and-swap predecessor. A conflicting canonical transition can leave only unreachable immutable records; it cannot overwrite refs or receive a success status. The initial advertisement is relayed as packet lines, while the post-request response is bounded to 128 MiB and held until canonical verification succeeds.

### 3.12 GitHub mirror

The initial local configuration is one optional atomic `mirrors/github.ykgm` `YKGM` version-1 record. It binds the repository UUID, a credential-free `owner/repository` target, one or more selected `heads`, `tags`, or exact standard branch/tag rules, a direction policy, and a force-update policy. Its SHA-256 checksum detects accidental or hostile local corruption. The record remains portable canonical recovery data, but it is not a repository-format feature flag: stores without it remain valid.

Each acknowledged checkpoint maps a selected local ref to its remote ref and records their respective verified Git object IDs plus the observed Unix timestamp. Checkpoints are accepted only when the stored local object is still the effective acknowledged local ref target. `yeokcham github plan` reconstructs a fresh verified temporary bare Git export and walks only selected refs through C Git; it reports selected tip IDs and, when explicitly requested, each reachable object ID before removing the export.

Policies:

- `publish-only`
- `pull-only`
- `bidirectional-fast-forward`
- `manual`

`yeokcham github publish <repo> --apply` re-creates that verified temporary export, reads exactly the selected remote refs, then requests one C Git `push --atomic --porcelain` operation. HTTPS uses the user's standard Git credential helper; SSH uses the standard agent. The process inherits neither Git/SSH command overrides nor askpass configuration, has terminal prompting disabled, stores no token, and retains no credential data. It verifies every selected remote ref against the local Git ID after success, then writes all corresponding checkpoints in one local policy update. A stale local ref prevents every checkpoint update. The default force-update policy is `reject`; `require-exact-checkpoint` emits `--force-with-lease` only for a branch whose current remote object exactly equals its persisted checkpoint. Existing tags are never replaced. Pull-only rejects publication; `manual` requires this explicit command. The transport fails closed if the remote does not support atomic pushes.

`yeokcham github publish-pr <repo> --source <refs/heads/branch> --branch <remote-branch> --apply` uses that same one-ref transaction but maps the selected acknowledged local branch to exactly `refs/heads/<remote-branch>`. It rejects source tags, unavailable or unselected local branches, unsupported reference bytes, and invalid target branch names before network I/O. The confirmed checkpoint retains this local-to-remote mapping. It deliberately stops at branch publication: opening or updating a GitHub pull request remains outside the Git transport boundary.

`yeokcham github fetch <repo>` lists bounded standard remote refs and overlays explicit checkpoint mappings before selecting work. It fetches selected remote refs into `refs/yeokcham/github/*` only inside a fresh disposable bare repository using atomic local fetch updates and explicit no-tag/no-refmap settings. Each temporary ref must still equal its preflight remote ID before the core reconstructs, verifies, and imports objects. The temporary repository is removed before success is reported. Import creates immutable records but no snapshot or journal event; canonical refs cannot move as a fetch side effect. Existing local selected refs checkpoint the exact observed remote ref and ID only after import and a current-local-ref check. A missing local counterpart is reported as remote-only; unequal present IDs are reported as divergent. Ref names and IDs are emitted only through explicit `--show-refs`.

`yeokcham github resolve <repo> --accept-remote <local-ref> --remote <remote-ref> --apply` explicitly adopts one currently selected mapping. It lists that mapping again, fetches and verifies exactly that remote object without first recording an observation checkpoint, then creates a successor `GitRefState` with the local ref set to the remote ID. `append_ref_state_if_expected` verifies all target reconstruction and appends its journal event only if the ref state captured before fetch remains current. A successful transition is followed by a checkpoint with equal local/remote IDs. If the checkpoint write fails, the accepted ref event remains authoritative and a retry reconciles the checkpoint; no ref is rolled back or silently replaced.

## 4. Data flows

### 4.1 Import

```text
Git repository
  -> enumerate refs
  -> traverse reachable objects
  -> read bounded object batches and validate object IDs
  -> choose representation
  -> write records to staging segments
  -> seal segments
  -> persist indexes and manifests
  -> verify reconstruction
  -> commit repository generation
  -> commit ref journal event
```

Independent source objects may be read and SHA-1-verified concurrently through separate gitoxide adapter handles. An import batch contains at most eight objects and 64 MiB of declared bodies; batches below 2 MiB and singleton objects remain serial. Canonical storage, SQLite metadata, manifests, ref transitions, and final verification remain ordered and serial.

### 4.2 Fetch

```text
Git wants objects
  -> resolve wants/haves
  -> calculate missing reachable set
  -> obtain manifests
  -> retrieve needed records
  -> decrypt/decompress/reconstruct
  -> verify Git object IDs
  -> synthesise pack
  -> stream to Git
```

### 4.3 Push

```text
Git sends pack + ref commands
  -> parse and validate pack
  -> stage imported objects
  -> seal and persist immutable data
  -> verify all proposed new refs are resolvable
  -> write ref event with expected old values
  -> make event durable
  -> acknowledge success
```

### 4.4 Drive synchronisation

```text
Local new sealed segments
  -> encrypt
  -> upload if absent
  -> upload indexes/manifests
  -> append per-device ref event
  -> publish generation summary

Other device
  -> list journal heads or generation summaries
  -> fetch missing events
  -> fetch referenced metadata
  -> reconcile refs
  -> lazily fetch content
```

## 5. Repository format

Top-level conceptual structure:

```text
yeokcham-repository/
  format/
    repository.bin
  segments/
    ab/cd/<segment-id>
  indexes/
    ab/cd/<index-id>
  manifests/
    blobs/
    objects/
    generations/
  journals/
    refs/<device-id>/<sequence>
  summaries/
    current/<summary-id>
```

Remote keys should be opaque when metadata confidentiality is enabled. `RepositoryEncryptionKey::derive_drive_object_naming_key` derives a separate repository-bound key, then maps each validated backend key through HKDF-SHA-256 to a fixed 64-character hexadecimal Drive file name. A Drive file starts with an authenticated encrypted `YKDO` key capsule, allowing bounded list reconstruction without provider-visible logical keys. The mapping has no database, cache, or cleartext name fallback.

The current local V1 implementation uses flat `segments/<segment-uuid>` paths and `indexes/<segment-uuid>.ykix` paths before future sharding or opaque remote keys. `YKIX` remains rebuildable acceleration metadata and is never trusted instead of the matching sealed segment.

`repository.bin` contains only the minimum bootstrap information and follows the canonical binary policy in [`docs/serialization.md`](docs/serialization.md). It should itself be encrypted if practical.

## 6. Crash consistency

The write order must be:

1. Write temporary local records.
2. Seal immutable segments.
3. Verify sealed segments.
4. Persist or upload immutable segments.
5. Persist indexes and manifests.
6. Verify all objects required by the proposed refs.
7. Append ref event.
8. Acknowledge success.

Garbage collection must not delete old generations until:

- Ref events are durably retained.
- A grace period has elapsed.
- No active lease or maintenance operation references the generation.
- Recovery tests confirm the retained graph is complete.

## 7. Garbage collection

GC phases:

1. Discover accepted ref heads.
2. Traverse reachable Git object identities.
3. Resolve yeokcham manifests and records.
4. Mark reachable segments and records.
5. Retain recent unreferenced objects during a safety window.
6. Compact sparsely live segments by copying live records.
7. Publish new indexes.
8. Delete obsolete segments only after validation.

Remote deletion should be optional in early releases. A leak is safer than data loss.

## 8. Partial retrieval

The local helper relies on C Git-compatible filtering rather than inventing a Yeokcham filter protocol. Its verified complete snapshot lets C Git serve `blob:none` and `blob:limit=<bytes>` with normal promisor configuration and lazy hydration. A C Git cone-mode sparse checkout configured before `checkout` hydrates only selected current paths through the same helper and retains excluded blobs as promisor objects. The complete cache remains an implementation boundary, so this does not yet reduce Yeokcham-side reconstruction or remote-backend reads. Shallow clone and native remote-backend sparse prefetch remain unsupported; non-cone and sparse-index combinations are not covered.

Implemented core seam and remaining progression:

1. `LocalRepository::prefetch_current_sparse_paths` verifies and caches only an explicit current-`HEAD` path set. The daemon schedules configured selections after ref metadata changes and prebuilds the existing disposable ref-state-keyed snapshot-pack cache; the helper consumes that verified disk cache but not the daemon's in-memory objects.
2. Avoid reconstructing excluded records before C Git pack filtering.
3. Measure the daemon-prebuilt snapshot path before claiming an end-user workload improvement.

Do not build a virtual filesystem until benchmark results show that ordinary sparse checkout is insufficient.

## 9. Observability

Provide:

- Human-readable CLI output.
- Structured JSON logs.
- Trace IDs for operations.
- Per-stage timings.
- Bytes read/written by layer.
- Cache hit rates.
- Chunk deduplication ratio.
- Pack synthesis time.
- Backend round trips.

Logs must avoid source content and sensitive ref names when metadata privacy is enabled.

## 10. Upgrade strategy

Every persistent record includes:

- Format version.
- Feature flags.
- Required reader version where necessary.

Upgrades should be:

- Copy-on-write.
- Resumable.
- Verifiable.
- Reversible until finalisation.
- Tested using old-format fixtures.

Never rewrite the only copy of a repository in place without a recovery generation.
