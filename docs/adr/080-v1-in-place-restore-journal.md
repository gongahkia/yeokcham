# ADR-080 — V1 in-place restore journal

- Status: Accepted
- Date: 2026-08-27

## Context

V1 can copy a retained checkpoint into an empty directory, but that does not
complete the `saved` promise for the active project tree. Replacing that tree
can destroy unsaved bytes or leave a partially materialized tree after process
or host interruption.

V1 is the only product model governed by this decision. Existing generic exact
snapshot and immutable object-store components remain implementation
substrates; prior Yeokcham journal, ledger, encryption, and authority semantics
do not define this format.

## Decision drivers

- Publish an exact safety checkpoint before the first destructive action.
- Keep journal generations immutable, canonical, versioned, and path-free.
- Make interrupted replacement safely repeatable from named snapshots.
- Preserve `.yeokcham` and `.git` as non-source metadata.
- Keep recovery separate from sharing, decisions, and delivery.

## Considered options

### Replace the tree after an in-memory safety scan

Rejected. A crash can lose both the previous bytes and knowledge of the
operation.

### Mutate one progress record in place

Rejected. It makes the durable crash boundary ambiguous and violates the rule
that the only record is never overwritten.

### Append immutable generations around idempotent replacement

Selected. V1 retains the current snapshot in project state, then appends
`Prepared`, `Applying`, `Materialized`, and `Published` generations. Recovery
re-derives the target tree and repeats replacement when the latest generation
is `Applying`.

## Decision

The canonical V1 restore journal is a six-field CBOR array:

```text
[version=1, operation-id, safety-snapshot-id, target-snapshot-id,
 generation, phase-code]
```

The operation ID is 32 bytes rendered as 64 lowercase hexadecimal characters.
Safety and target IDs must differ. Generation and phase code are equal and
advance from zero through three:

```text
0 Prepared -> 1 Applying -> 2 Materialized -> 3 Published
```

Every generation is create-only under `.yeokcham/journal`. Equal existing
bytes are an idempotent retry; different bytes at the same path are corruption.
Before `Prepared`, the safety snapshot is stored and published as a retained V1
checkpoint. `Applying` removes all root entries except `.yeokcham` and `.git`,
then materializes the exact target. `Published` follows publication of the
target as the active draft checkpoint.

## Consequences

In-place restore can recover pre-restore bytes and resume an interrupted
replacement. Repeating `Applying` is destructive only after the safety
checkpoint is durable. The journal does not claim filesystem transaction
atomicity; it provides deterministic recovery from partial application.

The V1 project-state schema is unchanged. Journal schema version 1 has a golden
fixture. There is no migration from prior Yeokcham versions and no prior V1
journal format to migrate.

Compaction must treat snapshots named by all restore generations as protected
roots. Journal pruning is deferred to the compaction slice.

## Verification

- golden-byte and canonical decode tests for `Prepared`;
- unit tests for legal and illegal phase transitions;
- exact in-place restore with recoverable unsaved bytes;
- preservation of `.yeokcham` and `.git`;
- interrupted-`Applying` resumption;
- CLI journey coverage for in-place restore and reported safety identity.
