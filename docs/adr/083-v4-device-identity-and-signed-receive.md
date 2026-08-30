# ADR-083 — V4 device identity, signatures, and verified receive

- Status: Accepted
- Date: 2026-08-27

## Context

V4 currently has useful local change composition, but a device identifier is
only a local model value. A peer therefore cannot prove who authored a
revision, whether that author is allowed in this repository, or whether all
referenced snapshot objects arrived intact. Usernames improve local
readability, but must not become identity or authority.

Earlier product tracks contained authority and peer protocols. They do not
define the smaller V4 source-control model. Reusing a cryptographic primitive
is appropriate; importing prior authority graphs, encrypted state, or transport
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

Each V4 work record has a canonical signed envelope. Its signature binds the
repository ID, the complete canonical revision fields, the author's certificate
ID, its author device ID, fixed signature domain, and whether the record is
ordinary shared work or a resolution of one exact decision. A verified record
consequently cannot be transplanted into another repository, re-associated with
another device or certificate, or reclassified by a package manifest.

Private keys are behind a V4 signer-provider interface. The first production
providers use macOS Keychain and Linux Secret Service. Private bytes are not
V4 state, immutable objects, package entries, diagnostics, or fixtures. The
test-only file provider requires the explicit
`YEOKCHAM_V4_TEST_SIGNER_DIRECTORY` environment variable. ADR-093 extends the
same record-compatible boundary to explicit SSH-agent and non-exportable
PKCS#11 custody; it is authoritative for local provider configuration and
failure semantics.

ADR-084 extends this certificate and receive boundary with causal authority
epochs, forward-looking revocation, exact late-arrival adoption, device
rotation, recovery, and phrase-checked join. It is the authoritative lifecycle
decision; this ADR remains the identity, signing, signer-custody, and baseline
offline-receive decision.

Offline exchange is a versioned directory package with canonical manifest,
signed identity/certificate/revision records, and immutable object files named
only by object identity. Receive verifies package bytes in staging, including
repository binding, certificate causality, signatures, revision parents, and
snapshot/tree/content closure. It then publishes verified shared work or applies
verified decision-specific resolutions, plus any derived open decisions, in one
V4 state-head update. It never modifies a working tree, draft, or delivery.

## Invariants

1. A device ID matches exactly one Ed25519 public key and is derived from it.
2. A username has no bearing on signature verification, membership, or roles.
3. A non-root certificate signer is an administrator in a causally prior
   verified certificate chain for the same repository.
4. A signature is verified over exactly one canonical preimage and protocol
   domain; unsupported algorithms/features fail closed.
5. A received revision has a valid author certificate, matching author,
   repository, and complete causal revision-parent chain.
6. A signed resolution binds exactly one decision ID and is received only
   through the pure resolution transition; it cannot become ordinary shared
   work.
7. A received closure names only canonical immutable objects whose identities
   and recursive snapshot references verify.
8. A failed package never advances the V4 state head or mutates the working
   directory.

## Consequences

V4 gains explicit, inspectable authorship and offline collaboration without
introducing trust-on-first-use, a hosted service, automatic merge, or automatic
delivery. Lifecycle consequences are specified and tested in ADR-084.

## Verification

Implemented focused tests cover certificate/revision canonical round trips,
resolution-purpose binding, signature tampering, causal administrator
enrollment, wrong repository, alternate root, missing snapshot closure,
duplicate revisions, state-wrapper preservation, and working-tree preservation.
The package verifier performs its validation in a temporary store before
imports and state-head publication.

The remaining platform evidence is Linux execution of the real watcher loop;
the Darwin run is not evidence for that behaviour. Further signer providers and
transport require separate decisions.

## References

- [RFC 8032](https://www.rfc-editor.org/info/rfc8032/)
- [RFC 8949](https://www.rfc-editor.org/rfc/rfc8949.html)
- [Git signing format](https://git-scm.com/docs/gitformat-signature)
