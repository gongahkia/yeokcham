# ADR-087 — V1 scoped relay access

- Status: Accepted
- Date: 2026-08-30
- Implements: GitHub issue #258

## Context

ADR-085 used one static bearer secret for an entire relay. That secret could
read and write every repository served by the process and could only be
replaced by restarting it. The relay must remain an untrusted byte courier:
access policy may limit who can use storage but cannot become membership,
authority, revision, decision, delivery, or receipt policy.

## Decision

The relay stores a local `relay-access-registry-v1` beside its immutable byte
directories. It is versioned canonical CBOR and contains only sorted
credential IDs (SHA-256 verifiers of random 256-bit secrets), a repository ID,
canonical `read`/`write` scopes, issue/expiry times, and active/revoked state.
It contains no plaintext secret, project state, package data, publication, or
authority data. The registry is bounded to 4,096 credentials and 1 MiB.

An operator manages it with `relay access issue`, `rotate`, `revoke`, and
`list`. A new credential defaults to thirty days and may specify a shorter or
longer positive lifetime up to one year. Issue and rotation write the secret
only to the controlling terminal, exactly once; normal output contains only a
safe credential ID and expiry. Noninteractive issue/rotation fails. Rotation
atomically revokes the named active credential and issues a replacement with
the same repository and scopes. Revocation is idempotent.

`relay serve` no longer accepts a global token file. The listener reads the
complete access registry for each valid route. `GET` and publication listing
need `read`; every immutable `PUT`, including bootstrap bytes, needs `write`.
It checks access before reading an upload body or calling storage. Atomic
registry replacement makes a request observe either the prior complete policy
or the replacement policy, so revocation and rotation do not require restart.

Missing, malformed, unknown, expired, and revoked secrets receive generic 401
responses. An active secret for the wrong repository or without the needed
scope receives generic 403. A malformed local policy fails closed with 503.
Responses and diagnostics contain neither a secret nor payload/model detail.
The operator may inspect safe IDs, scope, repository, times, and status; the
relay records no content or authority audit trail.

Bearer-secret replay has a limited meaning here. A valid secret is reusable by
its holder, so a copied still-valid secret cannot be distinguished from its
owner. TLS, narrow scope, finite lifetime, rotation, and revocation limit that
exposure. Reuse of an expired, revoked, or rotated-old secret is rejected.
Proof-of-possession, external identity services, and access-token encryption
are separate custody/protocol work and are not introduced here.

## Invariants and verification

- Relay policy is not V1 collaboration state and cannot grant authority or
  affect model transitions.
- Access failure changes no relay immutable object, local project object,
  transport cursor, review inbox, state head, or working-tree path.
- Every HTTP storage/list route has one read/write access check.
- Secrets are never persisted in the registry, project state, package,
  publication, fixture, normal command output, or diagnostics.
- Registry bytes are canonical, versioned, bounded, atomically replaced, and
  covered by a golden fixture.

The suite covers canonical policy bytes, scope, expiry, revocation, rotation,
cross-repository use, denial before immutable write, listener bounds, HTTPS
sync, and the existing receipt no-working-tree-mutation cases.

## Consequences

Existing global `--token-file` relay setups are intentionally replaced. An
operator issues fresh repository-scoped secrets and each client supplies its
replacement through `remote login`. Existing immutable relay bytes remain
unchanged.

## References

- [RFC 6750](https://www.rfc-editor.org/rfc/rfc6750.html)
- [RFC 9700](https://www.rfc-editor.org/rfc/rfc9700.html)
