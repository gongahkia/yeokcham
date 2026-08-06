# ADR-042 — Encrypted offline object bundles

- Status: Accepted
- Date: 2026-08-06
- Deciders: maintainer (approved 2026-08-06)
- Supersedes: None
- Superseded by: None

## Context and problem statement

ADR-038 transfers immutable objects over an interactive transport but deliberately
excludes encryption. M10-06 needs a bounded offline file that can carry an
explicit immutable object set through untrusted storage or hand-off without
copying mutable refs, ref events, trust maps, private device capabilities, or
transport state. The file must reject before local publication when its key,
format, integrity, or object contents are invalid.

Current milestone: M10 Local Synchronisation. Vertical slice: one encrypted,
recipient-less, caller-keyed offline bundle containing canonical exact
Envelope-1 object bytes. It excludes passwords and KDFs, recipient public-key
wrapping, key IDs, key storage/discovery/rotation/revocation, sender identity
or signatures, compression, streaming, transport, ref exchange/reconciliation,
consensus, background sync, CLI mutation, and secure deletion. No implementation
begins before this ADR is accepted.

## Decision drivers

- Preserve ADR-020 object identity and create-only publication exactly.
- Authenticate both encrypted payload and clear compatibility metadata before
  an import can publish any object.
- Keep keys separate from immutable objects, bundle bytes, repository state,
  environment lookup, and command-line history.
- Bound allocation, object count, object bytes, and restart work.
- Avoid unapproved cryptographic dependencies: the installed
  `mirage-crypto` 2.2.0 provides RFC 8439 ChaCha20-Poly1305 AEAD and the OS
  CSPRNG adapter is already used by ADR-040.

## Considered options

### Password-encrypted bundles

- Familiar for manual file exchange.
- Requires an approved memory-hard KDF, salt/parameter policy, password UI,
  and recovery/threat model not present in M10-06.

### Per-recipient public-key envelopes

- Can distribute one bundle to several recipients.
- Requires recipient discovery, key lifecycle, sender authentication, and a
  wrapping format before Paengi has those authority decisions.

### Caller-held symmetric key and authenticated encrypted container

- Reuses an installed standard AEAD with one narrow key boundary and no key
  metadata.
- Requires callers to deliver a 32-byte key out of band; it provides neither
  recipient management nor sender identity.

## Decision outcome

Select caller-held 32-byte symmetric keys and an authenticated encrypted bundle
container.

`encrypted-bundle-v1` is not a Paengi Envelope and is never stored as an
immutable Paengi object. Its canonical Profile-1 outer container is:

```text
encrypted-bundle-v1 = [
  1, "chacha20-poly1305", repository-format-sha256,
  nonce-96, ciphertext-with-tag, mandatory-features
]
bundle-aad-v1 = encode([
  1, "chacha20-poly1305", repository-format-sha256,
  nonce-96, mandatory-features
])
```

V1 requires the algorithm text exactly `"chacha20-poly1305"`, all mandatory
features zero, a 32-byte SHA-256 repository-format digest, and a unique 12-byte
nonce. `ciphertext-with-tag` is the exact output of RFC 8439
ChaCha20-Poly1305 over the canonical plaintext with `bundle-aad-v1` as
associated data. A bundle key is exactly 32 opaque bytes supplied directly by
the caller. It is neither serialised, derived from a password, given a key ID,
looked up from a repository, logged, nor retained after the call. The production
export path obtains each nonce from the OS CSPRNG; it does not accept caller
nonces or attempt a durable nonce registry. Reusing a key/nonce pair is outside
the V1 contract and is a structured exporter failure only when detected inside
one invocation.

The canonical plaintext is:

```text
encrypted-bundle-plaintext-v1 = [
  1, [* strictly-ascending (stored-object-id, exact-envelope-1-bytes)],
  mandatory-features
]
```

The entry list has 0–4,096 unique raw-ID-ordered entries. Each entry ID is 32
bytes and each byte string must be one exact canonical Envelope-1 encoding with
ADR-020 `stored-object-id(envelope-bytes) = entry-id`. V1 permits at most 128
MiB total encoded plaintext bytes, including all Envelope and control bytes;
the ciphertext-with-tag is at most that limit plus the 16-byte AEAD tag. It
performs no compression, decompression, re-encoding, graph traversal, or
inference of object closure.

Import first bounds and canonically decodes the outer container; verifies the
repository digest against the local exact format bytes; validates key/nonce
sizes; and authenticates/decrypts using the full canonical header as associated
data. It then bounds and canonically decodes all plaintext entries and verifies
every ID, Envelope, version, feature bit, checksum, and duplicate/order rule
before the first call to `Paengi_store.put`. Only after complete validation does
it publish each object through ADR-020's existing create-only path. A later I/O
failure can leave a valid immutable prefix; retry with the same bundle is
idempotent. Import never creates, reads, updates, reconciles, or deletes a
mutable ref, divergence binding, trust map, device declaration, or key record.

