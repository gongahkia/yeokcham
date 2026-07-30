# ADR-0059: Add caller-supplied Ed25519 signatures to ref events

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

`YKRE` V1 records detect replacement and stale transitions with canonical SHA-256 binding, but provide no evidence of who created a transition. The security design requires standard Ed25519 signatures without conflating a device UUID, a signing key, and writer authorization. The current milestone needs a bounded, verifiable format and core API before persistent key management and multi-device policy can safely be added.

## Decision drivers

- Preserve exact V1 bytes and recovery behavior.
- Use a mature standard implementation compatible with Rust 1.85.
- Verify hostile record bytes before materialization.
- Do not imply authorization without a device-key policy.

## Considered options

### Option 1: caller-supplied signed-event foundation

Add a V2 event with an embedded public key and detached Ed25519 signature. Accept a caller-owned signing key only at the core API boundary; defer key generation, storage, registration, authorization, and revocation.

### Option 2: persistent device-key and authorization subsystem

Build encrypted key storage, device enrollment, authorization records, and revocation together with the event format. This needs recovery and multi-device decisions not yet implemented.

## Decision

Use Option 1 with `ed25519-dalek` 3.0.0, pinned exactly in the workspace. Keep V1 unchanged: version `1`, zero feature flags, no signer, no signature. Add V2: version `2`, required feature bit `0` set, zero optional feature flags, raw 32-byte Ed25519 verifying key after the complete canonical ref state, and raw 64-byte detached signature after that key.

The detached signature covers the canonical bytes from `YKRE` through the embedded verifying key. It excludes the signature, `YKRH` footer, and SHA-256 record checksum. Decoding checks bounded canonical structure, the outer checksum, the verifying-key encoding, and the signature before an event can be materialized. Unknown versions or feature sets fail closed.

Expose redacted `RefEventSigningKey` and `RefEventVerifyingKey` wrappers. `RefEvent::new_signed` creates V2 events; `verify_signature` checks the embedded key and `verify_signature_with` permits a caller-selected key. `LocalRepository::append_signed_ref_state` appends a checked signed local transition. Existing `sync` and remote-helper code keep creating V1 events.

## Consequences

Tampering remains detectable even if an attacker recomputes the public SHA-256 checksum. A caller can pin or compare an expected public key before assigning meaning to a signature. V1 recovery remains supported and legacy operations do not acquire accidental key dependencies.

This is not a key-management or authorization feature. Yeokcham neither generates nor persists private keys; it does not associate keys with device IDs, decide whether a signer may advance a repository, revoke signers, or enable untrusted multi-device sync. Those concerns require separate versioned authorization and recovery design.

## Invariants

- V1 encodings retain version `1` and zero feature bits exactly.
- A V2 signature binds repository ID, device ID, sequence, predecessor IDs, and complete successor ref state.
- A decoded V2 event is signature-verified before ref-state materialization.
- Private-key debug output is redacted and secret material has no logging API.
- Signature validity is never treated as authorization.

## Compatibility and migration

`YKRE` is independently versioned within existing repository-format V2 stores; no bootstrap or repository-format migration is required. Older readers reject V2 events as unsupported instead of silently interpreting them as V1. Existing V1 events and storage remain readable. A future authorization format can add policy without changing the meaning of V1 or unregistered V2 records.

## Security and recovery

The format uses the standard Ed25519 primitive through `ed25519-dalek`; it does not construct a new signature scheme. The public key is metadata, while the caller retains private-key storage and backup responsibility. Both signature verification and checksum validation precede trust in decoded V2 data. Loss of the caller-held key does not prevent reading or recovering existing events, but it prevents creation of further events under that key.

## Verification

Core tests prove V1 header compatibility, V2 canonical round trips, embedded-key verification, wrong-key rejection, and signature rejection after an attacker recomputes the outer checksum. Repository tests prove a signed event is persisted and materialized. The existing ref-event fuzz target exercises the same decoder boundary.
