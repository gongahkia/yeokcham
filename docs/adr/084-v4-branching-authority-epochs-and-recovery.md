# ADR-084 — V4 branching authority epochs and recovery

- Status: Accepted
- Date: 2026-08-28

## Context

ADR-083 establishes public device certificates and signed revisions, but its
additive membership cannot revoke a compromised device, rotate a key, recover
a sole administrator, or describe concurrent administrator changes. Refusing
all work during such a disagreement would make an authority problem everybody's
problem; treating the branches as an implicit union would silently undo a
revocation.

## Decision

V4 authority is an immutable, signed graph of canonical `Authority_epoch_v1`
records. An epoch names one or more sorted parent heads, the complete resulting
member/administrator/revocation state, a revision frontier, and one recovery
public key. A normal epoch has one explicitly selected parent; when there is a
fork, a lifecycle command must name that parent rather than select one by
default. An explicit reconciliation names two or more sorted selected divergent
heads. Any administrator active in every selected parent may sign it, while
unselected heads remain active. When no administrator is common to the desired
parents, the recovery authority is the only emergency reconciler.

Every signed revision names the authority epoch under which its author was
authorised. Authority branches remain inspectable as distinct heads. Normal
local authoring refuses to select or implicitly union a fork; an explicit
successor reconciliation names every selected parent. Authority disagreement is
shown separately from a content decision; it never selects a winner or changes
the working tree. The CLI exposes this boundary as `--parent EPOCH` for
single-branch lifecycle actions and `authority reconcile --parents EPOCH,EPOCH`
for the multi-parent operation. Signed shared work, signed resolution, and
one-time adoption use `--authority EPOCH` when more than one current authority
head exists.

A signed change record additionally carries one of two signed purposes:
ordinary shared work, or an exact decision ID for a resolution replacement.
Package receipt dispatches through the matching pure model transition. An
unsigned manifest field may never reclassify work as a resolution, and a
resolution record may never be received as a new shared change.

A revocation contains its known sorted revision frontier. A record signed under
an older epoch remains historical proof. If it is new to a receiver and a
current head causally descends from that epoch while revoking its signer, it is
an authority-review item rather than ordinary shared work. A current-head
administrator may make a one-time signed adoption of that exact signed record.
A one-use authorisation similarly binds one device and one exact
revision/change; it grants neither enduring membership nor authority. Key
rotation atomically adds the replacement certificate and revokes the old device
in one successor epoch. Historic records remain verifiable against their named
epoch.

A repository may have one active recovery authority. Recovery material is a
small versioned canonical package encrypted with ChaCha20-Poly1305 under a
random 256-bit secret rendered as a 24-word BIP-39 English mnemonic. It holds
the recovery private capability, never a device or root signing key. Its public
commitment is authenticated by the authority epoch. Recovery creates a new
administrator, revokes the replaced device, and rotates recovery authority.
`init` creates the initial package. `recovery refresh` may write a later
additional copy with the same secret and a fresh nonce, while `recovery use`
replaces the sole active recovery authority and writes its next package before
publishing the successor state.

A new device joins only after the user compares a deterministic 12-word BIP-39
English phrase derived from the root certificate through an explicit domain. The
phrase is a comparison aid, not a secret or credential. Join and ordinary
package exchange carry the complete authority closure.

## Invariants

1. Epoch and parent collections are canonical, duplicate-free, and form no
   cycle; root epochs have no parents and exactly one root administrator.
2. A normal non-root epoch has one explicitly selected current parent. A
   reconciliation has two or more canonical current parents, and its signature
   is valid only from an administrator active in all of them. No branch produces
   an implicit union of roles.
3. A signed revision names exactly one verified epoch and its author is active
   in that epoch and signs whether it is shared work or a named resolution. A
   late revision from a signer revoked by a current descendant head additionally
   needs exactly one current-head adoption before receipt.
4. Revocation changes future ordinary acceptance only. It neither rewrites
   historical signed records nor silently discards late work.
5. Authority review, adoption, and one-use authorisation are durable,
   domain-separated records; each applies to exactly the record it names.
6. Recovery package ciphertext and authenticated data bind its repository,
   active recovery key, version, algorithm, and nonce. A mnemonic is never
   written to project state or exchange packages; test vectors use fixed public
   test material only.
7. A failed join, recovery, epoch import, or package receive leaves the state
   head and working tree unchanged.

## Consequences

V4 gains a flexible small-team trust lifecycle without TOFU, global authority
freezes, automatic permission merges, or a dependence on wall-clock time.
Authority forks remain a human responsibility at their boundary, not a reason
to interrupt unrelated work. This adds public persistent records and requires
new golden, property, two-repository, corruption, and recovery evidence.

## References

- [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032.html)
- [RFC 8439](https://www.rfc-editor.org/rfc/rfc8439.html)
- [BIP-39](https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki)
