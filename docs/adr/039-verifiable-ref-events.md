# ADR-039 — Verifiable ref events without implicit trust

- Status: Accepted
- Date: 2026-08-05
- Deciders: maintainer (approved 2026-08-06)
- Supersedes: None
- Superseded by: None

## Context and problem statement

M10-02 follows ADR-038's compatible immutable-object exchange. A peer can now
transfer an exact object byte string without moving any mutable ref. The next
layer needs to describe a proposed ref transition and let a local user verify
who signed it, while preserving divergent ref states and avoiding an
unauthenticated device, key, or ref authority.

Current milestone: M10 Local Synchronisation. Vertical slice: define one
immutable signed ref-event record and pure verification result. It excludes
transport, automatic ref application/reconciliation, device lifecycle, key
distribution, key rotation/revocation, authentication UI, encryption,
consensus, background sync, and CLI. No implementation begins before this ADR
is accepted.

## Decision drivers

- Preserve ADR-020 create-only object publication and existing mutable-ref CAS.
- Make exact signed bytes, signer selection, replay, and rejection inspectable.
- Keep an explicit local trust decision separate from possession of a key ID.
- Represent incompatible concurrent proposals without last-writer-wins choice.
- Avoid treating ADR-027's deterministic test signer as cryptographic evidence.

## Considered options

### Transfer mutable ref files

- Reuses local storage.
- Has no signer, replay, compatibility, or divergence boundary and can silently
  replace visible local state.

### Treat any self-declared key as trusted

- Makes signatures easy to verify.
- Equates a byte string with a person/device authority and permits arbitrary
  peer-supplied keys to assert ref changes.

### Signed immutable proposals with caller-supplied trust

- Separates canonical proposal bytes, cryptographic verification, local trust,
  and later ref-application policy.
- Leaves key lifecycle and reconciliation as explicit future decisions.

## Decision outcome

Select signed immutable proposals with caller-supplied trust.

`Ref_event_v1` is a new immutable Envelope object type. Its unsigned canonical
Profile-1 payload is:

```text
ref-event-v1-unsigned = [
  1, event-id, repository-format-sha256, ref-name,
  signer-key-id, signer-sequence, previous-signer-event-id-or-null,
  observed-generation, observed-target-or-null,
  proposed-generation, proposed-target-or-null,
  mandatory-features
]
event-id = SHA-256("paengi:ref-event:v1\000" || encode(unsigned-without-event-id))
```

The stored payload appends `algorithm-text` and `signature-bytes`. The signed
preimage is exactly:

```text
"paengi:ref-event-signature:v1\000" || encode(ref-event-v1-unsigned)
```

V1 accepts only `algorithm-text = "ed25519"`, a 32-byte public key, a 32-byte
`signer-key-id = SHA-256("paengi:ref-key:v1\000" || public-key)`, and a
64-byte signature. The event contains only the key ID; a verifier receives an
explicit caller-supplied bounded map from key ID to public key. It recomputes
the key ID, event ID, canonical payload, repository-format digest, and Ed25519
verification before yielding `Verified`. An absent key is `Untrusted`, not a
valid assertion. Unknown algorithms, key-ID mismatch, bad signature, malformed
canonical bytes, unsupported mandatory features, or bound breach are structured
rejections. The existing deterministic release test signer is invalid for this
algorithm and cannot produce `Verified` ref events.

`repository-format-sha256` is the SHA-256 digest of the exact current
`Paengi_store.repository_format` bytes. `ref-name` uses the existing safe
single-component mutable-ref namespace. `observed` is the source ref's complete
`(generation, target)` pair. `proposed-generation` is exactly
`observed-generation + 1`, and the proposed target may be absent. The event
describes an intended CAS transition only; producing, receiving, or verifying
it does not call `compare_and_swap_ref`, create a ref, update a ref, or delete a
ref.

`signer-sequence` is non-negative and strictly increasing within one signer key
chain; `previous-signer-event-id` is null only for that key's first known event.
An event with a repeated signer sequence, inconsistent predecessor, different
signed bytes for one event ID, an observed ref that no longer matches local
state, or a competing valid proposal is an explicit replay/order/divergence
result. V1 does not choose a winner, merge targets, advance a ref, or infer
reachability. A later reconciliation layer must present competing verified
events and obtain an explicit policy/user choice.

V1 limits are: 256 trusted public keys supplied per verification call, 4,096
candidate events per ref evaluation, 256-byte ref name, 256-byte algorithm text,
and 16 MiB total event bytes per evaluation. Public key, key ID, event ID, and
stored object ID are type-distinct. Keys, trust maps, verified-event indexes,
and replay cursors are transient caller state; no trust database or automatic
key discovery is introduced.

## Consequences

- A verified event proves only that a configured public key signed exact
  proposal bytes; it does not prove a human, device, ownership, authorisation,
  freshness, ref application, or convergence.
- A valid but untrusted event can remain an inspectable immutable object but
  cannot affect a local ref or become a verified event result.
- Repeated transfer/reopen is safe because event objects are immutable and no
  event or verification result mutates a ref.
- Key registration, revocation, aliases, multiple algorithms, timestamps,
  witness policies, and device identities require separate ADRs.

## Model and invariant impact

New values are ref event, signer key ID, signer sequence, signature preimage,
trust map, verification result, replay result, and divergence set. They are
separate from stored-object ID, release attestation, mutable ref, device
identity, checkpoint, capsule, revision, workspace, conflict, and release.

- One event ID names one exact canonical unsigned proposal.
- `Verified` requires exact configured-key signature verification; `Untrusted`
  is not an authenticity result.
- An event's observed/proposed transition is a proposal, never evidence that a
  mutable ref changed.
- Concurrent verified proposals remain distinct values until a later explicit
  reconciliation decision.

## Persistent-format and migration impact

This is additive after acceptance: `Ref_event_v1` receives a new Envelope type
code and retained canonical fixtures. Existing Envelope, ref, release
attestation, exchange-v1 frame, and repository-format bytes remain unchanged.
Existing repositories have no ref events and no migration action. A future
event/key version retains v1 decoders and fixtures or rejects v1 before any ref
operation; it never rewrites an immutable event or mutable ref in place.

## Verification

Required after acceptance:

- Exact unsigned/stored event goldens and inverse canonical decoders.
- Two-local-repository fixtures for accepted, untrusted, wrong-repository,
  replayed, out-of-order, and concurrent proposals with unchanged refs.
- Focused tests for key/event identity, signature bytes, malformed records,
  unknown algorithms/features, key and event bounds, stale observed state, and
  no-ref-change on every failure.
- Seeded generated event-chain/restart/failure properties including loss,
  duplicate delivery, corrupted signature, key absence, replay, and divergence.
- `make check`, `make property-test PROPERTY_TEST_SEED=17`, and retained old
  persistent fixtures.

## CLI and user impact

No CLI, transport, key import, trust configuration, or ref mutation is added in
M10-02. A future inspector may state that an event is verified for one explicit
key map, untrusted, invalid, stale, replayed, or divergent. It must not state
that a person/device is trusted or that a ref was synchronised without a later
approved trust and reconciliation layer.
