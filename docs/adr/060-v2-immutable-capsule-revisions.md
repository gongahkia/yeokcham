# ADR-060 — V2 immutable capsule revisions and explicit composition plans

- Status: Proposed
- Date: 2026-08-10
- Deciders: maintainer (approved V2-01 client-neutral continuation)
- Supersedes: None
- Superseded by: None
- Governing issue: [#141](https://github.com/gongahkia/yeokcham/issues/141)
- Related issues: [#140](https://github.com/gongahkia/yeokcham/issues/140), [#142](https://github.com/gongahkia/yeokcham/issues/142)

## Context and problem statement

ADR-059 creates one visible, exact initial V2 capsule revision. A continuing
capsule needs later immutable revisions, but V2 deliberately has neither V1
mutable ref files nor a platform-specific editor or filesystem authority.
Later revision operations must preserve direct exact replay, retain a stable
capsule identity, and make a concurrent current-head change explicit.

## Decision drivers

- Preserve ADR-059 initial records and their v1 bytes exactly.
- Every revision directly replays from its own declared base.
- Make parent history and split/combine sources inspectable immutable links.
- Make planning read-only and confirmation an explicit publication boundary.
- Reuse signed causal ledger events as the V2 current-selection mechanism.

## Decision outcome

`Capsule_revision` frame kind 5 accepts a second, strict canonical payload
version. Version 1 remains the ADR-059 initial record. Version 2 adds an
optional same-capsule parent revision link, an ordered nonempty list of source
boundaries, explicit provenance, and an observation timestamp. Its logical ID
is a new domain-separated SHA-256 preimage over the capsule ID, parent logical
link, declared-base and expected-result logical snapshot IDs, exact operations,
logical source boundaries, and logical provenance links. Opaque object
references remain required durable verification links but do not affect the
logical ID.

```text
revision-link-v2 = [capsule-id, revision-id, revision-opaque-ref]
parent-link-v2 = revision-link-v2
provenance-v2 = created | folded(parent-link-v2) |
                split-from([* revision-link-v2]) |
                combined-from([* revision-link-v2])
capsule-revision-v2 = [
  2, capsule-id, revision-id, capsule-opaque-ref,
  parent-link-v2-or-null, declared-base-link, expected-result-link,
  [* canonical-operation-bytes], [* source-boundary-v1], provenance-v2,
  created-at, features
]
```

A fold names the currently selected revision and its binding event, plus an
explicit scratch range and an ascending selection. The source checkpoint must
equal the selected revision result. The service derives and selects only exact
structural operations from that result, then derives the child complete delta
from the parent's declared base to the selected result. The child therefore
replays directly without recursively applying its parent. Both new range
boundaries receive retention claims before the child binding is visible.

The signed `capsule-<id>` ref remains the only current selection. A later
binding names the previous binding event as its ledger predecessor. Publication
checks the caller's expected revision and binding event immediately before it
adds the child event. A stale expectation returns a concurrent-update error;
if independent publishers nonetheless create causal heads, resolution reports
divergence and selects no winner.

Split and combine first create a read-only plan. A split preserves an ascending
operation partition and reports an exact left result plus a right revision whose
base is that result. A combine preserves caller-supplied source order and only
accepts a directly replayable base/result chain. Plans expose logical output
identities, bases, results, source order, and provenance. They create no object,
claim, or binding. Confirmed publication recomputes the plan from verified
inputs before publishing any output capsule; each visible output is individually
complete, and a crash can leave no implicit source mutation or partial visible
revision.

The V2 service is deliberately filesystem-neutral. An edit request is an
explicit, read-only target plan for the selected revision result. A client that
materialises it must use the guarded V2 restore services; no edit session,
working-path, or UI state becomes canonical capsule storage.

## Consequences

- ADR-059 v1 Capsule and initial Capsule_revision frames remain decodable and
  byte-identical.
- Revision parent and provenance links are immutable, physical, and type
  checked on reopen; parent traversal detects cycles through the pure graph
  seam and rejects invalid durable links.
- A capsule current head is a verified causal event rather than a mutable file.
- No intent, move, semantic rewrite, automatic conflict resolution, or
  platform-dependent editor action is inferred.

## Model and invariant impact

```text
child.parent = P => child.capsule = P.capsule
visible(C) => replay(current(C).base, current(C).operations) = current(C).result
publish(child, expected-head) => current(C) = expected-head before binding
unconfirmed(plan) => no object, claim, or binding publication
```

1. A complete child may retain a parent but never needs parent operations to
   replay.
2. Parent links only connect revisions of the same capsule.
3. Provenance links are explicit evidence, not an instruction to infer intent.
4. Read-only plans do not reserve IDs or mutate repository state.
5. Divergent signed heads are an explicit conflict, never last-writer-wins.

## Persistent-format and migration impact

Kind 5 gains only `capsule-revision-v2`; ADR-059 `capsule-revision-v1` bytes,
object kinds, envelope formats, scratch formats, and existing golden fixtures
remain unchanged. A new v2 frame golden is required. The approved development
policy has no real V2 repositories, so no migration writer is introduced.

## Verification

- Unit and seeded generated tests cover direct child replay, parent/type/cycle
  rejection, stale-head rejection, and reopen verification.
- Split/combine plans are tested for zero publication until confirmed and exact
  replay after confirmation.
- Persistence-failure tests cover interruption before a child binding.
- `make check` and `PROPERTY_TEST_SEED=17 make property-test` are required.
