# ADR-0084: Share only verified Git objects through a bounded process cache

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

`LocalRepository` already has private resolver caches. A daemon may hold several repository handles and needs an opt-in process-level reuse seam without making object bytes durable or sharing them across repositories implicitly.

## Decision

`SharedObjectCache` is an explicitly constructed, mutex-protected LRU cache keyed by `(RepositoryId, GitObjectId)`. It accepts an object only after canonical Git-ID verification and re-verifies it before returning a clone. It is bounded by caller-selected body bytes, skips an object larger than the full capacity, and supports explicit clearing.

## Consequences

Daemon callers can reuse verified reconstruction results across handles for the same repository after validating their manifest/operation inputs. The cache is in-memory only and has no disk, encryption, or migration behavior.

## Invariants

- A cache hit never crosses a repository ID boundary.
- Stored and returned objects verify their Git IDs.
- Eviction is deterministic LRU and cannot overflow its byte accounting.
- Clearing or disabling the cache changes no repository state.

## Compatibility and migration

No persistent format. Restart, clear, or removal discards all entries safely.

## Security and recovery

Cached plaintext stays only in process memory and debug output contains counts rather than object data. Callers must validate a manifest or operation boundary before accepting a shared-cache hit; the cache itself does not replace storage integrity checks. Recovery never relies on it.

## Verification

Tests prove repository scoping, ID verification, LRU eviction, clear behavior, and thread-safety bounds.
