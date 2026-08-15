# ADR-077 — Peer publication projections and explicit integration

- Status: Accepted
- Date: 2026-08-15
- Deciders: maintainer
- Supersedes: None
- Superseded by: None

## Context and problem statement

V3-003 introduces direct native peer exchange after the local model and Git
migration boundary. A stored capsule revision records local scratch checkpoint
boundaries. Sending its raw storage closure would therefore either transfer
scratch history or leave a receiver with dangling checkpoint references. Either
result violates the V3 promise that scratch remains local by default.

Current milestone: V3 peer exchange. Vertical slice: publish one selected
capsule revision or release as a versioned immutable projection; transfer its
verified snapshot closure through the existing bounded immutable-object
exchange; retain it as an inspectable proposal; and let the receiver explicitly
adopt a capsule projection into a fresh local capsule. It adds no ref sync,
automatic workspace mutation, working-tree materialisation, discovery, relay,
background daemon, account, or merge policy.

## Decision outcome

`Peer_publication_v1` is a versioned canonical Envelope record with a typed
logical publication ID and one of two targets:

- a capsule projection: source capsule and revision IDs, source title and
  description, and the revision's exact declared-base and expected-result
  snapshots;
- a release projection: source release ID, message/timestamp metadata, and its
  exact base and final snapshots.

The record contains the sorted, duplicate-free closure of those snapshots. The
closure may contain only Snapshot, Tree, Content, File_manifest, and Chunk
objects. It contains neither scratch event/checkpoint/retention/generation
objects nor mutable refs, workspace/release/capsule records, validation data,
or another publication. A recipient validates every listed object and
recomputes this closure before its publication binding becomes visible.

The source verifies a selected capsule revision or release with the ordinary
local resolver before building a projection. The receiver preserves the source
logical IDs as provenance, not as local capsule or release identity. A received
publication is an inspectable proposal, not a current capsule, workspace
input, release, scratch head, or working-tree action.

`Peer_integration_v1` records a receiver-chosen capsule adoption. Its explicit
command requires a new local capsule ID, title, and description. It makes fresh
detached local checkpoint boundaries from the projected source/result snapshots,
then uses ordinary durable capsule creation. It never copies a remote scratch
checkpoint. Release projections are intentionally not converted into native
releases: a native release requires a locally verified workspace/validation
composition, which remote release provenance cannot manufacture.

The local-path adapter opens the caller-selected source repository, transfers
only the publication record plus missing listed immutable objects through the
bounded exchange protocol, validates the complete result, and creates the
receiver binding. It never changes sender state. SSH is a Unix transport over
the same declared immutable object set and uses an explicit, one-shot remote
command; it has no Yeokcham account, listener, discovery, or background
service.

## Invariants

1. A publication target refers only to a source capsule revision or release
   already verified in its source repository.
2. The closure is exact, sorted, and contains only snapshot-storage object
   types. Scratch and mutable records are absent.
3. All transferred bytes retain their existing typed stored-object IDs and are
   published create-only; malformed, incompatible, interrupted, or collision
   transfers cannot alter a pre-existing object or ref.
4. Receiving publishes no workspace selection, scratch head, capsule current
   ref, release binding, or working-tree change.
5. Capsule integration is a new local intent transition requiring user-authored
   local identity/title/description. A received source ID is provenance only.
6. Release integration refuses rather than inventing workspace validation,
   release ancestry, or a policy for foreign evidence.

## Persistent-format and migration impact

This adds Peer_publication and Peer_integration Envelope types and create-only
bindings under `refs/peer-publications/` and `refs/peer-integrations/`. Both
records are versioned, canonical, golden-tested, and reject unknown mandatory
features. Existing repository roots, objects, mutable refs, scratch history,
and Git archive formats are unchanged.

## Verification

- Golden publication/integration bytes and bindings with inverse decoders.
- Two-repository local-path fixtures for capsule/release publication, exact
  missing-only transfer, receiver reopen, sender immutability, and explicit
  capsule adoption.
- Failure tests for corrupt/missing closure objects, scratch-object inclusion,
  incompatible roots, transfer interruption/retry, corrupt bindings, and
  release-adoption refusal.
- Seeded generated capsule projections varying byte/mode snapshot content and
  already-present receiver objects.
- A direct-argv SSH adapter test with a controlled runner; it does not claim a
  configured SSH server or peer authentication.

## Consequences

Peer exchange is distinct from Git cloning and from the retired V2 sync work:
it distributes selected native work as explicit, inspectable proposals. It is
not automatic history reconciliation. A later capability for signatures,
identity, release adoption, workspace integration, or peer discovery requires
a separate decision and cannot reinterpret V1 records.
