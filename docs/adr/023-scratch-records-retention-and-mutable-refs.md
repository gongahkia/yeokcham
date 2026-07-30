# ADR-023 — Scratch records, retention, and mutable refs

- Status: Accepted
- Date: 2026-07-30
- Deciders: maintainer (approved Milestone 2 direction on 2026-07-30)
- Supersedes: None
- Superseded by: None

## Context and problem statement

Milestone 1 persists byte-correct snapshots but has no durable scratch history.
Milestone 2 needs immutable event and checkpoint records, independently mutable
retention annotations, a recoverable scratch head, deterministic timeline
traversal, and a guarded restore path.  These requirements must not introduce a
second object-ID scheme, mutate a checkpoint to pin it, or make an index the
only record of history.

## Decision drivers

- Reuse Envelope-1 objects and ADR-020 stored-object identities.
- Keep event, checkpoint, snapshot, retention-change, and mutable-ref handles
  type-distinct in the OCaml API.
- Make canonical ancestry independent of an optional query index.
- Reject divergent mutable-ref updates instead of last-writer-wins publication.
- Preserve a scan-derived safety checkpoint before a populated-directory restore.

## Considered options

### Rewrite checkpoint records for pinning

- Makes effective retention easy to read.
- Changes an immutable checkpoint identity and invalidates references.

### Mutable side index for all scratch metadata

- Reduces immutable-object count.
- Makes recovery depend on an overwriteable index and can hide divergent state.

### Immutable records plus atomic mutable refs

- Keeps accepted events, checkpoints, and retention edits independently
  verifiable and append-only.
- Requires explicit ref locking, compare-and-swap, and recovery documentation.

## Decision outcome

Scratch Event v1 and Scratch Checkpoint v1 are Profile-1 payloads inside
Envelope-1 objects of the existing `Scratch_event` and `Checkpoint` types.
Their identities are their existing ADR-020 `Stored_object_id`s; API wrappers
remain distinct despite the shared underlying object ID.

```text
scratch-event-v1 = [
  1,
  parent-checkpoint-object-id,
  base-snapshot-object-id,
  resulting-snapshot-object-id,
  [* scratch-operation-v1],
  observation-source,
  observed-at-unix-seconds
]

scratch-checkpoint-v1 = [
  1,
  parent-checkpoint-object-id-or-null,
  event-object-id-or-null,
  resulting-snapshot-object-id,
  created-at-unix-seconds,
  [* intrinsic-retention-reason-v1]
]

scratch-operation-v1 =
    [0, path-components, entry-v1]                                  ; create
  / [1, path-components, entry-v1]                                  ; delete
  / [2, path-components, expected-content-object-id, replacement-content-object-id]
  / [3, path-components, expected-mode, replacement-mode]
  / [4, source-path-components, destination-path-components, entry-v1]

entry-v1 = [0] / [1, mode, content-object-id]                       ; directory / file
path-components = [* safe-path-component-bytes]
```

`observation-source` is explicit (`0` explicit command, `1` scan).  A change
set emitted by the v1 differ uses only create, delete, modify-content, and
change-mode; move remains an exact, validated operation available to later
producers.  Operations retain their array order because order is part of
replay semantics.  The differ orders deletion descendants before parents,
then creates parents before descendants, with bytewise path tie-breaking.

An initial checkpoint has null parent and event.  Every non-initial checkpoint
has both.  Loading a non-initial checkpoint verifies that its event names the
same parent, parent's snapshot as base, and the checkpoint snapshot as result;
it also replays the event over the parent snapshot and compares the resulting
state with the declared snapshot.  A reader rejects cycles, missing references,
wrong object types, noncanonical payloads, unsupported versions, or any
disagreement.

Checkpoint creation records intrinsic `Recent_window` retention.  Later
retention changes use a new additive Envelope-1 type `Retention_change`:

```text
retention-change-v1 = [
  1,
  previous-retention-change-object-id-or-null,
  checkpoint-object-id,
  action,
  retention-reason-v1,
  changed-at-unix-seconds
]

action = 0 / 1                                                       ; add / remove
```

`retention-reason-v1` preserves the formal-model tags for user pin, capsule
boundary, release boundary, validation, periodic retention, recent window,
and conflict reference.  Milestone 2 produces `User_pinned` through the CLI;
the capsule and validation variants are typed placeholders only and no capsule
or validation feature is implemented.  Effective retention folds the intrinsic
checkpoint reasons with the verified retention-change chain.  Pinning and
unpinning therefore never replace a checkpoint object or checkpoint ID.

`.paengi/refs/scratch-head` is a mutable, non-content-addressed ref.  Its
canonical Profile-1 record is:

```text
mutable-ref-v1 = [1, generation, target-object-id-or-null, checksum]
checksum = SHA-256("paengi:mutable-ref:v1\\000" || encode([1, generation, target]))
```

