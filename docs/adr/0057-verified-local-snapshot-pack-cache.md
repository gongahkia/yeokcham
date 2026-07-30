# ADR-0057: Cache verified full local snapshot packs

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The local remote helper exported every effective Yeokcham state into a new loose-object bare Git repository for every `connect git-upload-pack` request. That proves compatibility but repeats reconstruction and leaves C Git to repack the same complete graph on every connection. A raw upload-pack result cannot be safely reused because a client's wants, haves, protocol version, and capabilities determine its negotiated response.

## Decision

Cache a complete conventional bare Git snapshot under `<store>/cache/packs/<sha256-effective-ref-state>`. Build it only from a fully verified local Yeokcham store, pack it with fixed C Git commands, and publish its directory atomically. Before every use, open it through the isolated Git adapter, require exact effective-ref-state equality, and run `git fsck --full --strict`. Any missing, partial, malformed, wrong-state, or fsck-failing entry is disposable and rebuilt; cache verification or construction failures never cause the canonical store to be modified.

Delegate every upload-pack conversation to C Git after selecting the verified complete snapshot. Do not cache wire responses, advertized capabilities, or packs chosen for one client's haves.

## Consequences

Unchanged clone and fetch requests can reuse a C-Git-readable packed object database without changing the Git protocol boundary. A changed effective state uses a distinct entry, so an old snapshot cannot serve new refs. Current entries are retained until a later cache-capacity policy; the existing cache-clear and capacity TODOs remain open.

The cache contains plaintext conventional Git objects in the current unencrypted local milestone. It is local acceleration data only, is excluded from repository verification and recovery, and must not be copied to a remote backend as canonical data. Invalid cache bytes are not trusted even though they are local.

## Invariants

- Canonical Yeokcham storage is fully verified before any cache selection or build.
- A cache entry is used only if its complete refs exactly equal the materialized local state and C Git fsck succeeds.
- A cache key selects a full state, never one client-specific negotiated response.
- Cache publication cannot replace canonical records or ref events.
- Cache loss, corruption, or deletion can only require reconstruction from canonical records.

## Compatibility and migration

This adds no canonical persistent format or migration. `cache/` is a disposable local directory. Existing stores build entries on their first helper request; deleting `cache/` restores the pre-cache behavior for the next request until it is regenerated.

## Security and recovery

The helper uses fixed C Git subcommands with helper-created paths, hides their diagnostic output, rejects symlink cache roots, and revalidates cache bytes before delegation. Source repository paths, source bytes, ref names, object IDs, and cache keys are not emitted in default logs. A cache entry is not an authorization boundary and does not make unsigned ref events safe for multiple writers.

## Verification

The remote-helper integration test proves clone and fetch equivalence, validates the generated bare cache with `git fsck --full --strict`, checks reuse for unchanged refs, corrupts a cached pack index and proves rebuild before fetch, then syncs a changed/deleted ref state and proves a separate valid cache entry. Workspace CI, MSRV CI, and bounded parser fuzzing remain required gates.
