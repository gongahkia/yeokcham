# ADR-046 — V2 keyed opaque object addresses

- Status: Accepted
- Date: 2026-08-07
- Deciders: maintainer
- Supersedes: None
- Superseded by: None

## Context and problem statement

An unkeyed hash of ciphertext is deterministic but lets a server or observer
correlate equal encrypted bytes across repositories. V2 needs client-held,
repository-bound object references before it can publish encrypted envelopes.

## Decision drivers

- Server-visible references must not reveal plaintext identity or object type.
- Equal bytes in repositories with distinct address keys must not correlate.
- Address derivation must be deterministic, independently verifiable by an
authorized client, and domain separated from all other hashes.

## Considered options

### SHA-256 of ciphertext

- Benefits: simple content addressing.
- Costs and risks: cross-repository equality and replay are directly visible.

### Random server-assigned object IDs

- Benefits: prevents equality correlation.
- Costs and risks: server participates in identity allocation and clients cannot
independently verify an address before publishing.

### Client-held keyed address

- Benefits: deterministic opaque references, no server key material, and
repository binding.
- Costs and risks: key derivation, recovery, and rotation require later
explicit protocols.

## Decision outcome

Derive each V2 `Opaque_object_ref` as:

```text
HMAC-SHA-256(address-key,
  "yeokcham:v2:opaque-object-address:1\\0" || repository-id || envelope-bytes)
```

The address key is exactly 32 bytes and separate in the type system from the
envelope encryption key. `verify` recomputes the address and returns a typed
mismatch for a wrong key, repository identity, ciphertext envelope, or replay.

## Consequences

- The hosted server stores a 32-byte opaque reference but cannot derive it from
guesses without the client-held address key.
- Nonce changes alter the envelope and therefore the address. This is expected;
addressing does not deduplicate plaintext.
- Key hierarchy, rotation, recovery, and durable object publication remain
separate V2 tasks.

## Model and invariant impact

Address keys and opaque references are abstract types. A derived reference is
always exactly the SHA-256 digest length. Verification binds one canonical
envelope byte sequence to one typed repository ID and one client-held key.

## Persistent-format and migration impact

The domain separator and HMAC input are a persistent addressing rule. The
fixture `test/golden/v2-opaque-object-address-v1.hex` fixes the initial vector.
There is no V1 compatibility or migration path; V2-005 will persist references
only after its ref-ledger format is defined.

## Verification

- Unit tests cover the fixed vector, deterministic derivation, different key
and repository separation, and wrong-key, wrong-repository, and replay
verification failures.
- Seeded properties generate envelope payloads and check deterministic,
key-separated addresses.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` remain required.

## CLI and user impact

Not applicable. V2-004 is a pure client-side addressing boundary.
