# ADR-0065: Encrypt complete backend objects with bound envelopes

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The backend contract accepts byte vectors, and the new repository key hierarchy has no persistent ciphertext consumer. Remote storage needs a concrete authenticated encryption layer for segments and sensitive metadata before a provider is connected. Existing local repository V1/V2 paths and files must remain readable rather than changing in place.

## Decision drivers

- Encrypt complete immutable backend objects before a filesystem backend writes them.
- Bind ciphertext to repository, storage domain, external object identity, and length.
- Keep the envelope independently bounded and versioned.
- Retain backend create-only and deletion semantics.
- Avoid presenting unauthenticated encrypted metadata as trusted recovery evidence.

## Considered options

### Option 1: generic complete-object `EncryptedBackend`

Wrap any backend, seal its bytes as one `YKCE` envelope, derive a per-object subkey, and resolve plaintext metadata from a fixed-size envelope header.

### Option 2: change each segment and manifest record format directly

Create encrypted successors for all current local records. This is broader than the backend layer and would require an immediate migration of local import, verification, export, and ref workflows.

### Option 3: encrypt transport bytes only

Rely on a provider connection without encrypting persisted objects. This leaves backend copies and recovery exports outside the milestone's encrypted-storage boundary.

## Decision

Use Option 1. `EncryptedBackend<B>` owns a `RepositoryEncryptionKey` and wraps a `Backend`. A create-only put creates a fresh random-nonce envelope and delegates that envelope unchanged to the inner backend. A full read fetches one caller-bounded envelope, validates its canonical `YKCE` header, derives the bound key, verifies XChaCha20-Poly1305 authentication, and returns the exact plaintext. Authentication occurs before the wrapper returns plaintext.

`YKCE` version 1 is canonical: magic `YKCE`, `u16` version `1`, fixed 24-byte nonce, `u64` plaintext length, and a length-delimited ciphertext consisting of exact plaintext length plus the 16-byte AEAD tag. The backend key is external routing data and is not duplicated in the envelope. Associated data canonically encodes `YKCE` version, repository UUID, encryption-domain tag, backend key, segment UUID for a canonical `segments/<uuid>` key, and plaintext length. Segment paths derive segment keys; indexes, manifests, refs, and format paths derive metadata keys; other paths derive backend-object keys.

`head` and `list` read the fixed public header to report plaintext length, but header metadata is not authenticated until a complete read succeeds. The wrapper rejects range reads and resumable upload calls with `unsupported`: complete-object AEAD cannot satisfy an arbitrary small range request without fetching/decrypting the complete object under the current bounded-vector contract. A streaming-envelope extension requires a new format and contract decision.

## Consequences

Stored bytes are ciphertext and cleartext length/header fields; backend keys remain visible to the inner backend. Repeating a create-only request encrypts with a new nonce, but an already-existing immutable object remains unmodified and the wrapper returns the existing header's plaintext length. The wrapper adds complete-object CPU, allocation, ciphertext-tag overhead, and header reads for head/list.

The envelope protects bytes supplied through `EncryptedBackend`, not existing local repository files or the direct `FilesystemBackend`. Current `LocalRepository` workflows do not yet publish through the backend abstraction. Opaque remote keys, encrypted local repository migration, streaming/range encryption, and encrypted resumable multipart upload are deferred.

## Invariants

- Every successful encrypted put stores a new authenticated `YKCE` envelope.
- Plaintext returns only after envelope parsing, key derivation, associated-data construction, and AEAD authentication succeed.
- Segment, metadata, and generic backend-object paths use distinct derived-key and associated-data domains.
- Plaintext length in the envelope equals ciphertext length minus the AEAD tag.
- Default `Debug` values do not disclose master keys, derived keys, plaintext, nonces, backend identities, or authentication details.

## Compatibility and migration

`YKCE` is a new independent encrypted backend object format. It changes no `YKSG`, index, manifest, ref-event, bootstrap, or Git object bytes. Existing unwrapped backends cannot be opened through `EncryptedBackend`; callers must select the correct storage mode explicitly. A future streaming envelope or opaque-key format uses a new magic/version or required feature rather than reinterpreting `YKCE` version 1.

## Security and recovery

The cleartext envelope header leaks plaintext length and the inner backend sees its path key. The wrapper does not trust `head` or `list` metadata for recovery; recovery still completes a bounded read and verifies authentication, canonical record checksums, signatures, and Git identities. Ciphertext tampering, wrong repository keys, domain changes, key swaps, and associated-data changes fail as `corrupt_data` without returned plaintext. `zeroize` reduces the lifetime of master and derived keys in process but does not erase caller-owned plaintext.

## Verification

Tests prove ciphertext-only filesystem object bytes, correct plaintext reads and plaintext lengths, wrong-key rejection, ciphertext tampering rejection, segment/metadata/backend domain separation with deterministic supplied key/nonce inputs, range rejection, secret-redacted `Debug`, and thread safety. Full workspace CI, rustdoc with warnings denied, and fuzz smoke run before acceptance.
