# ADR-025 — Durable capsules and revisions

- Status: Accepted
- Date: 2026-07-30
- Deciders: maintainer (approved continuation of Milestone 4 on 2026-07-30)
- Supersedes: None
- Superseded by: None

## Context and problem statement

Milestone 4 has a pure capsule model, exact transition application,
checkpoint-range drafts, and in-memory revision history. It has no durable
Capsule or Capsule_revision schema, canonical revision resolver, or
compare-and-swap current revision. Existing Envelope-1, object-store, scratch,
retention, and compaction formats are accepted contracts and cannot change.

## Decision drivers

- Keep stable logical capsule identity distinct from immutable logical revision
  identity and physical Envelope-1 object identity.
- Preserve independently applicable complete revisions and exact byte/mode
  preconditions.
- Publish a capsule only after all immutable objects and required scratch pins
  exist.
- Reject stale writers and divergent logical-ID reuse.
- Keep all history reconstructible from immutable parent links and current refs,
  not a mutable catalog.

## Considered options

### Store mutable revision state in Capsule_v1

- Makes current revision lookup local to one object.
- Violates immutable object identity and requires rewriting a capsule.

### Use only Stored_object_id identities

- Reuses ADR-020 directly.
- Loses the stable logical capsule/revision identities required by the model.

### Add immutable capsule and complete-revision objects with a current ref

- Separates stable logical IDs, immutable revision history, and mutable current
  selection.
- Requires codecs, direct logical-to-physical links, canonical refs, and
  recovery tests.

## Decision outcome

Add immutable Envelope-1 objects of existing reserved types `Capsule = 6` and
`Capsule_revision = 7`. No existing object type, payload, ref, object ID, or
golden fixture changes.

`Capsule_id` is an opaque caller-supplied exactly-32-byte value. The pure model
already accepts it as an input; it is deliberately not derived from title,
description, checkpoint boundaries, or current revision. The imperative CLI or
future UI must obtain a fresh value outside the canonical model.

`Capsule_revision_id` is exactly:

```text
SHA-256("yeokcham:capsule-revision:v1\000" || encode(revision-identity-v1))
```

where `encode` is Profile 1 and `revision-identity-v1` contains the capsule ID,
optional parent revision link, declared base snapshot, expected result snapshot,
ordered operations, canonically sorted unique dependencies, ordered source
checkpoint boundaries, and provenance. It excludes its own revision ID,
creation timestamp, and validation evidence timestamps/durations. Envelope
stored-object identity remains ADR-020 over the complete Envelope-1 bytes,
including observational metadata. A logical revision link therefore always
contains both its logical revision ID and typed physical `Stored_object_id`.

All `*_id` raw values below are exactly 32 bytes. Every payload has version `1`;
Envelope-1 retains object-format version `1` and mandatory feature mask `0`.

```text
capsule-v1 = [
  1,
  capsule-id,
  created-at-unix-seconds,
  initial-title-text,
  initial-description-text
]

revision-link-v1 = [capsule-id, capsule-revision-id, revision-stored-object-id]
parent-link-v1 = [capsule-revision-id, revision-stored-object-id]
source-boundary-v1 = [from-checkpoint-id, to-checkpoint-id]

capsule-revision-v1 = [
  1,
  capsule-id,
  capsule-revision-id,
  parent-link-v1-or-null,
  declared-base-snapshot-id,
  expected-result-snapshot-id,
  [* change-operation-v1],
  [* dependency-v1],
  [* validation-evidence-v1],
  [* source-boundary-v1],
  provenance-v1,
  created-at-unix-seconds
]
```

Operations retain their pure-model exact entry/content/mode preconditions.
Operation order is significant and preserved. A textual edit stores its text
anchor, replacement bytes, and exact fallback; application returns an explicit
fallback-required conflict until the caller selects that fallback. Dependencies
and validation evidence are unordered sets: their encoded entries are strictly
bytewise ascending and unique. Boundaries retain explicit source order.

Every durable revision has an expected result snapshot and is complete: it
applies directly from its declared base snapshot without replaying parents.
Parent links serve provenance and history only. The payload decoder verifies its
logical revision ID preimage and canonical bytes; the repository resolver then
verifies object type, parent object/type/capsule agreement, operation replay,
and direct expected result.

The only mutable capsule state is:

```text
.yeokcham/refs/capsules/<lowercase-capsule-id-hex>/current

capsule-current-ref-v1 = [
  1,
  generation,
  capsule-id,
  capsule-stored-object-id,
  current-capsule-revision-id,
  current-revision-stored-object-id,
  checksum
]

checksum = SHA-256(
  "yeokcham:capsule-current-ref:v1\000" ||
  encode([1, generation, capsule-id, capsule-object, revision-id, revision-object])
)
```

The generation is non-negative and strictly increases on each successful
replacement. The ref uses a per-capsule repository lock, verified expected raw
bytes, unique same-directory temporary file, file fsync, rename-over, directory
fsync where supported, and lock release. A stale expected ref returns a
structured concurrent-update error; no last-writer-wins path exists. Capsule
listing may enumerate validated `refs/capsules/<hex>/current` directories; any
catalog or index is rebuildable and non-canonical.

