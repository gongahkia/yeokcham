# ADR-052 — V2 local bootstrap authority and role-separated capabilities

- Status: Accepted
- Date: 2026-08-09
- Deciders: maintainer (approved development roadmap)
- Governing issue: [#145](https://github.com/gongahkia/yeokcham/issues/145)
- Related issue: [#136](https://github.com/gongahkia/yeokcham/issues/136)

## Context and problem statement

ADR-045 through ADR-049 provide the V2 encrypted envelope, opaque address,
verified causal ledger, and crash-recoverable object publication. Their durable
adapters deliberately require caller-supplied encryption, address, and public
verification keys. That is the correct separation, but it leaves a local V2
repository unable to prove after restart which injected capabilities belong to
its scratch stream.

V2-014 cannot solve that by adding a plaintext secret file, a mutable
`scratch-head`, or a second device/key hierarchy. The first useful local V2
slice needs one repository, one local device, and one ledger signer without
claiming a user account, team membership, policy, recovery mechanism, or
network authority.

## Decision drivers

- Keep every private capability outside `.yeokcham`.
- Bind an injected local capability to durable, canonical public bytes.
- Keep envelope encryption, opaque addressing, and ledger signing distinct.
- Make an absent or mismatched capability fail explicitly before V2 mutation.
- Preserve ADR-048's causal/divergence model and ADR-049's lack of generic ref
  authority.
- Allow intentional format breaks during pre-user development; no V1 or prior
  V2 root migration is introduced.

## Considered options

### Let V2-014 write a mutable local scratch-head and reuse one key

This would turn recovery metadata into an authority decision, contradict
ADR-048/ADR-049, and blur encryption, addressing, and signing roles.

### Wait for all V2-02 identity, recovery, membership, and key-store work

This delays the local recovery core behind collaboration and browser concerns.
It is broader than the single-device authority V2-014 needs.

### Pull forward a narrow first V2-023 slice

This supplies only the local bootstrap boundary now and leaves platform secret
stores, user identity, enrolment, rotation, recovery, MLS, and policy as later
V2-02 work. This is the selected option.

## Decision outcome

V2 root layout version 3 adds a `.yeokcham/bootstrap/` directory. Its sole
canonical record in this slice is `local-bootstrap-v1.cbor`, a signed CBOR
array containing:

```text
[
  1,
  repository-id,
  device-id,
  ledger-signer-key-id,
  ledger-signer-public-key,
  envelope-key-commitment,
  address-key-commitment,
  mandatory-features,
  signature
]
```

The signature covers the first eight fields under the distinct
`yeokcham:v2:local-bootstrap:1` domain. The signer-key ID must recompute from
the supplied Ed25519 public key. The encryption and address commitments are
SHA-256 values over separate domain strings and their 32-byte secret keys; they
allow a provider to prove it supplied the expected key without writing any
secret to the repository.

`yeokcham_v2_bootstrap` is the pure core. It exposes opaque capability values
that contain three distinct roles: a ChaCha20-Poly1305 envelope key, an HMAC
opaque-address key, and an Ed25519 signing key. Construction rejects equal raw
key material across roles. It creates, decodes, canonicalises, verifies, and
matches the bootstrap record, and can produce the one-entry public-key registry
required by ADR-048.

`yeokcham_v2_bootstrap_store` is the persistent adapter. It accepts only an
already valid V2 root, publishes the signed public record create-only through a
same-directory staging file, fsync, hard-link-without-replace, and directory
fsync sequence, and never overwrites differing bytes. It ignores only its
strictly named regular staging remnants; any other bootstrap entry rejects.
Opening requires an injected capability whose signer and both commitments match
the canonical record.

An empty V2 root is therefore not ready for a bootstrap-aware scratch service.
It becomes one only after bootstrap publication and an external key provider
supplies the matching opaque capability. Existing low-level envelope, ledger,
and transaction adapters continue to require explicit caller-supplied keys;
they do not infer authority from this record. The runtime daemon session
capability from ADR-050 is unrelated and cannot satisfy this boundary.

## Consequences

- #136 can use the existing encrypted-envelope, opaque-address, causal-ledger,
  and transaction primitives after a concrete local provider is connected.
- A local scratch stream must publish an immutable causal advance; it must not
  create a mutable `scratch-head` file. Multiple valid heads remain explicit
  divergence, not an automatic winner.
- The bootstrap signature proves possession of the listed local signing key at
  creation. It does **not** prove a human identity, user ownership, membership,
  authorization, or trust outside the locally selected repository root.
- This is the first, deliberately constrained slice of V2-023, not a parallel
  hierarchy. Later V2-02 work extends these same role boundaries with secure
  providers, public records, enrolment, rotation, and policy.
- Existing V2 layout-version-2 roots are intentionally unsupported in this
  development phase. No migration, compatibility reader, or automatic rewrite
  is provided.

## Model and invariant impact

The new algebraic values are `capability`, `local_bootstrap`, and bootstrap
publication/opening outcomes. Their invariants are:

1. Each role's raw key material differs from every other role.
2. Decoding then encoding a valid bootstrap preserves identical bytes.
3. The public signer key, signer key ID, repository ID, device ID, commitments,
   feature set, and signature are bound in one canonical statement.
4. An injected capability must match all three durable bindings before opening.
5. Bootstrap publication is create-only; a retry with identical bytes is
   idempotent and different prior bytes remain intact.
6. The record is not a user identity, trust map, membership record, mutable ref,
   scratch head, or authorization grant.

## Persistent-format and migration impact

`local-bootstrap-v1.cbor` is a new canonical public V2 root record with a
fixed `v2-local-bootstrap-v1.cbor.hex` golden fixture. It carries no plaintext
secret, source content, ref name, or user metadata. Its mandatory-feature mask
fails closed. Private staging files use the exact
`.local-bootstrap-v1.cbor.bootstrap-<pid>-<attempt>` grammar and are
non-authoritative crash remnants.

The V2 root format changes from layout version 2 to 3. Per approved
development policy, old layout-2 roots fail closed rather than being migrated.
V1 repositories remain outside V2 runtime semantics and receive no conversion.

## Verification

- Unit coverage fixes canonical bootstrap bytes, decode/re-encode stability,
  role-key reuse rejection, signature tampering, capability mismatch, missing
  bootstrap refusal, create-only retry, and no-overwrite behavior.
- A seeded 200-case property proves canonical round trips for arbitrary valid
  repository and device IDs.
- Root-layout generated tests verify the added required directory is never
  repaired implicitly.
- Focused persistent tests use a temporary V2 root and validate opening only
  after create-only bootstrap publication.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` remain required.

## CLI and user impact

No public CLI key-management command is added by this slice. Before a platform
provider exists, applications must inject a matching capability explicitly;
missing capability is an inspectable refusal rather than a generated fallback
or plaintext repository secret.
