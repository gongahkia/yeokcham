# ADR-0070: Authorize remote device journals with a pinned root registry

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

An Ed25519 signature in a `YKRE` V2 ref event proves only possession of the event's embedded key. A dumb encrypted backend cannot safely decide which device keys are trusted, and accepting every self-declared key would allow any repository-key holder to advance refs.

## Decision drivers

- Preserve every concurrent journal branch.
- Reject unsigned, unknown, revoked, and stale writers before publication.
- Keep the backend untrusted for authorization bootstrapping.
- Use immutable bounded canonical records.

## Considered options

### Backend-discovered root key

This removes configuration but lets a writable backend replace the authorization root.

### Shared repository encryption key as the authorization root

Every device that can read encrypted data could also impersonate an administrator and defeat revocation.

### Caller-pinned Ed25519 root registry

An operator distributes a root public key out of band and keeps the matching signing secret under caller control. Root-signed immutable records define the allowed device keys.

## Decision

Use the caller-pinned root registry. Fixed-width `YKDR` version-1 records form one SHA-256-identified, Ed25519-root-signed sequence chain under encrypted logical backend keys. Registration binds one UUIDv4 device ID to one Ed25519 verifying key. Re-registration and duplicate revocation fail closed.

Revocation includes the device's final accepted `(sequence, event ID)`. Reconciliation accepts only the verified chain prefix through that exact event and rejects all later entries. This prevents a revoked device from advancing refs with a delayed or pre-signed successor after an administrator selects its accepted head.

Remote `YKRE` events must be V2 signed, match a registered key, and satisfy the registry's revocation cap. Fetch returns a resolved state only for one unambiguous continuation; otherwise it returns the base state plus every unresolved event. Publication fetches and reconciles first, requires an exact expected-state match, uses create-only write, and confirms by refetching.

## Consequences

The root public key must be supplied to each trusted client through a channel outside the mutable backend. The core intentionally does not persist the root signing secret or add a CLI key-management surface. Current local `sync` and remote-helper commands remain V1 single-writer paths until they own that operator workflow.

Revocation does not delete ciphertext, revoke a copied repository encryption key, or revoke a provider OAuth token. It prevents trusted clients from accepting new remote ref events beyond the administrator-selected cap. Repository content replication and Drive clone/push are separate unfinished work.

## Invariants

- The backend never supplies a trust root.
- A remote acknowledged ref event is signed by its registered device key.
- A revoked device cannot advance the accepted journal past its recorded cap.
- No divergent or incomplete journal branch is silently selected or deleted.
- Every registry and journal record remains immutable and bounded.

## Compatibility and migration

`YKDR` is a new remote-only version-1 record namespace and does not change local repository bootstrap formats. Existing V1 `YKRE` records remain readable locally but are rejected for remote multi-device publication. No migration is required because no prior remote journal format exists.

## Security and recovery

The root public key is non-secret but must be authenticated by the operator. Root signing material, repository master keys, and OAuth credentials must not be logged. A lost client can rebuild its authorization view by fetching immutable encrypted records and supplying the pinned root public key. A malicious backend can withhold or add ciphertext but causes an explicit conflict or integrity failure rather than a trusted state transition.

## Verification

Core tests cover registry serialization, root-signature rejection, registration, revocation caps, paginated encrypted backend fetch, stale-state rejection before write, and divergent-branch retention. Full core tests and warning-denying clippy run for the implementation.
