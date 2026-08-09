# ADR-056 — V2 opaque restore journal

- Status: Accepted
- Date: 2026-08-09
- Deciders: maintainer (approved V2-01 continuation)
- Supersedes: None
- Superseded by: None
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

`restore-journal-v1` is canonical CBOR:

```text
Restore_journal = [version=1, repository-id, operation-id,
                   safety-event-id, safety-snapshot-ref, target-snapshot-ref,
                   generation, phase-code, completed-actions, action-count,
                   mandatory-features]

phase-code = 0 Prepared | 1 Applying | 2 Materialized | 3 Published
```

All IDs and references are exactly 32 raw bytes. `operation-id` uses the V2
transaction identity type only as an opaque local operation name; it is neither
an ADR-049 object-publication transaction nor authorization. Safety and target
references must differ. `action-count` is positive and bounded. Mandatory
features start at zero; unknown mandatory bits reject.

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
codec alone performs no journal-directory write, scan, checkpoint publication,
filesystem mutation, recovery, or cleanup.

## Consequences

- A future restore store can create-only name every generation and reject a
  collision rather than overwriting recovery state.
- Resume derives the action plan from encrypted snapshots instead of trusting
  raw journal plaintext.
- The raw journal leaks operation progress and opaque identifiers to local disk
  readers but no file path, file content, symlink target, or private key.
- A later adapter must still verify that the safety event and snapshot
  references are valid in the selected repository before applying anything.

## Model and invariant impact

```text
Restore_phase = Prepared | Applying(completed-actions)
              | Materialized | Published
Restore_record = (repository, operation, safety-event, safety-snapshot,
                  target-snapshot, generation, phase, action-count)
```

1. Non-no-op restoration has a positive bounded action count and distinct
   safety/target opaque references.
2. `Prepared` occurs only at generation zero with zero completed actions.
3. Progress stays in `0..action-count`; terminal phases require completion.
4. A record can only advance through the listed transition relation.
5. Re-decoding and re-encoding retain exactly the same bytes.
6. The record supplies no causal-head selection, user authorization, intent,
   filesystem contents, or recovery authority by itself.

## Persistent-format and migration impact

The journal is a version-1, bounded canonical CBOR record intended for a
private `.yeokcham/journal` create-only generation chain. It carries only
opaque/public values and is not an ADR-045 encrypted object. The static golden
fixture covers the initial record. Unknown schema versions/features, invalid
IDs, equal snapshot references, impossible phase/progress combinations,
noncanonical bytes, trailing bytes, and oversized inputs fail closed. No old
format reader, migration, or compatibility fixture is retained under the
approved no-user-data development policy.

## Verification

- Unit tests cover the exact initial golden, all legal phases, illegal skips,
  equal references, invalid features/progress, trailing bytes, and bounds.
- Seeded generated traces cover positive action counts and prove every legal
  final journal decodes and re-encodes canonically.
- Before a journal store is complete, add create-only collision, crash, retry,
  stale-generation, and recovery tests.
- Before a filesystem adapter is complete, add injected-write-failure and
  exact re-scan/safety-publication tests.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` are required.

## CLI and user impact

No CLI or filesystem operation is introduced in this format-only slice. A
future status command may render the typed phase, operation ID, and opaque
references after opening the local bootstrap, but it must not imply that a
record authorizes automatic conflict resolution or a destructive retry.
