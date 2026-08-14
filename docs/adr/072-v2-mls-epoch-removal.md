# ADR-072 — V2 MLS epoch removal and append-only rekeying

- Status: Accepted
- Date: 2026-08-14
- Deciders: maintainer (approved development roadmap)
- Governing issue: [#153](https://github.com/gongahkia/yeokcham/issues/153)
- Related issues: [#152](https://github.com/gongahkia/yeokcham/issues/152) and [#122](https://github.com/gongahkia/yeokcham/issues/122)

## Context and problem statement

ADR-071 deliberately left issuer-state replacement and member removal to a
separate transition. Replacing `group-state-v1.cbor` would lose a verifiable
predecessor, make interruption ambiguous, and violate the rule that the only
copy must not be mutated in place. V2 needs real MLS Remove commits, active
member rekeying, and an explicit boundary on what removal does not revoke.

## Decision

The repository authority root is the sole removal policy role in this slice.
The secure runtime performs a real MLS Remove proposal and Commit, applies it
to the issuer state, and exposes an explicit active-client Commit application
operation. Active retained clients get an opaque successor snapshot only after
their runtime has processed the delivered Commit. Removed clients get an
explicit `Removed` outcome and no successor snapshot.

`Mls_epoch_transition_v1` is a root-signed canonical CBOR record. It binds the
repository-derived GroupID, parent transition or initial root, changed device,
change kind, consecutive MLS epoch numbers, SHA-256 commitments of predecessor
state, successor state, and Commit bytes, and an encrypted successor snapshot.
The record ID is the domain-separated SHA-256 of its unsigned canonical fields;
the root signature signs that ID in a separate domain. The successor snapshot
uses the existing V2 envelope under caller-owned local bootstrap custody; no
MLS key, exporter secret, or plaintext snapshot is durable.

Records publish create-only at:

```text
.yeokcham/mls-epochs/<epoch-id>.cbor
```

The store uses same-directory `0600` staging, file and directory `fsync`, and
hard-link publication. Exact byte retries are idempotent. Strict enumeration
ignores only the adapter's staging grammar. A reader verifies a unique complete
chain from the initial group state: every record must be canonical and signed,
every predecessor commitment and parent must match, every encrypted successor
must open and runtime-reload, and all records must be consumed. Competing
children are `Divergent_epoch`; disconnected records fail closed.

Both Add and Remove transitions use this one generic append-only record so the
issuer state returned by ADR-071 can become a durable predecessor for removal.
This does not make an invitation event itself membership state.

## Alternatives considered

- Overwrite the initial encrypted group state: rejected because it discards the
  causal predecessor and has no interruption-safe compare-and-publish proof.
- Treat MLS roster membership as removal authority: rejected because a roster
  is not an authorization-policy evaluator.
- Add a server recovery key or re-encrypt all historical content: rejected;
  this slice has neither recovery-key policy nor retroactive revocation.
- Return a fake successor to removed devices: rejected because it would
  contradict MLS removal semantics.

## Invariants

1. Only the repository authority root can create a transition.
2. A transition binds one repository-derived GroupID, one parent, one changed
   device, and exactly `next_epoch = previous_epoch + 1`.
3. The persisted successor is a canonical encrypted group snapshot, never
   plaintext MLS state or key material.
4. Active retained devices can advance only by runtime processing the Commit;
   a removed device has no successor snapshot and cannot decrypt newly
   encrypted MLS metadata.
5. Stored records form one complete, append-only, uniquely verifiable chain or
   return an explicit divergence/disconnection error; no reader chooses a head.
6. Removal does not revoke plaintext or ciphertext keys already copied from a
   previous epoch. This limitation is explicit in API names, tests, and docs.

## Persistent-format and compatibility

`Mls_epoch_transition_v1` rejects unknown mandatory features and records the
existing versioned V2 envelope bytes. `mls-epochs` is an optional strict V2
namespace; roots created before this slice remain valid without it. No record
or initial state is overwritten, and no migration is needed for V2's
development format.

## Verification

- Rust tests execute a real three-device Add/Add/Remove sequence, rekey an
  active device, and report the removed device outcome.
- OCaml unit tests cover signed encrypted chain replay, root refusal, exact
  durable retry, interrupted staging, unknown-entry refusal, and the explicit
  historical-plaintext limitation.
- A seeded property varies repository and device IDs and proves append-only Add
  and Remove records replay to their unique runtime-verified successor.
- Canonical record format is covered by the V2 format test/golden fixture; the
  store validates strict lowercase-hex names and staging grammar.

## Consequences

This creates a local, verifiable epoch progression and active-client rekeying
primitive. It does not deliver commits, synchronize epochs, establish remote
identity or role delegation, revoke already copied history, add server recovery
keys, or add a CLI command.

## References

- [RFC 9420 — The Messaging Layer Security (MLS) Protocol](https://www.rfc-editor.org/rfc/rfc9420.html)
- [mls-rs CommitBuilder API](https://docs.rs/mls-rs/latest/mls_rs/group/struct.CommitBuilder.html)
