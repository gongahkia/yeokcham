# Project context

Yeokcham explores whether version control can make the everyday recovery loop
simple without pretending that every edit is shared intent or every shared
change is a release. The product is local-first: exact local state and its
proof do not depend on a server.

## The model boundary

Scratch checkpoints answer “can I get my bytes back?” They are automatic,
bounded, and may compact subject to pins and other named protections.

A shared change answers “what do I want another person to consider?” It is an
explicit immutable revision with a signed author and an authority epoch.

A decision answers “which incompatible proposal should apply?” It is durable
and inspectable, never a process error or an automatic merge. A resolution is
a new revision, not a mutation of a candidate.

Delivery answers “what did this repository publish as delivered?” It remains a
separate model transition. Signing, review, transport, and CI do not silently
mean delivery.

## Trust boundary

Device IDs are derived from Ed25519 public keys. Usernames are local display
metadata and have no authority. A public immutable authority-epoch graph makes
enrolment, revocation, recovery, and concurrent administrator changes visible.
There is no trust-on-first-use join: peers compare the root certificate’s
12-word phrase independently.

Revocation is forward-looking. A record remains cryptographically historical at
the epoch where it was valid. If it arrives after a current descendant head has
revoked that signer, receive requires a current-head adoption of exactly that
signed record. This is deliberate human review, not an implicit permission
merge.

## Product posture

V4 is the only active product track. Earlier tracks are available only in Git
history and have no compatibility or migration path. The codebase retains the
unversioned hashing, canonical CBOR, envelope, object store, snapshot,
chunking, testkit, and advisory Linux-watcher foundations because V4 uses them.
