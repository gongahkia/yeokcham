# ADR-038 — Bounded immutable object exchange

- Status: Accepted
- Date: 2026-08-05
- Deciders: maintainer (approved 2026-08-05)
- Supersedes: None
- Superseded by: None

## Context and problem statement

M10-01 begins local synchronisation after the local scratch, capsule,
workspace, conflict, release, object-publication, and CAS invariants are
implemented. ADR-010 defers distributed behaviour until this point; ADR-020
defines local immutable Envelope-1 object publication. An exchange mechanism
must discover and transfer immutable object bytes between two compatible local
repositories without silently overwriting an object, advancing a ref, choosing
a divergent head, or treating network/transport state as canonical history.

Current milestone: M10 Local Synchronisation. Vertical slice: define a bounded,
transport-neutral protocol-v1 for compatible peers to discover, request,
transfer, verify, and restart immutable object exchange. It excludes ref
exchange/reconciliation, peer identity, signing, encryption, compression,
authentication, consensus, automatic graph reachability, background sync, CLI,
and transport implementation. No implementation begins before this ADR is
accepted.

## Decision drivers

- Reuse ADR-020 stored-object identity and create-only publication exactly.
- Reject incompatible repository/object formats before object discovery.
- Bound message bytes, object bytes, object IDs, pages, and session work.
- Make interruption and retry safe without a mutable transfer journal.
- Preserve divergent mutable refs for a later explicit reconciliation decision.
- Keep wire/schema evolution explicit without creating a Paengi persistent
  object format.

## Considered options

### Copy object directories between peer repositories

- Reuses current object file paths.
- Couples exchange to filesystem layout, has no message compatibility boundary,
  and cannot distinguish malformed/corrupt peer bytes from a valid retry.

### Exchange mutable refs and objects in one operation

- Can make a peer appear immediately up to date.
- Couples immutable transfer to divergent-head policy, ref CAS, identity, and
  conflict semantics before those decisions are defined.

### Versioned immutable-object protocol with no ref mutation

- Binds every transferred byte string to its typed stored-object ID and local
  create-only `put` path.
- Leaves transport, identities, refs, and reconciliation as explicit later
  layers while allowing restart-safe object convergence.

## Decision outcome

Select the versioned immutable-object protocol with no ref mutation.

`exchange-v1` is a transport-neutral sequence of length-delimited canonical
Profile-1 CBOR messages. A frame is exactly `u64-be payload-length || payload`;
the payload is a canonical CBOR array beginning with protocol version `1`,
message kind, required-feature bits, and that kind's fields. Unknown mandatory
features, unsupported version, noncanonical CBOR, trailing bytes, malformed
length, or unsupported message kind are structured rejection before repository
state changes. This framing is a transient protocol schema, not an Envelope or
Paengi object.

The v1 logical messages are:

- `Hello(repository-format-bytes, supported-versions, required-features)`;
- `Inventory(session-id, sequence, final, sorted-unique stored-object-ids)`;
- `Want(session-id, sequence, sorted-unique stored-object-ids)`;
- `Object(session-id, sequence, stored-object-id, exact Envelope-1 bytes)`;
- `End(session-id, status)`; and
- `Error(session-id option, code, detail)`.

`Hello` precedes every other message. Peers require byte-identical current
repository-format records, an overlapping supported version, and no unknown
mandatory feature before accepting an inventory. A session ID is a transient
16-byte nonce used only to reject interleaved/replayed frames within one
invocation; it is neither a device identity nor persisted state. Inventory and
Want pages are strictly ascending by raw 32-byte stored-object ID and carry a
strictly increasing sequence. `final = true` closes one offered inventory; it
does not assert repository reachability or synchronised refs.

V1 limits are: 1 MiB message payload excluding an Object's Envelope bytes,
4,096 IDs per Inventory/Want page, 128 MiB Envelope bytes per Object (the
current `Paengi_store.max_object_bytes`), 16 MiB total control-plane bytes per
session, 65,536 requested/transferred object IDs per session, and a caller-set
total object-byte budget not exceeding 1 GiB. A limit breach stops the session
with a structured error; objects already individually verified and published
remain valid immutable objects, while no ref is changed.