`scratch-head` requires a non-null Checkpoint target.  `.paengi/refs/retention-head`
uses the same record and may have a null Retention_change target.  The checksum
is integrity verification, not an object identity.  Ref targets are typed by
the named-ref API; raw 32-byte payloads are not interchangeable at call sites.

Ref publication is compare-and-swap:

1. Exclusively create `.paengi/locks/<ref>.lock` as the repository-local
   single-writer lock.
2. Read and verify the existing ref, then compare its exact expected record.
3. Write the next generation to a uniquely named same-directory temporary file,
   fsync, and close it.
4. Atomically rename it over the mutable ref and fsync the refs directory where
   supported.
5. Remove the lock and fsync the locks directory where supported.

A mismatch returns a structured concurrent-update error.  Immutable objects
continue to use ADR-020 hard-link no-replace publication; rename-over is used
only for mutable refs.  A crash can leave a stale lock.  Paengi does not remove
it automatically because ownership cannot be proved safely; operators inspect
the ref and process state, then remove only the stale lock.  Directory-fsync
unsupported filesystems have the same documented weaker durability guarantee as
ADR-020.

The canonical timeline is the verified parent chain from `scratch-head`.
Optional timeline/path indexes are disposable caches, excluded from canonical
state and recovery.  A missing or corrupt cache is ignored and traversal falls
back to the parent chain.  Traversal is newest-to-oldest ancestry order,
bounded by a caller limit and optionally starts at an explicit checkpoint.

Restore scans first and creates a durable safety checkpoint for a differing
working state before it prepares a plan.  The plan is bound to that scanned
snapshot and is checked by an immediate rescan before writes.  Every write path
uses validated components and non-symlink parent checks.  The completed tree is
rescanned and must equal the target snapshot before the target becomes the
scratch head.  A restore is not claimed crash-atomic: a failed filesystem write
may leave partial working-tree changes, but the safety checkpoint remains
available and the error reports this recovery path.  The only permitted
pre-apply head advancement is publication of that safety checkpoint; a failed
restore never advances the head to its requested target.

## Consequences

- Scratch records, retention edits, and refs have independent lifecycle and
  verification rules.
- Snapshot IDs remain purely snapshot-content identities; event/checkpoint
  timestamps cannot affect them.
- Timelines remain recoverable without a database, at the cost of bounded
  parent-chain reads.
- Automatic recovery from a stale writer lock is deliberately manual and
  documented rather than guessing process ownership.
- Populated-directory restore reports partial-failure risk instead of claiming
  transactional filesystem replacement.

## Model and invariant impact

- `Event.id`, `Checkpoint.id`, `Retention_change.id`, `Snapshot.id`, and
  `Mutable_ref.t` are opaque and type-distinct.
- `apply(parent-state, event.operations) = event.resulting-snapshot-state`.
- A non-initial checkpoint and its event agree on parent/base/result snapshots.
- A successful scratch-head CAS names a fully persisted checkpoint; failed
  object publication or CAS leaves the prior head unchanged.
- Effective pin state is derived from immutable retention changes, never a
  checkpoint rewrite.
- Timeline order is ancestry order, never timestamp order.

## Persistent-format and migration impact

This additively assigns Envelope-1 object type code `15` to
`Retention_change`; existing codes and all Milestone 0/1 bytes stay unchanged.
Scratch Event v1 and Scratch Checkpoint v1 use their already reserved type
codes `4` and `5`.  Repositories created before Milestone 2 have no scratch
refs; the first initial checkpoint creates the additive `refs/` and `locks/`
directories and `scratch-head`.  No object is rewritten and no migration is
required.  Future schema changes require retained v1 readers and fixtures plus
a new ADR; canonical indexes remain outside this compatibility surface.

## Verification

- Golden bytes for event, checkpoint, retention-change, and mutable-ref v1.
- Unit and deterministic generated tests for differ/replay, structural checks,
  CAS, ref corruption, pin immutability, bounded timeline traversal, and
  restart.
- Failure tests for object publication, stale/corrupt refs, missing/cyclic
  record chains, failed restore, and external mutation after planning.
- State-machine tests for scan, checkpoint, restore, pin, unpin, and reopen.
- Watch tests for debounce, unchanged snapshots, clean stop, and scanner error
  reporting; no timing threshold is a correctness test.

## CLI and user impact

Milestone 2 exposes only `init`, `checkpoint`, `timeline`, `restore`, `pin`,
`unpin`, and explicit local `watch`.  Timeline output includes deterministic
ancestry position and effective retention.  Restore dry runs display a plan and
normal restore errors identify any durable safety checkpoint.  No capsule,
compaction, Git, network, semantic, signing, or UI command is introduced.
