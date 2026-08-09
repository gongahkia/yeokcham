# ADR-058 — V2 scratch retention and immutable generation activation

- Status: Accepted
- Date: 2026-08-09
- Deciders: maintainer (approved V2-01 continuation)
- Supersedes: None
- Superseded by: None
- Governing issue: [#137](https://github.com/gongahkia/yeokcham/issues/137)
- Related issues: [#136](https://github.com/gongahkia/yeokcham/issues/136), [#139](https://github.com/gongahkia/yeokcham/issues/139), [#140](https://github.com/gongahkia/yeokcham/issues/140), [#143](https://github.com/gongahkia/yeokcham/issues/143)

## Context and problem statement

ADR-055 stores a device's scratch checkpoints as exact snapshot targets in one
immutable causal ledger scope. That gives a recoverable current state, but an
ever-growing predecessor chain cannot be reclaimed: removing an old event
breaks causal evaluation, while keeping every event and snapshot defeats a
local quota.

V1 ADR-023 and ADR-024 cannot be ported mechanically. They depend on mutable
refs, V1 checkpoint timestamps, and records whose V2 replacements do not
exist. In particular, V2 currently has no capsule, release, or validation
record. Treating any absent record as a retention source would create an
unreviewed authority and confuse a historical V1 format with the V2 model.

The V2 foundation does have encrypted typed frames, signed causal ledger
events, exact snapshot references, local bootstrap capability, and create-only
object publication. This decision uses those primitives to create a compacted
scratch scope, then makes it active only through another causal ledger scope.
No mutable "current generation" file is introduced.

## Decision drivers

- Preserve each retained exact snapshot without rewriting it or selecting a
  divergent causal head.
- Make pins and future capsule/release boundaries explicit claims, never an
  inference from object contents or names.
- Bound current local scratch history without silently evicting protected data.
- Keep generation activation separate from recoverable physical cleanup.
- Make partial quarantine detectable and resumable; keep permanent deletion
  explicit and separately failure-tested.

## Considered options

### Reuse V1 mutable refs and timestamp policies

This would add an unapproved mutable authority and invent wall-clock checkpoint
fields. It is rejected.

### Delete old causal events in place

The current scratch head transitively depends on them. A crash or partial
delete would make the only recovery chain malformed. It is rejected.

### Re-encrypt every retained snapshot in a new chain

It preserves bytes but duplicates large exact trees and needlessly changes all
snapshot opaque references. It is rejected.

### Activate a new immutable scratch scope through a causal generation record

A compacted scope reuses each selected immutable snapshot object while issuing
new signed ledger events over those snapshots. A separate generation event is
the only activation point. It is selected.

## Decision outcome

For local bootstrap device ID `D`, V2 defines these ledger ref names:

```text
scratch-base(D)       = "scratch-" || lowercase-hex(D)
scratch-protection(D) = "scratch-protection-" || lowercase-hex(D)
scratch-generation(D) = "scratch-generation-" || lowercase-hex(D)
scratch-compact(D, H) = "scratch-compact-" || lowercase-hex(D) || "-" || H
```

`H` is the full lowercase-hex source head event ID. The ledger's 255-byte
ref-name limit admits every spelling above. Before the first generation,
`scratch-base(D)` is active. A valid sole head in `scratch-generation(D)`
targets a `Scratch_generation` frame and changes the active scope to that
frame's declared `scratch-compact(D, H)`. A missing generation scope uses the
base scope. A malformed target, unavailable active anchor, or divergent
protection/generation/scratch head is an explicit error; nothing chooses a
winner.

ADR-054 frame version 1 gains two encrypted kinds:

```text
kind = 0 Ledger_event | 1 Scratch_snapshot
     | 2 Scratch_protection | 3 Scratch_generation

scratch-protection-v1 = [
  1, snapshot-opaque-ref, action, protection-reason-v1, mandatory-features
]
action = 0 Protect | 1 Unprotect
protection-reason-v1 = [0] / [1, capsule-binding-opaque-ref]
                     / [2, release-binding-opaque-ref]

scratch-generation-v1 = [
  1, source-ref-name, source-head-event-id,
  active-ref-name, active-anchor-event-id,
  [* retired-ref-name], [* cleanup-candidate-v1], mandatory-features
]
cleanup-candidate-v1 = [opaque-object-ref, expected-frame-kind]
expected-frame-kind = 0 Ledger_event / 1 Scratch_snapshot
```

All reference byte strings are exactly 32 bytes. Reason codes are `User_pin`,
`Capsule_boundary`, and `Release_boundary`; a capsule or release binding is an
explicit opaque reference supplied by its future owner. A claim does not prove
that binding's type, authority, or reachability. It protects only the named
exact snapshot at this local retention boundary. A protection ledger chain is
folded in causal order; its latest action for an equal `(snapshot, reason)`
pair is effective. Any effective reason protects that snapshot.

The initial policy is runtime input rather than a persistent record:

```text
Retention_policy = (recent-count >= 0, storage-budget-bytes >= 0 | none)
```

V2 has no accepted trusted checkpoint timestamp, so `recent-count` keeps the
newest ordinal positions in the verified causal chain. It is deliberately not
a time-window policy. The sole current head is always retained. Effective
protection is additive. With a budget, required current/protected entries are
selected first; remaining recent entries are considered newest-first with
opaque-object-ref ties. A candidate is included only when the additional exact
encrypted source-object bytes fit. If required entries alone exceed the budget,
the plan reports the precise protected overrun and removes none of them.

A compaction plan revalidates the active scope, effective claims, and exact
regular-file lengths. It creates a new compact scope with one signed ledger
event for each retained snapshot, oldest-to-newest, reusing the original
snapshot opaque references. It then stores a `Scratch_generation` frame naming
the prior source scope/head and the new scope/activation anchor, and publishes
one signed generation ledger event targeting that frame. This last event activates
the generation. The source ref must appear in the sorted retired-ref list; it
makes the `scratch-compact(D, H)` name checkable against the full source head
`H` rather than trusting an unbound active-ref string. The frame lists older
retired scopes and canonical cleanup candidates; it must not list its active
scope, active anchor event object, or a retained snapshot. The anchor is the
sole compact head at activation; later ordinary scratch publication may extend
that same causal chain, so inspection requires the sole current head to descend
from the anchor rather than remain byte-for-byte equal to it.

After activation, inspection evaluates only the declared active scope. Retired
scope events remain authenticated objects but are no longer candidate scratch
history. A verifier obtains the active generation before evaluating ordinary
scratch scopes, so partially quarantined retired histories do not make active
repository meaning malformed.

The cleanup list contains every source event object from the retired scope and
only unretained snapshot objects not named by a retained entry, effective
protection claim, or live non-retired ledger target. There is no generic
cross-domain reachability assertion: future capsule/release designs must emit
an explicit protection claim before depending on a scratch snapshot. Generation
and protection objects remain reachable history in this initial design.

Quarantine happens only after activation. Each candidate is revalidated against
the active generation, expected encrypted frame kind, canonical source path,
and keep set. It moves into an exact generation-specific quarantine path on the
same filesystem without overwrite; an already-present byte-identical target is
a resumable prior move. Both directories are synced where supported. `prune`
deletes only an already quarantined active-manifest candidate; it is irreversible
and has separate failure/retry behavior.

## Consequences

- Retained scratch snapshots keep exact opaque references; only their ledger
  event chain is regenerated.
- A pre-activation interruption leaves the previous active scope unchanged,
  with at most unreachable new immutable objects.
- A post-activation interruption leaves the new exact active scope available
  and may leave excess source objects until quarantine resumes.
- Existing scratch publication appends to the active scope after compaction; it
  does not resurrect a retired base scope.
- V2-018 capsule curation and V2-021 releases must issue explicit protection
  claims when they need a scratch snapshot retained.

## Model and invariant impact

```text
Active_scratch(D) = scratch-base(D)
                  | generation-head(D).active-ref

retain(head, claims, policy) = current(head) union effective(claims)
                              union ordinal_recent(policy)

compact(retained) -> new-scratch-chain -> generation-frame
                  -> generation-ledger-event (activation) -> quarantine
```

1. The active scratch scope has one verified head or an explicit failure.
2. Each retained checkpoint resolves to the same exact snapshot before and
   after generation activation.
3. Protection and current head override quota pressure; overrun is observed,
   never repaired by eviction.
4. A compacted event targets an existing retained snapshot and names only the
   preceding compacted event as predecessor.
5. Activation follows durable, verified compacted events and generation frame;
   the anchor remains on the sole active compact chain as later scratch events
   extend it.
6. Cleanup never precedes activation or moves a keep-set object.
7. Quarantine is idempotently resumable; permanent prune is not recoverable.
8. Runtime policy, observed file sizes, and quarantine progress are not
   canonical encrypted history bytes.

## Persistent-format and migration impact

This adds ADR-054 frame-kind codes 2 and 3, both version 1 with mandatory
features zero, strict canonical decoders, and golden fixtures. Existing
envelope, opaque-address, ledger, snapshot, bootstrap, and journal schemas do
not change. The V2 object reader gains the new frame kinds; no old-format
reader or migration path is retained because the approved development policy
has no user repositories before issue closure.

Quarantine paths are local maintenance state outside the opaque object namespace.
They are validated against the immutable active generation rather than parsed as
canonical objects.

## Verification

- Unit and golden tests cover both payloads, strict reason/cleanup validation,
  and generation head/ref constraints.
- Seeded generated tests vary causal histories, claim order, policy input, file
  sizes, and permutations; selection must be deterministic.
- Activation tests prove exact retained snapshot reopening and both pre- and
  post-activation interruption states.
- Quarantine tests inject failure around each candidate movement; permanent
  prune tests are separate and do not claim rollback.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` are required.

## CLI and user impact

This decision adds no top-level VCS command. Future commands may expose
dry-run selection, activation, quarantine resume, permanent prune, and explicit
protection actions, but must display protected overrun and irreversible prune.

## Sources

The [Linux `rename(2)` manual](https://man7.org/linux/man-pages/man2/rename.2.html)
documents same-filesystem rename behavior and replacement semantics; cleanup
therefore needs a no-overwrite protocol rather than plain replacement rename.
The [Linux `fsync(2)` manual](https://man7.org/linux/man-pages/man2/fsync.2.html)
notes that file sync alone does not persist a containing directory entry, so
quarantine records both directory-sync attempts and their filesystem limitation.