For every Object, the receiver checks the session/sequence/request membership,
size, typed 32-byte ID, domain-separated ADR-020 stored-object hash, Envelope
decode/checksum, object-format version, and mandatory features before calling
the existing local `Paengi_store.put`. `put` retains ADR-020 behaviour: a
byte-identical existing final object is idempotent; different bytes at the same
ID are collision/corruption; no final object is overwritten or repaired.
Object bytes are never decompressed, transformed, re-encoded, or partially
published by exchange.

The protocol transfers only explicit offered/requested immutable IDs. It does
not infer object graph closure or mutable ref reachability. A later layer may
derive a declared object set from a verified ref/root, but must define that
traversal and ref policy separately. V1 does not transfer, create, update, or
reconcile scratch heads, retention refs, generation refs, capsule/workspace
current refs, release refs, mappings, Git refs, or external destinations.

Restart has no persistent sync journal. After interruption, either peer starts
a new Hello and repeats discovery. Objects published before the interruption
are rediscovered; ADR-020's idempotent equality verification makes retransfer
safe. Partial frames, temporary files, missing promised objects, duplicate
object IDs, out-of-order sequences, excess budgets, corruption, timeout, and
peer disappearance are structured incomplete-session outcomes. They never
advance a mutable ref or delete an object.

## Consequences

- Compatible peers can converge an explicit immutable object set without
  changing visible histories or resolving divergence.
- Transport implementations can use local HTTP, files, pipes, or tests while
  preserving one message/schema contract.
- Object transfer has a bounded restart story without a durable transfer state.
- Peers with different repository formats or unsupported mandatory features
  cannot partially negotiate into an apparently compatible session.
- Users must explicitly inspect and reconcile refs after a future ref-sync
  layer; object presence alone does not mean a history is selected.

## Model and invariant impact

New transient values are exchange session, feature set, frame, message,
inventory page, request page, object receipt, budget, and structured exchange
error. They are separate from stored object, snapshot, checkpoint, capsule,
revision, workspace, conflict, release, ref, mapping, device identity, and
signature values.

- A received available object has the exact requested typed ID and exact valid
  Envelope bytes used by ADR-020 identity verification.
- An exchange session cannot expose an Object before compatible Hello,
  canonical ordering, membership, sequence, and budget validation.
- Object publication is create-only and byte-identically idempotent; a
  collision/corruption outcome has no overwrite recovery path.
- Every stop/restart preserves all prior valid immutable objects and all mutable
  refs exactly; divergence remains explicit.
- No exchange fact is semantic authority or a proof of trust, ownership,
  reachability, freshness, or behavioural equivalence.

## Persistent-format and migration impact

No Envelope, object, ref, mapping, scratch, capsule, workspace, release,
signature, or repository-format bytes change. V1 frames are transient and no
session/journal record is persisted. Existing persistent goldens remain
byte-identical.

A later wire version or required feature retains v1 decoding/fixtures for
supported peers or explicitly rejects v1 before transfer; it never rewrites
stored objects. Persistent resume, signed announcements, ref state, object-set
manifests, compression dictionaries, or encryption metadata each require a
separate ADR, compatibility analysis, and migration fixtures.

## Verification

Required before implementation issue closure:

- Exact canonical frame/message goldens for Hello, paged inventory/Want,
  Object, End, Error, and version/feature rejection.
- Two-device local fixtures for empty/equal/divergent object sets, repeated
  transfer, compatible/incompatible format, and no-ref-change observation.
- Unit tests for ordering, page/session/sequence membership, required features,
  budgets, exact object identity/Envelope verification, idempotent existing
  objects, and collision/corruption refusal.
- Seeded state-machine properties varying interruption points, duplicates,
  partial pages, restart/retry, loss/reordering, limits, and corruption; every
  terminal state preserves object/ref invariants.
- Failure injection before/after frame receipt and local publication; tests for
  malformed/noncanonical CBOR, bad lengths, invalid IDs, hash mismatch,
  checksum/format failure, mandatory-feature rejection, timeout, peer loss,
  and object/ref immutability.
- `make check`, `make property-test PROPERTY_TEST_SEED=17`, retained protocol
  fixtures, and persistent-format audit.

## CLI and user impact

No CLI or transport implementation is introduced in M10-01. Future inspection
may report peer compatibility, requested/transferred IDs, budgets, verified
objects, and structured incomplete-session reasons. It must not claim that a
peer is trusted, a ref was synchronised, or divergent histories were merged.
