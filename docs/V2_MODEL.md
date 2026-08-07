# V2 typed identities and repository state

## Status

V2-002 introduces pure type boundaries only. It does not add key generation,
encryption, persistence, network transport, or authorization.

## Identity types

Repository, organization, account, device, opaque-object, and ref-event
identities are separate abstract types. Each contains exactly 32 arbitrary
bytes. Hex input must be 64 lowercase hexadecimal characters; constructors
reject a wrong length, uppercase input, and non-hex characters.

## Repository-state algebra

`Encrypted_ref_event` contains a typed event ID and a typed opaque object
reference. A `local_state` contains the typed repository and local-device IDs,
canonical object references, and canonical encrypted-ref events. Construction
rejects duplicate or non-increasing object and event IDs. `verify` creates an
opaque `verified_repository_state` only when every event references a known
object.

This is structural verification, not cryptographic validation. V2-003 through
V2-007 add ciphertext envelopes, opaque addressing, key authorization, and the
encrypted ref ledger that will make the later verification claim meaningful.
