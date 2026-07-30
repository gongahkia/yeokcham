# ADR-0072: Trim snapshot cache explicitly with LRU

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The local remote helper caches complete, verified bare Git snapshots. They are disposable but can accumulate after ref-state changes. Automatically removing an entry while a helper process is serving it can interrupt that Git operation. Cache contents do not have a canonical role, so an explicit local maintenance action can safely apply a storage limit outside active serving.

## Decision drivers

- Bound local snapshot-cache disk use on request.
- Preserve canonical repository correctness and recovery independence.
- Avoid cache eviction during an active helper operation.
- Make eviction order inspectable and testable.

## Considered options

### Automatic eviction on helper access

This would apply a limit without operator action, but a concurrent helper may still be using the entry selected for deletion.

### Age-based eviction from directory timestamps

Directory timestamps do not represent every successful cache reuse and vary by filesystem behavior.

### Explicit LRU trimming with durable access records

The helper can record a local last-used timestamp after every verified hit or successful publication. A separately invoked CLI command can then remove least-recently-used snapshot directories until a supplied byte limit is met.

## Decision

Record a local `.yeokcham-last-used` timestamp file in every successfully used snapshot-cache entry. Provide `yeokcham cache trim --max-bytes <bytes> <repo>` to enforce a caller-selected limit by deleting least-recently-used entries. The command validates that every candidate is a real directory and rejects symbolic links; it synchronizes the parent cache directory after deletions. It is documented for use outside active remote-helper operations.

## Consequences

There is no default automatic cache ceiling. Operators choose a limit appropriate to available local storage and invoke trimming as maintenance. A cache entry may be recreated after eviction; canonical records, refs, and recovery data remain untouched. Entries with zero bytes do not need deletion to satisfy a zero-byte limit.

## Invariants

- Trimming never removes paths outside `<repo>/cache/packs`.
- Symbolic links and unsupported cache entry types fail closed.
- An entry's last-used data contains only a timestamp, never Git content or repository metadata.
- Cache eviction cannot change canonical repository bytes or acknowledged refs.
- The helper validates a rebuilt or reused entry before serving it.

## Compatibility and migration

No persistent repository-format changes. Existing snapshot entries without a last-used record sort by their directory modification time until the helper reuses them. Older binaries ignore the local marker file.

## Security and recovery

Last-used markers are local cache metadata. They are bounded by cache inspection and must be regular files. A failed marker update emits only a structured error code and does not make verified cache data a recovery dependency. A user can clear all cache data and recreate it from canonical verified storage.

## Verification

The remote-helper integration test creates two ref-state cache entries, invokes the trim command with a limit equal to the newer entry's measured size, and proves that the older entry is removed while the newer entry remains. Package tests also cover cache inspection, verification, corruption detection, symlink rejection, and cache clearing.
