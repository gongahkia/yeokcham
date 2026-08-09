# V2 typed identities and repository state

## Status

V2-002 introduces the shared type boundaries. V2-005 adds a canonical,
encrypted, create-only causal ref-ledger record. It still does not add key
ownership, trust, enrollment, authorization, private-key storage, mutable ref
selection, or network transport.

## Identity types

Repository, organization, account, device, opaque-object, ref-event, and
signer-key identities are separate abstract types. Each contains exactly 32
arbitrary bytes. Hex input must be 64 lowercase hexadecimal characters;
constructors reject a wrong length, uppercase input, and non-hex characters.

## Repository-state algebra

`Encrypted_ref_event` contains a typed event ID and a typed opaque object
reference. A `local_state` contains the typed repository and local-device IDs,
canonical object references, and canonical encrypted-ref events. Construction
rejects duplicate or non-increasing object and event IDs. `verify` creates an
opaque `verified_repository_state` only when every event references a known
object.

This is structural verification, not cryptographic validation. V2-003 through
V2-004 provide ciphertext envelopes and opaque addressing. The structural
`Encrypted_ref_event` remains a V2-002 scaffold; it is not the V2-005 ledger
record.

## Causal encrypted ref ledger

ADR-048 defines the immutable plaintext event as:

```text
[1, repository-id, ref-name, signer-key-id, predecessor-or-null,
 target-opaque-object-ref-or-null, mandatory-features, event-id, ed25519,
 signature]
```

The first seven fields are canonical CBOR. `event-id` is SHA-256 over a
domain-separated copy of those unsigned bytes; Ed25519 signs a distinct
domain-separated concatenation containing that ID. A `ref-name` is bounded,
safe UTF-8 and has no filesystem-path meaning. A target is a distinct wrapper
around a 32-byte opaque object reference.

Verification uses a bounded, canonical caller-supplied map from signer-key ID
to 32-byte public key. It can return `Cryptographically_valid` or
`Unknown_signer`; neither result grants trust, membership, ownership, or
permission. A valid set is evaluated without mutation: every non-root event
needs a known predecessor in the same repository/ref, duplicate IDs and cycles
reject, and same-predecessor children are a sorted explicit divergence set.
The result is a sorted set of concurrent heads, not a chosen mutable current
ref.
