# ADR-070 — V2 repository MLS bootstrap

- Status: Accepted
- Date: 2026-08-13
- Deciders: maintainer (approved development roadmap)
- Governing issue: [#151](https://github.com/gongahkia/yeokcham/issues/151)
- Related issues: [#150](https://github.com/gongahkia/yeokcham/issues/150), [#152](https://github.com/gongahkia/yeokcham/issues/152), [#195](https://github.com/gongahkia/yeokcham/issues/195), and [#122](https://github.com/gongahkia/yeokcham/issues/122)

## Context and problem statement

V2 needs a repository-scoped MLS group before it can exchange encrypted
metadata with explicitly invited devices. The local bootstrap already binds one
repository and device to a device-envelope key, but must not become a second
membership system or retain plaintext MLS secrets.

## Decision

The constrained Rust runtime creates one `mls-rs` group per repository. Its MLS
GroupID is fixed as:

```text
SHA-256("yeokcham:v2:mls-group:1\0" || repository-id)
```

The initial MLS roster has exactly the bootstrap device's opaque 32-byte Basic
credential. This identifies a local member only; it is not a remote identity,
trust, or invitation assertion. The runtime reloads a snapshot only when its
GroupID and sole initial credential equal the requested group/device values. It
then derives a 32-byte, domain-separated MLS exporter secret. For the initial
state, the roster has exactly that one credential; later valid states must
contain the wrapper's local device credential. Yeokcham uses
that secret only as the existing V2 ChaCha20-Poly1305 envelope key for
repository metadata. A sole MLS member does not process an application message
sent to itself, so exporter-derived encryption is the defined bootstrap path.

The OCaml model wraps the opaque MLS-library snapshot in canonical
`Mls_group_state_v1` bytes binding repository ID, derived GroupID, device ID,
snapshot, and mandatory features. The local adapter immediately encrypts those
bytes with the existing bootstrap device envelope key and stores exactly one
create-only envelope at:

```text
.yeokcham/mls-group/group-state-v1.cbor
```

Publication uses an `O_EXCL`, mode-`0600`, same-directory staging file,
`fsync`, hard-link publication, and directory `fsync`. Staging files are not
membership state. Reads require the durable bootstrap to equal the injected
capability, then require envelope authentication, canonical group decoding,
repository/device equality, and runtime MLS reload before returning a state.
The V2 root validator recognises only this directory's final file and strict
private staging grammar.

## Alternatives considered

- Store a plaintext MLS snapshot beside the public bootstrap: rejected because
  a snapshot includes group private state.
- Define a Yeokcham-specific group-key format: rejected because MLS supplies
  the group state and exporter mechanism.
- Encrypt metadata as an MLS application message: rejected for bootstrap
  because the only initial member cannot process its own message.
- Treat Basic credentials as authenticated remote identities: rejected because
  Basic credentials are opaque and unauthenticated; V2-030 owns later explicit
  invitation and credential policy.

## Invariants

1. Repository GroupID is deterministic and cannot be selected independently.
2. A state is usable only if both its outer repository/device bindings and its
   reloaded MLS GroupID/local device credential match.
3. Repository storage contains no plaintext MLS snapshot, exporter secret, or
   bootstrap capability.
4. A missing final state means no visible local membership; staging alone is
   never recovered as membership.
5. Existing divergent, foreign, corrupt, or unknown local state is rejected
   without replacement.

## Persistent format and compatibility

`Mls_group_state_v1` and the outer V2 envelope are canonical, versioned bytes.
The new optional `.yeokcham/mls-group` namespace is accepted only with the
strict final/staging grammar. No old-format migration exists: V2 is still a
development format, while unknown mandatory features and noncanonical bytes
reject. The MLS-library snapshot remains an opaque runtime-owned value and is
not a Yeokcham source format.

## Verification

- Rust tests create, reload, derive twice, and refuse foreign group IDs, wrong
  device credentials, and corrupt snapshots.
- OCaml unit tests cover canonical fixture decoding, encrypted create-only
  publication/reopen, exporter metadata round-trip, foreign repository,
  wrong-device, corruption, and interrupted staging.
- A seeded property varies repository/device IDs and proves create, reload,
  exporter encryption, and decryption.
- `make test`, `make property-test PROPERTY_TEST_SEED=17`, and `make check`
  build and test the locked runtime alongside the existing project gates.

## Consequences

This establishes only initial local group bootstrap. It adds no server recovery
key, remote transport, invitation, rotation, revocation, automatic trust,
plaintext key persistence, CLI command, or claim that a Basic MLS credential
authenticates a person or device owner.

## References

- [RFC 9420 — The Messaging Layer Security (MLS) Protocol](https://www.rfc-editor.org/rfc/rfc9420.html)
- [mls-rs group API](https://docs.rs/mls-rs/latest/mls_rs/group/struct.Group.html)
- [mls-rs storage documentation](https://docs.rs/mls-rs/latest/mls_rs/index.html)
