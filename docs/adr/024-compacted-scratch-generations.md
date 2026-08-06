# ADR-024 — Compacted scratch generations

- Status: Accepted
- Date: 2026-07-30
- Deciders: maintainer (Milestone 3 direction)
- Supersedes: None
- Superseded by: None

## Context and problem statement

`Scratch_checkpoint_v1` and `Scratch_event_v1` form an immutable parent chain.
The current scratch head therefore reaches all old ancestry, preventing safe
physical compaction.  Rewriting either record, `scratch-head`, or
`retention-head` would violate ADR-023 and invalidate externally held
checkpoint IDs.

## Decision drivers

- Preserve logical checkpoint IDs, exact snapshots, and immutable v1 records.
- Permit a retained timeline to use short, independently verified chains.
- Make activation CAS-protected and interruption-safe.
- Keep deletion conservative, inspectable, and resumable.

## Considered options

### Rewrite retained checkpoint records

- Direct traversal needs no resolver.
- Mutates immutable content-addressed history and changes checkpoint IDs.

### Keep all ancestry and only delete shared content

- Requires little new metadata.
- Does not compact scratch ancestry and risks cross-domain objects.

### Immutable compacted generation with logical aliases

- Retains logical IDs while using new physical checkpoint objects.
- Adds resolver and generation-format complexity without changing ADR-023.

## Decision outcome

Use an active immutable `Scratch_generation_v1`, named by the new mutable
`refs/scratch-generation` ref.  The ref uses unchanged ADR-023 mutable-ref v1
bytes and publication rules.  A missing ref means legacy direct resolution.

Generation payloads are Envelope-1 objects with additive type codes 16–18:

```text
scratch-generation-segment-v1 = [1, [* generation-entry-v1]]
generation-entry-v1 = [
  logical-checkpoint-id,
  physical-checkpoint-id,
  snapshot-id,
  previous-retained-logical-checkpoint-id-or-null,
  [* effective-retention-reason-v1]
]

scratch-cleanup-manifest-v1 = [1, [* cleanup-candidate-v1]]
cleanup-candidate-v1 = [stored-object-id, expected-object-type-code]

scratch-generation-v1 = [
  1,
  previous-generation-id-or-null,
  source-scratch-head-id,
  source-scratch-head-ref-generation,
  source-retention-head-id-or-null,
  source-retention-head-ref-generation-or-null,
  retention-policy-v1,
  [* ordered-generation-segment-id],
  compacted-physical-head-id,
  retention-cutoff-id-or-null,
  cleanup-manifest-id
]
retention-policy-v1 = [recent-window-seconds, periodic-interval-seconds,
                       storage-budget-bytes-or-null]
```

Entries are oldest-to-newest and segment size is bounded at 128 entries.
Segment IDs appear in root order; each entry binds its predecessor logical ID,
so validation never depends on wall-clock ordering.  IDs are exactly 32 raw
bytes.  Arrays have exact arity, segments are nonempty/bounded, entries are
strictly ordered by predecessor linkage, mappings are unique, and each
physical target is a direct Checkpoint object rather than another alias.

During construction, retained snapshots are connected with exact generated
Scratch_event v1 transitions.  The earliest retained entry has an initial
physical checkpoint.  Later physical event/checkpoint parents name the prior
*logical* retained ID; generation-aware resolution expands that parent to its
direct physical mapping.  User-visible IDs and `scratch-head` remain logical.

The generation stores effective retained reasons and the source
`retention-head` as a cutoff.  Resolution starts with this base and applies
only immutable changes newer than the cutoff.  New pin/unpin operations retain
the ADR-023 `Retention_change_v1` log and CAS ref.

M3-D01 makes the already-encoded optional storage budget effective during
planning without changing `retention-policy-v1`. The budget charges only the
exact source-object file lengths of each selected Checkpoint and direct
Scratch_event; shared snapshot/content-domain objects remain outside the scope
until a complete cross-domain root mark exists. Pins and the logical
scratch-head requirement are never evicted. Optional recent checkpoints, then
periodic checkpoints, are considered newest-first with object-ID ties; a
nonfitting candidate is reported as `budget-excluded`. A protected-only
overrun remains visible rather than making a recovery state unavailable.

Publication obtains the repository compaction lock, reads source refs and the
active generation, publishes all immutable generation objects, verifies them,
rereads sources, then CAS-publishes `scratch-generation`.  It does not advance
scratch-head or retention-head.  A pre-activation crash leaves unreachable
objects only; a post-activation/pre-cleanup crash leaves valid excess history.

The cleanup manifest only permits superseded scratch events, scratch
checkpoints, and retention changes strictly older than the retained cutoff.
Content, Tree, Snapshot, Chunk, and File_manifest objects are never candidates
until a complete cross-domain root mark exists.  Candidates are rechecked
against the active generation, manifest, expected type, and keep set before an
atomic same-filesystem move to `.paengi/trash/<generation-id>/`.  Quarantine is
idempotently resumable.  Explicit prune permanently removes quarantined files;
previous history is not recoverable after prune.

## Consequences

- Logical checkpoint identity remains stable while physical checkpoint IDs may
  differ.
- Resolver failures are structured: corrupt generation, missing/wrong alias
  target, snapshot mismatch, alias cycle, and checkpoint-not-retained.
- Old generation roots are retained through `previous-generation-id`; this is
  conservative and can limit reclamation across repeated generations.
- Directory fsync support continues to bound crash-durability guarantees.

## Model and invariant impact

- Active mappings are direct logical-to-physical checkpoint mappings.
- Every retained logical checkpoint resolves to its declared exact snapshot.
- Compacted replay reaches every retained snapshot in declared order.
- Timeline order is predecessor order, not timestamp order.
- A failed activation cannot change repository meaning.
- Cleanup cannot delete active generation objects, active physical checkpoints
  or events, retained snapshots, current logical head state, or shared content.

## Persistent-format and migration impact

The change is additive: object types 16–18 and `scratch-generation` are new.
ADR-020 through ADR-023 bytes and schemas are unchanged.  Legacy repositories
without the ref remain supported.  Existing objects are never rewritten;
generation activation is the migration boundary.  Quarantine can be restored
manually before explicit prune; permanent prune has no rollback guarantee.

## Verification

- Canonical goldens and inverse decoders for all three object schemas and the
  generation ref.
- Deterministic retained-state, replay, resolver, race, corruption, repeated
  generation, cleanup-resume, and planner-versus-actual tests.
- Failure injection before activation and after activation before cleanup.
- Existing ADR-020 through ADR-023 fixtures remain byte-identical.

## CLI and user impact

`paengi compact --dry-run`, `paengi compact`, `paengi compact --resume`, and
`paengi compact --prune` expose planning, activation, quarantine, resume, and
irreversible pruning.  Timeline, restore, retention, and checkpoint creation
continue to display and accept logical checkpoint IDs.
