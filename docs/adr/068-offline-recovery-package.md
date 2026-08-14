# ADR-068 — offline recovery package and explicit replacement-device proposal

- Status: Superseded by ADR-073
- Date: 2026-08-13
- Superseded by: ADR-073
- Deciders: maintainer (approved development roadmap)
- Governing issue: [#149](https://github.com/gongahkia/yeokcham/issues/149)
- Related issues: [#145](https://github.com/gongahkia/yeokcham/issues/145), [#148](https://github.com/gongahkia/yeokcham/issues/148), [#122](https://github.com/gongahkia/yeokcham/issues/122)

## Context and problem statement

The V2 repository-authority root can certify devices. Losing every enrolled
device without an independently held root capability would make a repository
unrecoverable; handing that capability to a service or accepting a support-side
reset would create an implicit recovery authority. V2-027 needs a recoverable
offline package without that authority change.

## Decision

The recovery ceremony creates an opaque 32-byte CSPRNG `Recovery_secret`, a
random public 32-byte package ID, and a unique 12-byte nonce. A separate
ChaCha20-Poly1305 key is SHA-256 derived from a recovery-specific domain,
secret, and package ID. The package stores only public bindings and one
authenticated ciphertext:

```text
Recovery_package_v1 = (
  version, package-id, repository-id, user-id, root-key-id, root-public-key,
  encrypted-payload, mandatory-features
)
Recovery_payload_v1 = (version, package-id, canonical-authority, root-private-key)
```

The public header is repeated and checked after decrypting. Changing package ID
changes the derived key; changing any other public binding cannot produce a
payload that passes the strict equality checks. The encrypted payload is a
portable encrypted local artifact, not a repository object and not a service
secret. A service may store or relay the package bytes but never receives the
recovery secret, a root private key, or a plaintext capability.

The ceremony returns the secret in lowercase hex and a 12-word deterministic
verification phrase. The phrase is a SHA-256-derived transcription check and
must be supplied and matched before recovery attempts decryption. It carries
only 60 bits of derived check data and is not a substitute for the 256-bit
secret. Neither secret nor phrase is encoded in the recovery package, a
repository record, log, or fixture.

Recovery validates canonical format and phrase, derives the package key, opens
the authenticated envelope, reconstructs the root capability, and proves every
public authority binding. A wrong secret, wrong phrase, malformed package,
wrong root, or tampered ciphertext is a typed refusal. If all recovery copies
and the recovery secret are lost, the result is explicit irreversible loss;
there is no server reset, password fallback, security question, or implicit
trust path.

The recovered root may create a **proposed** replacement-device certificate
from explicit new device material. It does not publish that certificate, write
a local bootstrap, activate a device, rotate an epoch, revoke a device, or
declare membership. Those remain separate signed authority/ledger and local
custody transitions.

The recovery package has a strict create-only local persistence adapter under
`.yeokcham/recovery/`. It is deliberately separate from the public bootstrap;
interrupted staging is non-authoritative and a different prior package never
overwrites the only recoverable copy.

## Invariants

1. `Recovery_secret`, root private key, derived envelope key, and verification
   phrase are never repository or service fields.
2. The random nonce is used once for its recovery-derived key; retries reuse
   exact existing bytes rather than re-encrypting under the same nonce.
3. Recovery succeeds only if authenticated payload and all package/authority
   bindings match exactly.
4. A phrase check precedes decryption but has no authorization force by itself.
5. Replacement-device output is a signed proposal, not an automatic authority
   decision or a service-side key replacement.

## Verification

- Unit tests cover canonical package bytes, phrase verification, wrong secret,
  tampering, header/payload mismatch, unsupported features, root mismatch,
  replacement certificate construction, and explicit loss.
- Durable tests cover create-only persistence, stale staging, corrupt prior
  bytes, reopen/retry, and no private bytes in the repository bootstrap.
- A seeded property varies recovery secret, package ID, nonce, and repository
  identities, then proves only the matching secret/phrase reconstructs the
  original root and replacement certificate.
- The canonical encrypted package vector contains ciphertext only; its test
  secret and root material never appear in the fixture.

## References

- [NIST SP 800-63B recovery codes](https://pages.nist.gov/800-63-4/sp800-63b.html)
- [RFC 8439 ChaCha20-Poly1305 nonce requirements](https://datatracker.ietf.org/doc/html/rfc8439)
