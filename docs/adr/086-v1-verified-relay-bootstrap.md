# ADR-086 — V1 verified relay bootstrap

- Status: Accepted
- Date: 2026-08-30
- Implements: GitHub issues #256 and #262

## Context

V1 relay sync is deliberately receipt between already-equivalent replicas. A
new device must not obtain authority from a relay, silently select a feed head,
or import source scratch history as its own. The existing phrase-checked join
only verifies enrolment and initializes from local working-tree bytes; it does
not provide a safe shared-history basis.

## Decision

An existing active device explicitly publishes an immutable
`bootstrap-basis-v1`. Its Ed25519 signature binds the repository, one ordinary
package-manifest-v1 digest, a canonical portable V1 state, and the publisher
certificate. The portable state retains only shared changes, resolutions,
deliveries, signed-record references, delivery baseline, and the exact snapshot
closure they require. It contains a fixed transport placeholder draft solely to
make the model state canonical; target initialization replaces it with one fresh
local draft and discards source creator, drafts, pins, checkpoints beyond named
history, usernames, aliases, credentials, and private capabilities.

A new replica names `--repository` and immutable `--basis`; the relay never
selects a latest basis. It fetches all bytes into staging, verifies ID binding,
canonical encoding, complete package closure, authority graph, active publisher
signature, portable-state/signed-record consistency, and a root phrase compared
independently by the user. Only then does it copy immutable objects and publish
one initial collaborative state. It does not scan or materialise the working
tree. A prompted bearer credential is held transiently and persisted through
the OS credential adapter only after successful bootstrap.

Relay storage gains a create-only `bootstraps/<sha256>` byte route. It has no
listing route because selection must remain explicit. The basis is separate from
ordinary transport publications and does not change package-manifest-v1 or
regular sync feed semantics.

## Invariants and verification

- wrong phrase, repository, signature, certificate, manifest, object closure,
  state shape, or signed-record reference writes no destination object, head,
  alias, credential, or working-tree path;
- bootstrap delivery records remain deliveries and source scratch remains absent;
- receipt has no materialisation dependency and ordinary receipt retains its
  existing no-working-tree sentinel coverage; and
- all new basis bytes are canonical, versioned, SHA-256 addressed, and
  immutable at the relay.

## Consequences

This is a bounded shared-history initialization feature, not a clone protocol.
It does not add end-to-end encryption, relay authorization, online authority,
automatic merge, branch-head choice, or V1–V3 compatibility.

## References

- [The Update Framework specification](https://theupdateframework.github.io/specification/)
- [RFC 8032 §8.3](https://www.rfc-editor.org/rfc/rfc8032.html#section-8.3)
