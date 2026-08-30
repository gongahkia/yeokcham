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
resolved. Its signed wrapper is either `Shared` or `Resolution(decision)`;
the latter binds the exact decision ID as well as the replacement revision.
This category is part of the signed bytes, not package metadata supplied by an
untrusted copier.

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

Authority validity has no online input. Network reachability, relay state,
quorum response, timestamp, lease, witness receipt, and remote observation do
not authorize, select, reject, or order an epoch. An administrator active at a
locally verified current epoch may act while disconnected; concurrent results
remain heads until an explicit valid reconciliation.

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
  A signed `Resolution(decision)` instead applies through `resolve`; it never
  becomes a shared change merely because it arrived in a package.
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

Snapshot identities are exact immutable object references. An explicit
in-place restore first records `{operation, safety, target}` in an immutable
journal. Before its terminal `Published` phase it writes a local
`Restore_proof = [1, operation, safety, target]`, after verifying both exact
snapshot closures. A proof is a compaction root for both snapshots until an
explicit forget transition deletes that proof; a published journal without a
matching proof is itself retained. Neither record is project history, package
content, transport state, or semantic intent.

Persistent model, authority, certificate, signed-revision, adoption,
recovery-package, journal, and restore-proof records have a schema version and
canonical encoding; unknown mandatory features and noncanonical encodings are
rejected. Only the mutable
`v4-project-state` head selects a current immutable state object.

## Transport state

`Transport_publication` is a signed immutable courier record, not a project
transition. Its body contains a repository, publisher certificate/device,
sorted parent publication IDs from that device's feed, and one package-manifest
SHA-256 ID. `publication_id(bytes)` is the SHA-256 of its canonical complete
record. A valid feed can have several heads; neither relay nor client adds an
ordering edge or chooses one.

Each local remote has private configuration outside project state and a
versioned local transport section inside the saved state wrapper: opaque
discovery cursor, known publication IDs, announced artifact/revision IDs, and
review-inbox references. It is not package data, authority, or a trust root.

`sync` stages every newly discovered publication package and verifies
publication, authority, signature, causal, and model transitions as one batch.
If any item is invalid, no destination object, project state, cursor, announced
set, or inbox changes. A valid ordinary record applies through `receive`; a
signed resolution applies through `resolve`; valid late records are inbox
references without receipt. Receipt never changes the working tree. Only after
durable receipt does upload begin; upload failure leaves received state intact
and unacknowledged artifacts eligible for retry.

`bootstrap` is not `sync` and does not choose a relay head. A caller names an
immutable `bootstrap-basis-v1` ID and repository ID. The signed basis binds one
package manifest and a portable projection containing only shared model state,
signed records, deliveries, and exact reachable snapshots. The root phrase is
independently checked before destination mutation. The transition replaces
source creator/drafts/checkpoints/pins/usernames with one fresh local creator,
active draft, baseline checkpoint, and local username; shared changes,
resolutions, and deliveries remain distinct. Neither transition scans or
materialises the working tree.

## Advisory runtime state

`Runtime_state` is disposable process observability, not `Project` state. A
Linux daemon may retain only a canonical repository-root reference, process
nonce, watcher condition, explicit task label, and bounded diagnostic result in
private `runtime-state-v1` bytes. It has no edge into checkpoints, shared
changes, decisions, deliveries, authority epochs, transport cursor, package,
or credential state.

The automatic runtime transition is exactly `save`; it therefore creates a
checkpoint only for an observed byte change. Its only network transition is an
explicit operator `daemon sync(remote)` request, which is observationally
equivalent to the existing `sync(remote)` receipt and upload orchestration. It
cannot select a feed or authority head, scan or materialise a working tree
during receipt, or cause an authority transition. Losing runtime state or the
runtime process changes no V4 model state.
