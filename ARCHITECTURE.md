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

Current local bridge: `git-remote-yeokcham` advertises only `connect`, accepts only `connect git-upload-pack`, verifies and exports the immutable store into a private temporary bare repository, then proxies C Git's smart upload-pack byte stream. It performs no pack parsing or buffering itself. This proves Git compatibility before native pack synthesis; it is not a performance path and cannot serve mutable ref updates until push/journal work exists.

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

The backend should be intentionally weak.

```rust
trait Backend {
    async fn put_if_absent(&self, key: &ObjectKey, data: ByteStream) -> Result<PutResult>;
    async fn get(&self, key: &ObjectKey, range: Option<ByteRange>) -> Result<ByteStream>;
    async fn head(&self, key: &ObjectKey) -> Result<ObjectMetadata>;
    async fn list(&self, prefix: &Prefix, cursor: Option<Cursor>) -> Result<ListPage>;
    async fn delete(&self, key: &ObjectKey) -> Result<()>;
}
```

Backend-specific consistency behaviour must be documented.

The repository layer must not assume:

- Atomic directory rename.
- Cross-object transactions.
- File locks.
- Ordered listing.
- Immediate global visibility.

### 3.10 Encryption layer

Encryption occurs after chunking and compression, before remote persistence.

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

### 3.12 GitHub mirror

Mirror state should record:

- Local ref.
- Remote ref.
- Last observed local object ID.
- Last observed GitHub object ID.
- Direction policy.
- Force-update policy.
- Last successful synchronisation.
- Conflict state.

Policies:

- `publish-only`
- `pull-only`
- `bidirectional-fast-forward`
- `manual`

No silent force-push in the default policy.

## 4. Data flows

### 4.1 Import

```text
Git repository
  -> enumerate refs
  -> traverse reachable objects
  -> decode object
  -> validate object ID
  -> choose representation
  -> write records to staging segments
  -> seal segments
  -> persist indexes and manifests
  -> verify reconstruction
  -> commit repository generation
  -> commit ref journal event
```

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

Remote keys should be opaque when metadata confidentiality is enabled.

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

Initial implementation should rely on Git-compatible filtering where possible.

Possible progression:

1. Clone/fetch all metadata and current blobs.
2. Support `blob:none`.
3. Support size filters.
4. Track promisor state.
5. Hydrate missing blobs on demand.
6. Add sparse path-aware prefetch.
7. Add daemon-assisted prediction.

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
