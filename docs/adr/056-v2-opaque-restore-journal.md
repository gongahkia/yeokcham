# ADR-056 — V2 opaque restore journal

- Status: Superseded by ADR-073
- Date: 2026-08-09
- Deciders: maintainer (approved V2-01 continuation)
- Supersedes: None
- Superseded by: ADR-073
- Governing issue: [#138](https://github.com/gongahkia/yeokcham/issues/138)
- Related issues: [#136](https://github.com/gongahkia/yeokcham/issues/136), [#145](https://github.com/gongahkia/yeokcham/issues/145)

## Context and problem statement

ADR-055 provides immutable exact scratch snapshots and a causal publication
step. V2-016 must eventually replace a working tree with a selected exact
snapshot while retaining a recoverable, inspectable account of its progress.
The existing object-publication transaction journal cannot describe filesystem
action progress, and putting a restore plan's paths or plaintext bytes in an
unencrypted journal would violate the V2 object confidentiality boundary.

The journal must state only the minimum durable facts needed to resume or
report a restore. It cannot select a divergent causal head, declare an
unverified working tree safe, or make a restoration action happen.

## Decision drivers

- Require an immutable, canonical progression before any destructive adapter is
  introduced.
- Retain only opaque object references and public identifiers in the unencrypted
  journal directory.
- Bind restore progress to a prior safety publication and a target exact
  snapshot without storing a second plaintext copy.
- Make every legal state transition explicit and bounded.
- Preserve the approved development-only policy: no raw prior-format reader or
  migration is required before user repositories exist.

## Considered options

### Store the full restore plan in a journal file

The plan contains paths, file bytes, and raw symlink targets. Persisting it
outside the encrypted object store would expose canonical plaintext and create
a second recovery source. It is rejected.

### Mutate one restore-progress file in place

An overwrite leaves no immutable record of the prior durable phase and makes a
crash boundary ambiguous. It is rejected.

### Append opaque generation records

Each record names verified immutable snapshot objects and one safety event,
then advances by a legal generation and phase transition. The actual action
plan is re-derived from the named exact snapshots. It is selected.

## Decision outcome

`restore-journal-v2` is canonical CBOR:

```text
Restore_journal = [version=2, repository-id, operation-id,
                   safety-event-id, target-event-id,
                   safety-snapshot-ref, target-snapshot-ref, generation,
                   phase-code, completed-actions, action-count,
                   mandatory-features]

phase-code = 0 Prepared | 1 Applying | 2 Materialized | 3 Published
```

All IDs and references are exactly 32 raw bytes. `operation-id` uses the V2
transaction identity type only as an opaque local operation name; it is neither
an ADR-049 object-publication transaction nor authorization. Safety and target
references must differ. `target-event-id` retains the caller-selected signed
target source so restart can re-verify its device scope and exact target
reference. `action-count` is positive and bounded. Mandatory features start at
zero; unknown mandatory bits reject.

The initial record is generation zero and `Prepared`. A next immutable
generation may only be:

```text
Prepared       -> Applying(0)
Applying(n)    -> Applying(n + 1), where n + 1 <= action-count
Applying(count)-> Materialized
Materialized   -> Published
```

`Applying(0)` is the durable boundary before the first destructive action; an
effectful adapter will append `Applying(n + 1)` only after action `n + 1`
completes. `Materialized` requires every action complete. `Published` means a
later adapter has published and verified the post-restore scratch result. The
codec and store perform no checkpoint publication, filesystem mutation,
recovery action, or cleanup.

Each record's V2 journal path is exactly:

```text
restore-<64-lowercase-hex-operation-id>-<16-lowercase-hex-generation>.cbor
```

The fixed-width nonnegative generation makes lexical and numeric order agree.
The store validates both filename/payload identity and every per-operation
successor relation, creates the final path by hard link from a fsynced private
temporary file, and fsyncs the containing directory. An existing identical
record is an idempotent retry; different bytes at the same path are a collision.
The root validator accepts only valid transaction and restore records in the
shared journal namespace.

The preparation service resolves the target from a caller-named signed event in
the local device scratch scope; it never chooses a causal head. For a changed
scan it causally publishes the exact observed snapshot as the safety checkpoint
before it writes this journal's `Prepared` and `Applying(0)` records. A
previously named operation is reported for explicit recovery rather than being
silently continued. Equal target and observed snapshots create neither safety
checkpoint nor restore journal.

## Consequences

- The implemented restore store create-only names every generation and rejects
  a collision rather than overwriting recovery state.
- Resume derives the action plan from encrypted snapshots instead of trusting
  raw journal plaintext.
- The raw journal leaks operation progress and opaque identifiers to local disk
  readers but no file path, file content, symlink target, or private key.
- The materialiser accepts `Applying(n)`, proves its pure replay, requires the
  exact pure prefix `n` before writes, rejects metadata paths and symlinked
  parents, fsyncs each action, and appends one `Applying(n)` record only after
  action `n` completes. It verifies the final exact target scan before
  `Materialized`.
- The preparation boundary publishes a safety checkpoint even when an external
  caller later declines or fails to materialise; that durable state is the
  intentional recovery anchor, not a partial destructive action.
- An interruption after a filesystem action but before its progress record
  intentionally leaves that action's physical result with the prior durable
  journal generation. On an explicit retry, the adapter may append exactly the
  next generation only when the root exactly equals the corresponding next pure
  prefix. Any other state rejects rather than being interpreted as progress.
- The recovery service re-resolves both named events in the signed local
  scratch scope and requires their snapshot references to retain the journal's
  bindings. It rechecks the materialized root before causal post-restore
  publication, accepts a post-publication crash only when the current checkpoint
  is exactly the target snapshot, and then appends `Published`. It never picks
  an alternate scratch head.

## Model and invariant impact

```text
Restore_phase = Prepared | Applying(completed-actions)
              | Materialized | Published
Restore_record = (repository, operation, safety-event, target-event,
                  safety-snapshot, target-snapshot, generation, phase,
                  action-count)
```

1. Non-no-op restoration has a positive bounded action count, distinct
   safety/target opaque references, and two explicit signed-event identities.
2. `Prepared` occurs only at generation zero with zero completed actions.
3. Progress stays in `0..action-count`; terminal phases require completion.
4. A record can only advance through the listed transition relation.
5. Re-decoding and re-encoding retain exactly the same bytes.
6. The record supplies no causal-head selection, user authorization, intent,
   filesystem contents, or recovery authority by itself.
7. Recovery re-verifies both source events and their snapshot references before
   it applies or publishes a plan.

## Persistent-format and migration impact

The journal is a version-2, bounded canonical CBOR record in a private
`.yeokcham/journal` create-only generation chain. It carries only opaque/public
values and is not an ADR-045 encrypted object. The static golden fixture covers
the initial record. Unknown schema versions/features, invalid IDs, equal
snapshot references, impossible phase/progress combinations, noncanonical
bytes, trailing bytes, oversized inputs, malformed paths, file/payload identity
mismatches, invalid chain successors, and non-regular temporary entries fail
closed. Version 2 deliberately replaces the earlier uncommitted development
shape so target-event provenance can be re-verified. No V1 reader, migration,
or compatibility fixture is retained under the approved no-user-data
development policy.

## Verification

- Unit tests cover the exact initial golden, all legal phases, illegal skips,
  equal references, invalid features/progress, trailing bytes, and bounds.
- Seeded generated traces cover positive action counts and prove every legal
  final journal decodes and re-encodes canonically.
- Store tests cover create-only retry/collision behavior, reopening, root
  validation, stale regular temporary handling, non-regular temporary
  rejection, missing predecessors, repository mismatch, and generated durable
  chains.
- Preparation tests cover signed explicit target lookup, no-op behavior, exact
  safety publication before durable `Applying(0)`, reused-operation reporting,
  and generated changed scans. No filesystem mutation is performed by this
  layer.
- Materialiser tests cover exact bytes, executable modes, paths, and raw
  symlink targets; stale pre-write scans; deterministic post-write/pre-journal
  interruptions; durable per-action generations; explicit one-prefix recovery;
  and 60 seeded generated target and interruption-reconciliation cases.
- Authenticated-recovery tests cover post-write restart publication, external
  root rejection, forged target-event/reference rejection, idempotent published
  resume, and 60 seeded interrupted restore-to-publication cases.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` are required.

## CLI and user impact

No CLI is introduced in this slice. A future status command may render the
typed phase, operation ID, and opaque references after opening the local
bootstrap, but it must not imply that a record authorizes automatic conflict
resolution or a destructive retry.