Creation holds the capsule writer lock, validates range ancestry, derives and
replays exact operations, publishes Capsule_v1 and complete initial
Capsule_revision_v1, adds/verifies every required `Capsule_boundary` retention
change, then CAS-writes an expected-absent current ref. The ref is the sole
visibility point. Pre-ref crashes leave only unreachable immutable objects and
possibly extra safe pins; post-ref crashes resolve a complete capsule. Retry is
idempotent for byte-identical objects/pins/ref and rejects conflicting capsule
ID reuse.

Creation from the current working directory is an adapter over that same range
path, not a separate working-diff object. It holds the repository writer lock,
reads the verified scratch head, scans the directory twice, and rejects if the
two exact snapshots differ. An equal snapshot returns a structured no-change
result and publishes nothing. A verified difference first publishes the normal
scratch event/checkpoint, then uses the old head and new checkpoint as the
range. Thus a failure before the current ref leaves work recoverable in scratch
history but exposes no partial capsule; the existing durable boundaries identify
the same-input retry path without a new persistent attempt record.

Enabling a single capsule for editing resolves and directly validates its
current complete revision, then uses the existing guarded scratch restore path
against that revision's expected-result snapshot. Divergent work is safety
checkpointed first. The exact target event/checkpoint is staged from the safe
head and becomes `scratch-head` only after guarded materialisation and rescan
verification. If that verified state is already the current scratch head, the
head is the editing anchor and no duplicate checkpoint is made. This adds no
workspace or edit-session ref; folding retains its existing explicit
checkpoint-range and current-ref-CAS protocol.

Folding holds the same lock, verifies the current ref and selected range begins
at the current revision result, derives extra exact operations, creates a new
complete revision from the original declared base to the new expected result,
publishes/pins/verifies it, rechecks the old ref, then CAS-updates current. A
failed CAS leaves harmless unreachable immutable data; the old revision remains
addressable.

Split uses a deterministic ordered chain: the first new capsule starts
at the source revision base and reaches an explicitly replayed intermediate
snapshot; the second new capsule declares that intermediate snapshot as base,
requires the first exact revision, and reaches the source result. Both source
output capsules are new immutable objects; the source remains unchanged. Partitions
that cannot validate this chain reject. Combine accepts an explicit
already-compatible source order whose base/result chain replays exactly; it
creates one new complete capsule revision and retains all source links in
provenance. It never silently concatenates incompatible operations.

Split and combine hold the repository writer lock and publish each output's
immutable objects and boundary pins before that output's current ref. There is
no multi-ref transaction: a crash can leave zero, one, or all output refs, but
every visible output is individually complete and resolvable, and sources are
unchanged. Retrying with the same output IDs is idempotent only for identical
objects/refs; divergent output-ID reuse rejects.

Split and combine first expose a deterministic, read-only plan. It includes
source logical/physical IDs, selected operation indices or exact source order,
output count, declared bases/results, dependencies or composition order,
provenance, and boundary pins. A CLI publication needs `--confirm`; absence of
that acknowledgement returns a non-zero result after the plan and publishes
nothing. Confirmed execution holds the writer lock and recomputes the plan from
the resolved immutable inputs immediately before publication.

## Consequences

- Stable capsule IDs never change as revisions are folded.
- Logical revision IDs describe canonical application semantics; stored IDs bind
  the full observed immutable record.
- Refs provide direct current resolution, while history needs no mutable index.
- Title/description edits, split, and combine need later immutable revisions or
  new capsule records; they are never in-place changes.
- Directory fsync unsupported filesystems retain the ADR-020/ADR-023 weaker
  crash-durability limitation.

## Model and invariant impact

- Capsule dependencies belong to revisions, not Capsule_v1.
- A parent revision link records both logical and physical IDs and resolves only
  to a same-capsule Capsule_revision_v1.
- The current ref's IDs and objects must resolve to matching Capsule_v1 and
  Capsule_revision_v1 records.
- Durable revision replay from declared base reaches its expected result or
  returns an explicit structured conflict/error.
- Revision history is newest-to-oldest parent linkage with cycle detection.

## Persistent-format and migration impact

This is additive. Existing type codes 6 and 7 gain their first schemas;
ADR-020 through ADR-024 bytes, object IDs, refs, and goldens remain unchanged.
Legacy repositories simply lack `refs/capsules/`. No object is rewritten and no
migration is needed. Future schema changes require a new ADR, retained v1
readers/goldens, and coexistence or an atomically published migration.

## Verification

- Golden and inverse-decoder tests for Capsule_v1, Capsule_revision_v1, and the
  capsule current ref.
- Unit/property/state-machine tests for creation, reopen, resolver, exact
  replay, current diff, history, folding, stale CAS, retries, corrupt/wrong
  links, pins, and rebuildable-index absence.
- Failure injection before and after current-ref publication and before folding
  ref replacement.
- Existing ADR-020 through ADR-024 goldens remain byte-identical.
- Split/combine replay, invalid partition, and incompatible composition tests
  cover the implemented deterministic chain model.
- Parent-cycle coverage injects a synthetic logical graph into the pure
  `Parent_resolver` seam. Persistent wrong-ID, corrupt, missing-parent,
  wrong-type, and cross-capsule-parent cases remain separate. A valid
  hash-verifying cyclic immutable-object fixture is cryptographically
  impractical and is not required to preserve the production cycle invariant.

## CLI and user impact

`capsule show`, `capsule current-diff`, and `capsule history` report logical
capsule/revision IDs and resolve only verified immutable records. Creation and
folding never expose a partial capsule. Split/combine commands follow the
documented exact-replay model.
