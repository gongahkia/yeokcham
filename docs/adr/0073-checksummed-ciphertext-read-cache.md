# ADR-0073: Cache immutable encrypted segments and indexes by opaque key

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Remote immutable segments and indexes can be read repeatedly during recovery and future remote resolution. A local cache must not leak plaintext, trust a malformed file, or change results when deleted.

## Decision

Use `CiphertextCache` as a checksum-validated read-through layer for complete `segments/` and `indexes/` backend reads. Name entries with SHA-256 of the opaque backend key and place the cache below `EncryptedBackend`, where values are authenticated ciphertext envelopes. Range reads and all other key namespaces bypass the cache.

## Consequences

Cache corruption becomes a miss and refetches the immutable backend value. The cache has no canonical or recovery role. The wrapper is reusable but callers must explicitly compose it below encryption; it does not cache plaintext or provide chunk/object resolver caching.

## Invariants

- Cache paths never expose logical backend keys.
- A hit requires a bounded regular file, valid versioned header, exact length, and SHA-256 checksum.
- Symlinks and malformed data are not trusted.
- Cache publication failures do not change a successful backend read.

## Compatibility and recovery

No repository-format change. Removing the cache only causes future immutable reads to reach the backend.

## Verification

Unit tests prove segment/index cache hits, corruption fallback, namespace exclusion, and that an `EncryptedBackend<CachedBackend<_>>` cache contains no plaintext fixture bytes.
