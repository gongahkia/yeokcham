# ADR-091 — V4 local recoverable garbage collection

- Status: Accepted
- Date: 2026-08-30
- Deciders: maintainers
- Implements: [#248](https://github.com/gongahkia/yeokcham/issues/248)
- Depends on: ADR-090 durable restore proofs

## Context

V4 checkpoint compaction removes unneeded checkpoint names from current project
state but intentionally leaves immutable object files in the local store.
Those files can include unreachable snapshots, trees, contents, chunk manifests,
chunks, and prior project-state objects. Removing bytes is not another model
transition: it is a destructive storage operation that must preserve every
recovery promise already represented by V4 state.

## Decision

The collector has three explicit phases:

1. `storage gc --dry-run --explain` derives one deterministic local plan and
   changes nothing.
2. `storage gc --apply` re-derives that plan while holding the restore-retention
   and project-state locks, then atomically moves only candidates into a local
   durable quarantine transaction.
3. `storage gc purge --id ID` revalidates current reachability before unlinking
   a complete transaction. `storage gc restore --id ID` moves its objects back
   instead. An interrupted transaction is visible and must be resumed,
   restored, or purged explicitly; it is never silently discarded.

The canonical `gc-transaction-v1` record contains the state-head object ID and
the exact sorted candidate object IDs and sizes. It is create-only and stored
locally below `.yeokcham/gc/`; it never enters a project state, package,
bootstrap basis, relay, authority record, or delivery.

### Root algebra

The collector marks the closure of these roots:

- the object selected by the sole `v4-project-state` mutable head;
- every checkpoint still named by that current project state, including
  ordinary retained scratch checkpoints;
- the more specific model reasons for baseline, draft, shared revision,
  delivery, resolution, open decision, pin, restore journal, and restore proof;
- every incomplete restore journal and every legacy published journal without a
  matching proof;
- every durable restore proof.

Snapshot closure means the snapshot object, its complete tree DAG, every file
content object, every file manifest, and every chunk. Collaboration, authority,
signed revision, authorization, adoption, and local transport data are embedded
in the current V4 project-state object; they do not create independent store
object roots. Offline packages are independent copied artifacts, not implicit
local retention promises.

Any malformed root, missing closure object, corrupt state/object, unsupported
unreachable object category, stale transaction, or lock failure stops the
operation before it moves or deletes another object. Unsupported object
categories remain retained rather than being guessed safe to collect.

Object moves use same-filesystem rename plus fsync of both affected directories.
Final removal uses unlink plus directory fsync. Rename is atomic within a
filesystem, while file durability still requires syncing directory entries;
these semantics are the basis for quarantine/recovery rather than an
in-place overwrite. [rename(2)](https://man7.org/linux/man-pages/man2/renameat.2.html)
[fsync(2)](https://man7.org/linux/man-pages/man2/fsync.2.html)

## Consequences

The tool gives an exact explanation before changing data. `--apply` does not
claim to free blocks immediately: it creates a recoverable quarantine. Only
explicit purge can reclaim the space. Garbage collection has no network,
semantic, authority, delivery, or working-tree effect.

The collector does not retain an object merely because an old V4 state object
once named it. A user who wants a snapshot retained keeps it named by current
state, pins it, or keeps a restore proof. This makes the retention promise
explicit and inspectable rather than accidental.

## Verification

- pure deterministic classification and generated shared-closure tests;
- canonical transaction fixture and malformed/old-version rejection;
- empty-store, retained checkpoint, pin, shared/delivery/decision, journal,
  proof, manifest/chunk, and prior-state candidate coverage;
- race/stale-head, interrupted quarantine, corrupt object, missing closure,
  restore, and purge no-partial-state tests;
- CLI dry-run explanation and explicit apply/restore/purge journeys.
