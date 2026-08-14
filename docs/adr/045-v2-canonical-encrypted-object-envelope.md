# ADR-045 — V2 canonical encrypted-object envelope

- Status: Superseded by ADR-073
- Date: 2026-08-07
- Deciders: maintainer
- Supersedes: None
- Superseded by: ADR-073

## Context and problem statement

V2 repository content and metadata must be encrypted before an object can be
published. The decoder also needs a bounded, deterministic wire format and a
forward-compatibility rule that fails before storage publication.

## Decision drivers

- Preserve end-to-end encryption of object contents and metadata.
- Bind every routing-relevant envelope field cryptographically.
- Reject unsupported mandatory capabilities before persistence.
- Keep a small deterministic byte format with a bounded decoder.

## Considered options

### Plaintext object header with encrypted payload

- Benefits: object routing can inspect type and repository fields.
- Costs and risks: leaks precisely the metadata V2 is intended to protect.

### Reuse the V1 encrypted bundle wire format

- Benefits: existing code and tests cover its AEAD primitive.
- Costs and risks: a bundle represents a batch and exposes a repository-format
  digest; it is not an object envelope or a V2 compatibility boundary.

### Canonical per-object authenticated envelope

- Benefits: fixed, bounded, metadata-minimising representation and a direct
  feature-negotiation point.
- Costs and risks: later object addressing and key lifecycle work must supply
  unique nonces and opaque references.

## Decision outcome

Use a canonical CBOR Profile 1 array with exactly five fields:

```text
[1, "chacha20-poly1305", nonce-12, ciphertext-with-tag, mandatory-features]
```

The authenticated associated data is the canonical four-field prefix without
the ciphertext. The fixed schema version, algorithm, nonce, and feature bits
are consequently authenticated. The envelope contains no repository ID, object
type, object name, ref name, author, or other plaintext metadata.

The implementation accepts only ChaCha20-Poly1305 with a 32-byte key and a
12-byte nonce. Mandatory feature bits are nonnegative and must be a subset of
the currently supported mask (zero). The decoder bounds outer bytes,
ciphertext bytes, and tag length; it rejects malformed, noncanonical,
unsupported-version, unsupported-algorithm, and unsupported-feature inputs.
Authentication is checked only by `open_envelope`, before any caller receives
plaintext.

## Consequences

- Future mandatory features require an explicit decoder update; unknown bits
  never degrade to best effort.
- Callers must provide unique nonces for a key. Random nonce generation and
  durable nonce/key ownership are introduced by later device and storage tasks.
- Object addressing, encrypted ref-ledger semantics, and key authorization are
  separate V2-004 through V2-007 decisions.

## Model and invariant impact

`Yeokcham_v2_envelope.t` is abstract. It can only be constructed by `seal` or
validated by `decode`. A decoded envelope has a 12-byte nonce, a ciphertext at
least as long as the AEAD tag and within the configured limit, supported
nonnegative mandatory features, and canonical bytes. A plaintext is returned
only if authenticated decryption succeeds with the supplied key and header.

## Persistent-format and migration impact

This introduces V2 encrypted-object-envelope schema version `1`; its canonical
fixture is `test/golden/v2-ciphertext-envelope-v1.cbor.hex`. It does not change
the V1 object envelope or make it a compatibility path. Unknown mandatory
features, versions, and algorithms fail closed. No migration or rollback is
needed because V2-004 has not yet made these bytes repository objects.

## Verification

- Unit tests assert fixed golden bytes, canonical decode/encode, feature
  rejection, truncation, noncanonical trailing bytes, ciphertext and nonce
  tampering, and wrong-key authentication failure.
- Seeded properties generate bounded plaintext round trips and every proper
  truncation of the golden-shape envelope.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` remain required.

## CLI and user impact

Not applicable. This is a pure wire-format boundary; V2-025 will expose it
through inspectable CLI operations.
