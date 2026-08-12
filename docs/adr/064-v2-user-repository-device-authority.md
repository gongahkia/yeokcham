# ADR-064 — V2 user, repository, and device authority hierarchy

- Status: Superseded by ADR-065
- Date: 2026-08-13
- Deciders: maintainer (approved 2026-08-13)
- Governing issue: [#145](https://github.com/gongahkia/yeokcham/issues/145)
- Related issues: [#146](https://github.com/gongahkia/yeokcham/issues/146), [#147](https://github.com/gongahkia/yeokcham/issues/147), [#149](https://github.com/gongahkia/yeokcham/issues/149), [#151](https://github.com/gongahkia/yeokcham/issues/151), [#153](https://github.com/gongahkia/yeokcham/issues/153)
- Supersedes: None
- Superseded by: ADR-065

## Context and problem statement

ADR-053 deliberately binds one local V2 root to one device capability. It
explicitly does not say who controls that device, whether another device may
join, or how a lost device is revoked. That narrow boundary enabled local
scratch publication, but it cannot support V2-027 recovery: copying the old
capability to a replacement machine would create an indistinguishable duplicate
device, while generating a fresh device has no authority that can enrol it.

Current milestone: V2-02 Device identity and end-to-end encryption. Vertical
slice: define an opaque repository-scoped user root, repository authority, and
device-certificate chain. The chain admits an active device signer only through
an exact user-root signature and records revocation as immutable evidence. It
gives later recovery a well-defined authority to restore and use for a fresh
device enrolment. It does not add human identity, account names, organisation
membership, hosted trust, MLS epochs, key sharing, automatic key rotation, or
network transport.

No dependent implementation begins before this decision is accepted.

## Decision drivers

- Retain ADR-048's rule that a valid ledger signature alone is not authority.
- Preserve ADR-053's separation between public repository bytes and platform
  custody of private material.
- Give replacement-device recovery an explicit authority transition instead of
  duplicating a device identifier or treating a recovery phrase as a signer.
- Keep device enrolment and revocation immutable, canonical, inspectable, and
  causally ordered.
- State the offline limit precisely: revocation evidence cannot stop a lost
  device that has not received it from creating new locally valid signatures.
- Avoid encoding a user name, account, host identity, email address, or other
  personal metadata into repository history.

## Considered options

### Continue to treat each local bootstrap as the whole authority model

This keeps the existing implementation small, but cannot distinguish a copied
old capability from a replacement device, issue a new signer, or revoke one.
It is rejected.

### Make the repository encryption key the user identity and authority

This avoids a separate signing key, but turns a symmetric decryption capability
into an authorization credential, makes rotation ambiguous, and lets every
reader issue device certificates. It is rejected.

### Use a repository-scoped user-root signing key and immutable device certificates

An opaque user root issues public, repository-scoped device certificates. A
certificate binds the existing local capability's public signer and key
commitments to one device ID; a separate immutable revocation record makes its
state explicit. A later recovery package restores the user root privately, then
uses it to create a new device certificate rather than copying a device. This
is selected.

## Decision outcome

The hierarchy is repository-scoped and deliberately pseudonymous:

```text
User_root = (user-id, root-signing-private-key, root-signing-public-key)
Repository_authority = (repository-id, user-id, root-key-id, root-public-key)
Device_certificate = signed-by(User_root,
  repository-id, user-id, device-id, signer-key-id, signer-public-key,
  envelope-key-commitment, address-key-commitment, local-key-handle,
  authority-predecessor, mandatory-features)
Device_revocation = signed-by(User_root,
  repository-id, device-certificate-id, authority-predecessor,
  mandatory-features)
```

`user-id` is the SHA-256 digest of the domain-separated root public key. It is
an opaque stable cryptographic identifier, not a person, account, owner, or
trust decision. The root signing key is an Ed25519 key distinct from every
device ledger signing key and every envelope/address key. It is a narrow
certificate and revocation signer: it must not sign ordinary scratch, capsule,
workspace, release, or transport events.

`Repository_authority` is the immutable first authority record for one exact
repository ID. It exposes only the user ID, root key ID, root public key,
version, and mandatory features. It is signed by the root key under a distinct
domain. It establishes a local trust-on-initialisation anchor; it makes no
global ownership, organisation, account, hosting, or human-identity claim.

Authority records form one encrypted, repository-scoped causal ledger. Its
first event targets the repository authority. Later events target exactly one
device certificate or revocation. The ledger uses the root public key from the
repository-authority record solely to verify authority records. Missing,
malformed, cross-repository, cross-user, duplicate, unknown-feature, invalid
signature, missing predecessor, or divergent authority state rejects the
operation; it never selects an authority head.

The local bootstrap evolves only after the certificate and authority ledger
formats are accepted. It binds its existing repository/device/key-handle/signer
and key-commitment fields to one exact active device-certificate object and one
repository-authority object. Opening a bootstrap requires all of the following:

1. its capability still matches the public bootstrap commitments;
2. the certificate matches every bound public bootstrap field;
3. the certificate is signed by the repository authority's root key; and
4. the complete, nondivergent authority ledger has not revoked that certificate.

An accepted future normal ledger event binds the device-certificate ID and the
authority event it observed. Verification reports that evidence; it does not
invent a total order between independently offline authority and work streams.
An authority revocation prevents new local publication after the revocation is
known. It does not erase a past valid signature, retroactively distinguish a
lost offline device from an earlier state, or select how replicas resolve
competing histories.

V2-027 may later create a recovery package containing only the private user
root and the repository encryption/address material needed to read its
authority records. Recovery generates a fresh device capability and obtains a
new certificate through the restored root; it never copies an old device ID or
device signing key. The package encryption, recovery-secret ceremony,
verification phrase, platform custody, and loss UX are intentionally deferred
to that issue's follow-up ADR.

## Consequences

- A replacement device has a defined cryptographic enrolment path without
  claiming a copied device is new.
- Devices can be explicitly revoked, while historical signatures remain
  verifiable as historical evidence.
- Ordinary V2 history gains an authorization proof only after its format is
  revised; existing V2 ledger event v1 records cannot be silently reinterpreted
  as authorized.
- Offline revocation is evidence delivered to replicas, not a network kill
  switch. A policy or user decision handles a competing stale history later.
- Existing ADR-053 Linux custody remains a device-capability adapter. It must
  receive a separate versioned root-authority custody record before it stores a
  user root key.
- macOS, browser, MLS, member invitation, rotation, hosted authorization, and
  network replication remain separate follow-on work.

## Model and invariant impact

The future algebraic values are `user_id`, `root_signing_capability`,
`repository_authority`, `device_certificate`, `device_revocation`,
`authority_event`, and `authority_state`. They are distinct from account IDs,
organisation IDs, device IDs, device signer IDs, envelope/address keys,
opaque-object references, ordinary ref events, and release attestations.

1. A user ID recomputes only from the canonical root public key under its own
   domain; it is not host- or account-derived.
2. Every device certificate binds one repository, user, device, signer public
   key/key ID, both existing key commitments, and local key handle under one
   exact root signature.
3. Root and device signing keys differ; neither is an envelope or opaque-address
   key.
4. The authority ledger has one valid causal head. Missing or divergent
   authority is a typed refusal, never a last-writer-wins choice.
5. Opening and publication require an active matching certificate; a revoked,
   missing, malformed, or mismatched certificate performs no publication.
6. A recovery secret is neither a device signer nor an authority record. Its
   only future effect is to restore private material that creates a fresh,
   separately certified device.

## Persistent-format and migration impact

After acceptance, the implementation will define versioned canonical encrypted
typed frames for repository authority, device certificate, and device
revocation; it will define canonical authority-ledger scope bytes and exact
signature domains. Bootstrap and ordinary ledger schemas will receive new
versions that bind the corresponding opaque object references and authority
evidence. Every field has a mandatory-feature mask, unknown mandatory features
reject, and every record has an exact golden fixture.

This is breaking development work. Layout-3 bootstrap roots and v1 ordinary
ledger events fail closed for authority-aware operations; there is no migration,
dual reader, in-place rewrite, or compatibility claim before the pre-user V2
format is released. The only copy of a root is never rewritten in place;
publication remains create-only and transaction-backed.

The recovery package format is not decided by this ADR and no recovery secret,
root private key, envelope key, address key, or artificial private material may
appear in a repository fixture, object, command argument, or diagnostic.

## Verification

Required after acceptance:

- Fixed canonical golden fixtures and inverse decoders for authority,
  certificate, revocation, updated bootstrap, updated ledger evidence, and all
  retained prior fixtures.
- Focused tests for user-ID/key-ID recomputation, role separation, certificate
  binding, active/revoked opening, malformed and unknown-feature rejection,
  signer/key/commitment/handle mismatch, and no private bytes in public records.
- Generated tests over bounded authority chains, certificates, revocations,
  missing predecessors, duplicate IDs, divergent heads, stale observations, and
  offline competing histories. Equal valid inputs must give equal authority
  results without selecting a winner.
- Persistent failure tests before and after every immutable object, authority
  event, bootstrap, and transaction publication. Any interruption leaves only
  an explicit valid prefix or inert unreachable objects.
- Platform custody integration tests for the root authority on each supported
  provider; existing device-custody tests continue unchanged.
- `make check`, `make property-test PROPERTY_TEST_SEED=17`, and focused native
  tests for every available provider.

No benchmark is required: this decision establishes an authority model and
format boundary, not a performance claim.

## CLI and user impact

No public user, member, recovery, invitation, or revocation command is added by
this decision alone. Future commands must display the exact opaque user ID,
repository authority, device certificate, authority head, and explicit revoked
or divergent state. They must not claim that an opaque user ID proves a human
identity, that a recovered package transfers ownership, or that an offline
revocation prevented an unseen signature.
