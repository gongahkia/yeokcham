# ADR-0074: Cache verified resolver plaintext only in bounded process memory

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Resolving a chunked blob repeatedly decodes the same decrypted chunks, and serving or exporting repeatedly reconstructs the same verified Git objects. A persistent plaintext cache would expand the local confidentiality and recovery surface.

## Decision

Keep separate decrypted-chunk and reconstructed-Git-object caches inside each `LocalRepository` process. Bound each cache to 32 MiB and 1,024 entries with LRU eviction. Do not retain an entry exceeding its byte limit and never write either cache to disk.

## Consequences

Cache contents disappear when the repository handle is dropped. Canonical segments and manifests remain authoritative. Cache efficiency is intentionally not a benchmark claim.

## Invariants

- A chunk entry binds its complete reference; a hit is rederived from its bytes and must match the requested content ID and length.
- An object entry binds its complete canonical manifest; a hit is rebuilt and must verify its requested Git ID and kind.
- A malformed or mismatched entry is removed before immutable storage is consulted.
- Eviction or process loss cannot affect reconstruction correctness or recovery.

## Compatibility and recovery

No repository-format change and no migration. No plaintext cache files are created.

## Verification

Unit tests corrupt each cache, prove fallback repairs it, then remove the source segment and prove the repaired in-memory entry still reconstructs. A separate test proves entry and byte bounds plus LRU eviction.
