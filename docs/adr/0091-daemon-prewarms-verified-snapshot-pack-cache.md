# ADR-0091: Prewarm the existing verified snapshot-pack cache from the daemon

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The daemon's in-memory sparse object cache is process-local, while the remote helper serves C Git from an existing disposable ref-state-keyed snapshot-pack cache. A configured daemon can perform the cache's verified construction before a user starts the later helper workflow without exposing object bodies over IPC.

## Decision

After each configured sparse prefetch, the daemon verifies canonical storage and prewarms the helper's existing `cache/packs/<ref-state-id>` entry. It exports a verified bare repository to a private staging directory, packs it with C Git, validates the expected ref state and strict Git fsck, then publishes by rename without replacement. Existing helper cache validation and access-time records remain the compatibility contract.

The configured daemon performs this work only after an acknowledged ref or supplied sparse-checkout-file change. Control-only daemon operation remains free of pack construction. The later helper opens the same disposable cache entry normally; no daemon socket request or persistent format changes are introduced.

## Consequences

The user-observed helper workflow can reuse a cache built before it starts. Daemon refresh becomes more expensive and may fail when cache construction or storage verification fails. This decision does not establish a performance result; W5 must report the prewarm cost separately from later checkout timing.

## Invariants

- A prebuilt entry is accepted only after canonical repository verification, expected ref-state validation, and strict Git fsck.
- A cache entry is scoped to one ref state and is never overwritten in place.
- A failed prewarm leaves canonical Git and Yeokcham state unchanged and does not make a stale entry current.
- Cache loss, eviction, or daemon shutdown preserves the normal helper cold path.

## Compatibility and migration

The cache layout, key, and access record are existing disposable helper state. No repository, segment, manifest, or daemon wire format changes.

## Security and recovery

Staging and final cache paths reject symlink misuse through the existing cache checks. The daemon writes no new canonical object data and recovery never depends on a cache entry.

## Verification

Daemon tests configure a real cone sparse-checkout file, prove selected-object hydration, and run strict Git fsck on the prebuilt helper cache. The W5 harness records cold, helper-warm, and daemon-prebuilt helper workflows from the same generated fixture.
