# ADR-090 — V4 durable restore proofs

- Status: Accepted
- Date: 2026-08-30
- Deciders: maintainers
- Implements: [#247](https://github.com/gongahkia/yeokcham/issues/247)
- Supersedes: ADR-081 only for completed in-place restore retention

## Context

ADR-081 correctly bounded anonymous scratch checkpoints, but its completed
restore journal was the sole named recovery root. A successful compaction
deleted that journal, so the safety snapshot captured before an in-place
restore could cease to be reconstructible in the timeline immediately. That
is inconsistent with an explicit destructive restore: the user asked to
replace their tree and must not need to predict a later compaction to preserve
the tree being replaced.

## Decision

Every completed in-place restore creates a local immutable
`restore-proof-v1` before its journal reaches `Published`. The exact canonical
record is:

```
[1, operation-id, safety-snapshot-id, target-snapshot-id]
```

It is stored create-only at
`.yeokcham/restore-proofs/v4-restore-proof-<operation-id>.cbor`. It names no
paths, content bytes, credentials, intent, shared history, or transport data.
It is not included in a package, bootstrap basis, relay publication, or
project-state record.

Both named snapshot closures are loaded before the proof is written. A proof
and a journal record are fsynced with their containing directory after a
create or delete operation. This follows the Linux `fsync(2)` durability rule:
syncing a file alone does not make its directory entry durable; the containing
directory must also be synced. [fsync(2)](https://man7.org/linux/man-pages/man2/fsync.2.html)

Compaction keeps every proof's safety and target snapshots regardless of the
recent-scratch count. It may prune a `Published` journal only after it finds a
matching proof. A legacy published journal without a proof remains a
compaction root until `yeokcham restore retain --operation ID` validates it
and creates one. `yeokcham restore forget --operation ID` is the only command
that removes this durable root; it removes the proof, not immutable objects or
working-tree bytes.

## Consequences

`restore --checkpoint` without `--destination` now returns a recovery proof
operation ID. `restore proofs` lists local proofs, and `storage roots` validates
and explains every non-recent compaction root. A corrupt proof, missing
snapshot closure, or root not retained by the state rejects inspection and
compaction before a state-head write.

This is deliberately stronger than bounded scratch retention but deliberately
weaker than an archive or release mechanism: it protects only the two exact
snapshots of an explicit destructive restore and has an explicit user removal
path. It does not introduce object garbage collection, retention timestamps,
automatic expiry, remote recovery, a clone protocol, or a new trust/history
category.

## Verification

- canonical `restore-proof-v1` golden fixture and malformed-record tests;
- generated/model compaction coverage for proof roots;
- in-place restore then compaction proves its safety survives after journal
  pruning, and explicit forget permits later compaction;
- legacy published journals stay protected until explicit retain;
- corrupt proof and missing/invalid closure paths reject before state mutation;
- restart from an incomplete journal completes the proof before publication.
