# ADR-081 — V4 bounded checkpoint retention

- Status: Accepted
- Date: 2026-08-27
- Deciders: maintainers
- Supersedes: None
- Superseded by: ADR-085, for its pre-release V4 persistence-version and
  migration clauses only

## Context and problem statement

V4 restore left every save on the checkpoint timeline and left published
restore journals on disk. The product contract requires a bounded automatic
checkpoint policy that still protects snapshots named by share, delivery, pin,
open decision, or restore-safety. The object store has no delete API, and V4
checkpoints have no timestamps, so a Git-style grace window or time-based
expiry cannot be represented honestly.

## Decision drivers

- Keep named recovery roots while dropping anonymous scratch checkpoints.
- Keep pins in the one final V4 project-state schema.
- Prune only completed restore journals.
- Do not claim blob garbage collection.

## Considered options

### Time-window retention

Rejected. Checkpoints are `{ checkpoint_snapshot }` with no observation time.

### Physical object deletion

Rejected. The V4 store cannot delete objects, and concurrent readers need the
same grace Git/jj give unreachable objects. Timeline drop is the honest bound.

### Count-based extra keep plus named roots

Selected. Protected snapshots stay. Among the rest, keep the newest `N`
(default 32). Pins are explicit retained names in project state schema v3.

## Decision

Compaction rewrites only `state_checkpoints`. It never mutates the only copy in
place and never deletes CAS blobs.

Protected snapshots are:

- the delivery baseline;
- every draft `latest_checkpoint`;
- shared-revision and resolution base/result snapshots;
- delivery snapshots;
- open-decision candidate snapshots;
- explicit pins;
- safety and target snapshots named by an incomplete restore journal.

Published restore journals are deleted after a successful compact persist.
Those snapshots then remain only if another protection still names them.
Pending journals are not pruned.

`keep_recent` must be nonnegative. `--dry-run --explain` reports keep reasons
without writing state.

## Consequences

Repeated `save` no longer grows the inspectable timeline without bound. Restore
safety from a completed operation can drop on the same compact that prunes its
journal unless pinned or still recent. Object bytes may remain until a later
store GC slice.

## Model and invariant impact

`state` gains `state_pins`. Share, amend, receive, and resolve retain the
revision snapshots they name. Import rejects pins or named history snapshots
that are missing from the checkpoint list. Compact must re-import successfully.

## Persistent-format impact

The final `V4_project_state` version-1 schema includes the canonical pin array.
ADR-085 supersedes the earlier pre-release V4 decoder/migration proposal:
older encodings are rejected rather than read or re-saved.

## Verification

- unit tests that named roots and pins survive `keep_recent=0`;
- property tests that compact never drops the active draft or baseline;
- journal prune of a published chain;
- final version-1 golden bytes plus pre-release encoding rejection;
- CLI `--explain` and `pin` journey.

## CLI and user impact

`yeokcham pin`, `unpin`, and `compact [--keep N] [--dry-run] [--explain]`.
Compaction does not capture the working tree.
