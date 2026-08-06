# ADR-041 — Immutable divergent ref-head sets

- Status: Accepted
- Date: 2026-08-06
- Deciders: maintainer (approved 2026-08-06)
- Supersedes: None
- Superseded by: None

## Context and problem statement

ADR-039 preserves competing verified ref-event proposals only in caller state.
M10-05 must retain concurrent synchronisation heads across store reopen and
exchange without turning a proposal into an applied ref, selecting a winner, or
silently replacing one device's view with another's.

Current milestone: M10 Local Synchronisation. Vertical slice: one immutable
canonical set of exact Ref_event object links plus one merge-only local binding
per safe ref name. It excludes ref application, target merge, reachability,
automatic trust, conflict resolution policy, transport discovery, consensus,
background sync, CLI mutation, and key lifecycle. No implementation begins
before this ADR is accepted.

## Decision drivers

- Preserve ADR-020 immutable publication, ADR-023 CAS semantics, and ADR-039
  verified-event ordering without altering a mutable application ref.
- Retain every concurrent valid proposal and make omissions/corruption explicit.
- Make retry/reopen merge deterministic and bounded.
- Keep event ID, event object ID, divergence-set object ID, binding, and ref
  state type-distinct.

## Considered options

### Update the mutable application ref

- Reuses existing CAS storage.
- Confuses proposal retention with ref application and loses competing values.

### Keep an unpersisted list at each receiver

- Requires no new format.
- Loses divergence on restart and makes exchange results non-inspectable.

### Immutable event sets with a merge-only binding

- Stores exact competing event links and permits CAS retry by deterministic set
  union.
- Adds one versioned object and binding namespace that require goldens and
  compatibility handling.

## Decision outcome

Select immutable event sets with a merge-only binding.

`Divergent_ref_set_v1` is Envelope type 28 with canonical Profile-1 payload:

```text
divergent-ref-set-v1 = [
  1, repository-format-sha256, ref-name, observed-generation,
  observed-target-or-null,
  [* strictly-ascending (event-id, ref-event-object-id)], mandatory-features
]
```

The list has 2–4,096 unique entries ordered by raw event ID. Each entry loads
an exact `Ref_event_v1` object, whose recomputed event ID, repository digest,
ref name, and observed state must agree with the set. Every event must already
be ADR-039 `Verified` against the explicit caller key map before insertion;
untrusted, malformed, stale, duplicate, missing, wrong-type, mismatched, or
out-of-context links are structured rejections. A set records candidates only:
it does not call mutable-ref CAS, advance a ref, delete a ref, merge a target,
or claim a selected head.

The only mutable visibility point is `refs/sync-divergence/<safe-ref-name>`.
Its existing checksummed ref value names one `Divergent_ref_set_v1` object.
Publication reads the binding, loads/validates its set, takes the exact union
with supplied verified entries, stores the canonical union create-only, and
CASes the binding. A CAS race reloads and repeats the union within a bounded
16 retries; exhaustion is explicit. No successful publication removes a prior
entry. A missing binding creates the first set; an existing corrupt binding or
set rejects without replacement. The application ref namespace is not read or
written.

V1 bounds are 4,096 entries/set, 16 MiB encoded set bytes, 256 trusted keys per
verification, and 16 CAS retries. Device resolution may be reported only after
event verification; it does not grant trust or choose a candidate. Key
rotation/revocation and policies that prune a candidate require later ADRs.

## Consequences

- Concurrent verified proposals remain durable and inspectable after reopen.
- Repeated exchange/publication is idempotent; concurrent writers converge on
  union or fail explicitly at the retry bound.
- A divergence set is not a current ref, reconciliation result, or authority
  record; users still need a later explicit decision to apply anything.

## Model and invariant impact

New values are divergence set, set entry, divergence binding, and merge result.

- Every bound entry is one exact validated verified event object for the set's
  ref/observed state.
- Canonical union is associative, commutative, and idempotent over valid unique
  event IDs.
- Binding publication only adds entries; it cannot silently discard one.
- Every decode/verification/CAS failure leaves application refs unchanged.

## Persistent-format and migration impact

This is additive after acceptance: Envelope type 28, retained set/binding
goldens, and one new `sync-divergence` ref namespace. Existing objects, refs,
exchange frames, Ref_event v1 bytes, and device declarations remain unchanged.
Existing repositories have no binding and need no migration. Future versions
retain v1 decoders/fixtures or reject before binding use; they do not rewrite
sets, events, or refs in place.

## Verification

- Exact set/envelope/binding goldens and inverse decoders, including retained
  v1 event fixtures.
- Focused two-device concurrent, duplicate, stale, wrong-type, corrupt,
  untrusted, missing-link, CAS-race, retry-bound, reopen, and unchanged-ref
  cases.
- Seeded bounded state-machine properties varying delivery order, duplicates,
  interruption/restart, corruption, union, and CAS races.
- `make check` and `make property-test PROPERTY_TEST_SEED=17`.

## CLI and user impact

M10-05 may expose an inspectable divergence listing only. It must report each
exact candidate/status without describing it as applied, trusted, selected,
merged, or synchronised; no CLI mutation is added.

## Implementation evidence

Implemented by `yeokcham_divergence` and `yeokcham_divergence_store` with Envelope
type 28 and checksummed `sync-divergence` bindings. Focused golden, inverse,
two-device merge/reopen, rejection, and unchanged-ref coverage is in
`test/test_divergence.ml`; the seeded delivery/duplicate/restart/corruption
property is `test/divergence_property_test.ml`. Verified with `make check` and
`make property-test PROPERTY_TEST_SEED=17`.