Wrong key, failed authentication, noncanonical CBOR, unsupported version/
feature/algorithm, wrong repository, invalid nonce/key size, bounds breach,
malformed plaintext, object ID mismatch, invalid Envelope, duplicate/order
failure, and publication failure are structured outcomes. Authentication failure
does not distinguish a wrong key from altered ciphertext.

## Threat model and limits

Given correct RFC 8439 implementation, a unique nonce for the supplied key, and
the caller keeping that key secret, the AEAD is relied upon for confidentiality
of plaintext object bytes and integrity of the authenticated header/payload.
The clear outer fields reveal the format version, algorithm label,
repository-format digest, nonce, and ciphertext length. V1 does not provide
sender identity, recipient identity, authorisation, forward secrecy, key
recovery, password resistance, replay/rollback prevention, metadata-length
hiding, traffic analysis resistance, secure deletion, multi-party key sharing,
or object/ref selection. A successfully imported object is not evidence of who
created it, who may read it, that it is current, or that any ref was
synchronised.

## Consequences

- Users can exchange one bounded explicit immutable object set as an offline
  encrypted file when they already have a 32-byte out-of-band key.
- Corruption and unauthenticated data fail before publication; valid immutable
  objects published before a later storage failure remain safely retryable.
- Files cannot be content-addressed as canonical Paengi objects because a fresh
  random nonce changes ciphertext; object identities inside remain unchanged.
- Password UX, recipient wrapping, signing, and key lifecycle remain explicit
  future decisions.

## Model and invariant impact

New values are bundle key, nonce, authenticated header, ciphertext, bundle
plaintext, object entry, import plan, and structured bundle error. They are
separate from stored object, stored-object ID, Envelope, exchange session,
mutable ref, divergence set/binding, ref event, trusted key map, device
identity, checkpoint, capsule, workspace, conflict, and release.

- An import plan contains only exact validated immutable object bytes.
- A failed outer authentication or plaintext validation calls no object
  publication transition.
- Publication is ADR-020 create-only and byte-identically idempotent; no bundle
  outcome alters a mutable ref or selects divergence.
- The same plaintext/key with different generated nonces may yield different
  valid bundle bytes; canonicality applies to header and plaintext, not random
  ciphertext equality.

## Persistent-format and migration impact

This is additive after acceptance: one versioned external bundle format, exact
bundle and plaintext fixtures, and no new Envelope type, object, ref, binding,
repository-format, exchange-v1 frame, device, or ref-event bytes. Existing
repositories need no migration and do not store bundle keys or files.

A later bundle version retains v1 decoding/fixtures or explicitly rejects v1
before import. It never rewrites a bundle's encrypted bytes, an immutable
object, or a mutable ref in place. Password/KDF, recipient-wrapping, signing,
compression, streaming, or key records each require a separate ADR and
compatibility analysis.

## Verification

- Exact outer/header/plaintext fixtures, RFC 8439 AEAD vectors, and inverse
  canonical decoding; ciphertext fixtures use a fixed test vector only, while
  production export uses OS CSPRNG nonces.
- Two-local-repository fixtures for empty/equal/divergent explicit object sets,
  export/import/reopen/retry, distinct generated bundle bytes, and unchanged
  refs/divergence bindings.
- Focused failures for wrong key, altered nonce/header/ciphertext/tag, wrong
  repository, invalid key/nonce, unsupported feature/algorithm/version,
  malformed/noncanonical plaintext, duplicate/order, ID/Envelope mismatch,
  limits, and injected publication interruption.
- Seeded bounded state-machine properties varying object sets, delivery order,
  duplicate objects, export/import/restart/failure points, and corruption;
  rejected imports have no publication and retries preserve object/ref
  invariants.
- `make check`, `make property-test PROPERTY_TEST_SEED=17`, retained fixtures,
  and persistent-format audit.

## CLI and user impact

No CLI or key-source convention is introduced in M10-06. A later CLI may accept
an explicit caller-provided key through an approved secret-handling boundary and
report structured export/import facts. It must not claim that a bundle is from a
known sender, addressed to a known recipient, password-protected, replay-safe,
or synchronised a ref.

## References

- [RFC 8439 — ChaCha20 and Poly1305 for IETF Protocols](https://www.rfc-editor.org/rfc/rfc8439.html)
- [RFC 5116 — An Interface and Algorithms for Authenticated Encryption](https://www.rfc-editor.org/rfc/rfc5116.html)

## Implementation evidence

None; implementation is blocked pending ADR acceptance.
