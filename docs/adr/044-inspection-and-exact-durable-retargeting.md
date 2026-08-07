# ADR-044 — Inspectable repository operations and exact durable retargeting

- Status: Accepted
- Date: 2026-08-07
- Deciders: maintainer
- Supersedes: None
- Superseded by: None

## Context and problem statement

The durable model already has object verification, snapshots, capsule revisions,
workspaces, releases, explicit dependency values, and a nonpersistent semantic
retargeting experiment. The local CLI did not expose repository-wide integrity
verification, storage accounting, status, required timeline fields, durable
capsule retargeting, or dependency declaration when creating a capsule.

## Decision

Add a read-only `yeokcham_inspection` adapter and CLI commands `status`,
enriched `timeline`, `storage stats`, and `verify`. Object enumeration must
ignore dot-prefixed interrupted-publication temporaries already tolerated by
the store, reject every other malformed layout entry, and pass each canonical
object through the ordinary stored-object identity and Envelope-1 decoder.
`verify` must then validate all stored snapshot graphs, capsule-revision links
and dependencies, current workspaces, and published releases. It must not
repair, rewrite, or publish anything.

`storage stats` reports physical stored-object byte lengths by exclusive object
domain. The retained-checkpoint subtotal resolves logical IDs through the active
generation and de-duplicates physical checkpoint IDs; it is not additive with
the domain totals.

Allow explicit creation-time dependency flags for capsule, pinned revision,
release, conflict, and ordering declarations. The existing canonical revision
dependency codec remains authoritative.

Add an exact durable retarget transition for a current capsule revision. It
replays only the revision's existing exact operations on a caller-supplied
snapshot. On success it persists a complete immutable child revision and CAS
updates the current ref. The child carries a `Retargeted_from` revision link in
the existing `provenance-v1` sum encoding as tag `4`; tags `0` through `3` and
all existing golden bytes remain unchanged. On an application conflict it
returns the complete structured conflict list and does not change the ref.
Semantic-anchor and textual fallback experiments are not invoked or persisted.

## Invariants

- Inspection has no object/ref write path.
- Every enumerated object has canonical location, matching object ID, and a
  valid Envelope-1 before its bytes or type are reported.
- A successful retarget keeps the capsule ID stable, creates a new logical and
  physical revision, retains a direct replay result, and names the immediately
  preceding current revision in provenance.
- A retarget conflict does not advance or replace the current ref.
- Retargeting preserves the source revision's declared dependencies, evidence,
  operations, and source boundaries.
- Semantic sidecars remain noncanonical evidence and cannot silently author a
  durable revision.

## Consequences

The CLI becomes able to audit the local repository without a separate demo or
ad-hoc filesystem inspection. Verification can be expensive because it checks
every stored snapshot rather than only current refs. Retargeting is durable only
for exact byte/mode/move operations at this stage; callers receive conflicts for
operations needing semantic or textual selection.

## Verification

- Focused tests cover read-only status/timeline/storage/verification accounting,
  a successful durable retarget, and a conflicting retarget that preserves the
  current ref.
- A seeded durable-capsule state-machine property includes a retarget and checks
  that provenance links the prior immutable revision.
- Existing persistent-format goldens and broad format checks remain required.
