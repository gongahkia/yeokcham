# ADR-083 — V4 device identity, signatures, and verified receive

- Status: Accepted
- Date: 2026-08-27

## Context

V4 currently has useful local change composition, but a device identifier is
only a local model value. A peer therefore cannot prove who authored a
revision, whether that author is allowed in this repository, or whether all
referenced snapshot objects arrived intact. Usernames improve local
readability, but must not become identity or authority.

V2 and V3 contain authority, MLS, and peer protocols. They do not define the
smaller V4 source-control model. Reusing their cryptographic primitive is
appropriate; importing their authority graph, encrypted state, or transport
semantics is not.

## Decision

V4 uses one Ed25519 signing key per device. Its public key deterministically
derives an opaque device identifier; a username remains a separately stored
local display registration. A repository has an opaque repository identifier
and begins with a self-signed administrator device certificate.

Each certificate is a canonical, versioned, domain-separated record containing
repository ID, subject device ID/public key, role (member or administrator),
issuer certificate ID, issuer device ID, and mandatory features. A root
certificate has no issuer and must be self-signed by an administrator device.
Every other certificate must be signed by a device already authorized by an
earlier administrator certificate. Any active administrator may enrol either a
member or another administrator. Certificates are additive and causal; an
incoming order is never treated as authorization.

Each shared V4 revision has a canonical signed envelope. Its signature binds
the repository ID, the complete canonical revision fields, the author's
certificate ID, its author device ID, and fixed signature domain. A verified
revision consequently cannot be transplanted into another repository or
re-associated with another device or certificate.

Private keys are behind a V4 signer-provider interface. The first production
providers use macOS Keychain and Linux Secret Service through opaque local
handles. Private bytes are not V4 state, immutable objects, package entries,
diagnostics, or fixtures. Tests may use an in-memory Ed25519 capability. The
provider interface allows an external signer/agent later without changing
signed bytes.

Revocation and administrator/device key rotation require a causal epoch
successor and are specified as future record kinds. This tranche does not
implement them. Readers reject unsupported revocation or epoch records rather
than accepting a permanently-authorized interpretation.

Offline exchange is a versioned directory package with canonical manifest,
signed identity/certificate/revision records, and immutable object files named
only by object identity. Receive verifies package bytes in staging, including
repository binding, certificate causality, signatures, revision parents, and
snapshot/tree/content closure. It then publishes verified revisions and
derived open decisions in one V4 state-head update. It never modifies a
working tree, draft, delivery, or existing resolution.

## Invariants

1. A device ID matches exactly one Ed25519 public key and is derived from it.
2. A username has no bearing on signature verification, membership, or roles.
3. A non-root certificate signer is an administrator in a causally prior
   verified certificate chain for the same repository.
4. A signature is verified over exactly one canonical preimage and protocol
   domain; unsupported algorithms/features fail closed.
5. A received revision has a valid author certificate, matching author,
   repository, and complete causal revision-parent chain.
6. A received closure names only canonical immutable objects whose identities
   and recursive snapshot references verify.
7. A failed package never advances the V4 state head or mutates the working
   directory.

## Consequences

V4 gains explicit, inspectable authorship and offline collaboration without
introducing trust-on-first-use, a hosted service, automatic merge, or automatic
delivery. Key loss/removal recovery remains deliberately incomplete until the
epoch successor slice is implemented, so V4 does not promise revocation yet.

## Verification

- RFC 8032 Ed25519 test vectors plus generated sign/verify tests.
- Golden canonical identity, certificate, revision-envelope, and package
  manifests; inverse decoders reject reordering and unknown mandatory fields.
- Tests for signature tampering, wrong repository, duplicate/missing
  certificate, unauthorized issuer, invalid causal order, wrong author,
  missing snapshot closure, parent mismatch, retry/idempotence, and
  working-tree preservation.

## References

- [RFC 8032](https://www.rfc-editor.org/info/rfc8032/)
- [RFC 8949](https://www.rfc-editor.org/rfc/rfc8949.html)
- [Git signing format](https://git-scm.com/docs/gitformat-signature)
