# Formal model

This document specifies the active V4 model. It deliberately has no migration
semantics for earlier product tracks.

## Core state

`Project` contains a unique active `Draft`, immutable `Checkpoint`s, ordered
`Shared_change`s with immutable `Change_revision`s, open `Decision`s,
`Resolution`s, `Delivery` records, and local `Username_registration`s.

`Checkpoint` is not `Change_revision`; `Change_revision` is not `Delivery`.
A decision is data, not an exceptional control path. A username registration is
not an identity claim.

Each change revision names its change ID, revision ID, parent revision if any,
author device ID, base snapshot, result snapshot, and exact edits. A delivery
uses the model’s current projection only after all relevant decisions are
resolved.

## Authority state

`Membership` is a causally verified set of public device certificates with one
self-signed administrator root. `Authority_epoch` is immutable and names a
repository, sorted parent epoch IDs, complete included certificate IDs,
inherited revocations, a revision frontier, one recovery public device, and a
signature from either an administrator active in every parent or the common
parent recovery device.

An `Authority` is a verified complete epoch DAG plus its non-parent heads.
Multiple heads remain distinct. A normal administrator action advances one
head: it uses the sole head when there is one, and otherwise requires an
explicit current parent selection. Reconciliation names two or more selected
current heads and requires an administrator active in every selected parent;
unselected heads remain active. No role or revocation state is inferred by
unioning divergent heads.

An epoch-bound `Signed_revision` binds one revision and its author certificate
to one authority epoch. It verifies only when the certificate was active in
that named epoch. Revocation does not invalidate that historical proof.

`Adoption` is a current-administrator signature over the exact signed-revision
digest. `Authorization` binds one device, revision, and change. Neither type
is a membership grant. For a record not already in the receiver’s project,
`late(record, authority)` holds if a current head causally descends from the
record epoch and revokes its signer. Receipt requires exactly one matching
adoption issued at a current head when `late` holds.

## Transitions and invariants

- `save` adds an exact checkpoint only when the observed snapshot changed.
- `share` appends a revision to one change and, in collaboration state, signs it
  at the sole current authority head. On a fork, it requires an explicitly
  selected current head for the signature.
- `receive` applies validated revisions through the pure causal model
  transition, delaying missing-parent revisions only to establish valid order.
- `revoke`, `enrol`, and `rotate` create a single-parent successor epoch;
  rotation adds the replacement certificate and revokes the old device
  atomically. On a fork they require an explicitly selected current parent.
- `reconcile` creates a multi-parent successor only for a canonical explicit
  selection of two or more current heads. It leaves every unselected head
  active.
- `recover` creates a recovery-issued replacement administrator certificate,
  successor epoch, revocation, and replacement recovery device. The old
  recovery authority is not active in the successor.
- `resolve` produces a new revision and clears only the selected decision. Its
  signed form likewise requires an explicit current head on a fork.

Snapshot identities are exact immutable object references. Persistent model,
authority, certificate, signed-revision, adoption, recovery-package, and
journal records have a schema version and canonical encoding; unknown mandatory
features and noncanonical encodings are rejected. Only the mutable
`v4-project-state` head selects a current immutable state object.
