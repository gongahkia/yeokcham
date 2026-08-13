# ADR-071 — V2 MLS member invitations and device join

- Status: Accepted
- Date: 2026-08-13
- Deciders: maintainer (approved development roadmap)
- Governing issue: [#152](https://github.com/gongahkia/yeokcham/issues/152)
- Related issues: [#151](https://github.com/gongahkia/yeokcham/issues/151), [#153](https://github.com/gongahkia/yeokcham/issues/153), and [#122](https://github.com/gongahkia/yeokcham/issues/122)

## Context and problem statement

ADR-070 creates one local MLS member but deliberately has no invitation,
credential authority, lifecycle record, or device join transition. V2 must add
members without treating an MLS Basic credential as a person, an implicit trust
decision, or a plaintext recovery key.

The only authorization role that the current V2 authority model can prove is
the repository authority root. There is not yet an active, causal policy-role
ledger. Inventing additional invitation roles here would make an unsupported
authorization claim.

## Decision

The repository authority root is the sole invitation issuer in this vertical
slice. It signs a canonical `Mls_invitation_v1` over the repository-derived
GroupID, recipient device ID, issue and expiry timestamps, an encrypted joined
MLS snapshot, and mandatory features. The record identity is SHA-256 over its
canonical unsigned bytes; the signature is separately domain-separated.

The secure runtime creates the recipient key package, adds it by value to an
MLS Commit, applies the issuer's pending commit, processes the resulting
Welcome with the recipient key package still in runtime memory, and returns
only the resulting opaque issuer and recipient snapshots plus commit/Welcome
commitments. It checks that both reloaded snapshots contain their requested
Basic credential. The runtime never writes a repository path, a key package,
or a plaintext secret.

The recipient snapshot is encrypted with the existing V2 envelope under a
32-byte invitation secret. That secret is a caller-held capability exchanged
out of band; it is never encoded in an invitation or membership event. This
uses the established ChaCha20-Poly1305 envelope and no new primitive.

The root also signs canonical encrypted `Mls_membership_event_v1` records for
issued, revoked, and accepted lifecycle events. Acceptance takes the complete
event history, rejects a missing issued event, expiry, revocation, duplicate
accepted event, duplicate issued event, invalid signature, and noncanonical or
foreign bytes. It decrypts and canonical-decodes the recipient state, checks
repository/GroupID/recipient bindings, and asks the MLS runtime to reload it
before creating the accepted event. Therefore no history event itself advances
MLS membership; only the verified MLS Add/Commit/Welcome transition does.

For this first policy, the root signs acceptance too. This is intentionally a
local-controller transition rather than a distributed invitation pickup API:
V2 does not yet have a device-signing authority, authenticated transport, or a
causal policy-role evaluator suitable for a remote recipient signature.

Durable records are create-only canonical files:

```text
.yeokcham/mls-invitations/<invitation-id>.cbor
.yeokcham/mls-membership-events/<event-id>.cbor
```

Publication uses `O_EXCL`, mode `0600`, same-directory staging, file `fsync`,
hard-link publication, and directory `fsync`. Exact retries are idempotent;
different existing bytes, corruption, symlinks, unknown entries, and malformed
filenames fail closed. The V2 root validator allows only 64-character lowercase
hex record names and the adapter's strict private staging grammar.

## Alternatives considered

- Let any existing MLS member issue invitations: rejected because MLS roster
  membership is not an authorization-policy evaluator.
- Put a recipient private key or invitation secret in the record: rejected
  because it creates plaintext durable key material.
- Use an MLS application message as the invitation transport: rejected because
  V2 has no authenticated message transport or remote-device custody path yet.
- Store a custom encrypted group-key blob: rejected because actual MLS
  KeyPackage, Add, Commit, Welcome, and Join processing is required.
- Silently replace the issuer snapshot after a join: rejected because durable
  group-state advancement needs its own crash-safe compare-and-publish adapter.

## Invariants

1. Only the public root/key ID anchored by the supplied repository authority
   can issue, revoke, or accept an invitation in this slice.
2. An invitation binds exactly one repository-derived GroupID, recipient
   device ID, issue time, expiry, encrypted recipient snapshot, and signature.
3. Invitation secrets, MLS snapshots, key packages, MLS signing keys, and
   exporter secrets are not plaintext durable records.
4. A valid acceptance is possible only from an open history and a runtime-
   verified recipient snapshot containing the invited device credential.
5. Membership-event history records lifecycle facts; they do not supersede or
   fabricate MLS membership state.
6. Persistent records are canonical, bounded, create-only, and never replace
   divergent or corrupt final bytes.

## Persistent format and compatibility

Both records are version-1 canonical CBOR and reject unknown mandatory
features. They include the existing versioned V2 envelope as encrypted payload
bytes. V2 remains a development format: there is no migration from an earlier
invitation record, and old roots without these optional namespaces remain valid.

## Verification

- Rust tests exercise real MLS Add/Commit/Welcome join and reload both members.
- Unit tests cover signed encrypted join, wrong secret, expiry, revocation,
  replay, tampering, unauthorized root, durable exact retry, corruption, and
  unknown durable entry refusal.
- A seeded property varies repository and device IDs and proves issuer and
  recipient snapshots reload after the real transition.
- `make test`, `make property-test PROPERTY_TEST_SEED=17`, and `make check`
  run the locked runtime and project-wide gates.

## Consequences

This establishes a cryptographically checked root-only invitation vertical
slice. It does not establish remote invitation delivery, device identity beyond
the opaque Basic credential, role delegation, removal/MLS epoch recovery,
server recovery keys, implicit trust, a CLI command, or crash-safe replacement
of the issuer's durable group snapshot.

## References

- [RFC 9420 — The Messaging Layer Security (MLS) Protocol](https://www.rfc-editor.org/rfc/rfc9420.html)
- [mls-rs Client API](https://docs.rs/mls-rs/latest/mls_rs/client/struct.Client.html)
- [mls-rs CommitBuilder API](https://docs.rs/mls-rs/latest/mls_rs/group/commit/struct.CommitBuilder.html)
