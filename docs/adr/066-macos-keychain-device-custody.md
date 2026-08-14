# ADR-066 — macOS Keychain device custody and explicit enrollment

- Status: Superseded by ADR-073
- Date: 2026-08-13
- Superseded by: ADR-073
- Deciders: maintainer (approved development roadmap)
- Governing issue: [#146](https://github.com/gongahkia/yeokcham/issues/146)
- Related issues: [#145](https://github.com/gongahkia/yeokcham/issues/145), [#147](https://github.com/gongahkia/yeokcham/issues/147), [#122](https://github.com/gongahkia/yeokcham/issues/122)

## Context and problem statement

The signed V2 local bootstrap binds a public random key handle to one local
capability, but deliberately does not encode private role bytes. ADR-053 made
that boundary concrete on Linux through Secret Service. V2-024 needs the
equivalent macOS boundary without treating a repository object, a command-line
argument, or a custom crypto format as key custody.

The current `Bootstrap.capability` needs the three raw private role values:
the existing pure V2 envelope/address operations consume symmetric bytes and
the ledger signer is implemented through Mirage Crypto. A macOS `SecKey` that
cannot be externally represented therefore cannot silently stand in for this
capability. In particular, exporting a Secure Enclave or smart-card key to
make it fit the current model would defeat the platform boundary.

## Decision drivers

- Keep capability bytes out of `.yeokcham`, repository objects, diagnostics,
  command arguments, and disk fixtures.
- Use the Data Protection Keychain so macOS applies lock-state accessibility
  controls without enabling iCloud synchronisation.
- Require explicit enrolment and removal; neither operation may invent a
  signed join, revocation, membership decision, or mutable repository state.
- Return locked, unavailable, missing, malformed, occupied-handle, and
  non-exportable-key states distinctly and fail closed.
- Keep routine verification platform-independent while retaining an opt-in
  native macOS integration check.

## Considered options

### Store private bytes beside the local bootstrap

This breaks the custody boundary and makes repository copies contain local
private material. It is rejected.

### Create or export a `SecKey` automatically

The current capability model cannot use a non-exportable `SecKey` for all
three roles. `SecKeyCopyExternalRepresentation` is specifically allowed to
fail for Secure Enclave and smart-card keys. Automatic export would either
fail unexpectedly or turn a non-exportable platform key into ordinary process
and filesystem material. It is rejected.

### Use a Data Protection Keychain generic-password item

The item can hold one opaque, strict local capability record encrypted by
Keychain at rest. `kSecUseDataProtectionKeychain=true`,
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and
`kSecAttrSynchronizable=false` give an explicitly local, lock-aware item.
This is selected.

## Decision outcome

`yeokcham_v2_keychain_custody` is a pure adapter core with injected lookup,
create-only store, and removal operations. It shares the signed bootstrap
contract with ADR-053 but has no Linux command semantics. Its private item
value is the strict `v2-local-capability-1` record already defined by ADR-053;
the value is private platform state rather than a repository or IPC format.
No private golden fixture is added.

`yeokcham_v2_macos_keychain` is a macOS-only Security.framework bridge. It
uses one generic-password item per public handle with:

```text
service = io.github.gongahkia.yeokcham.v2.local-capability
account = v2-local-capability-1/<lowercase-hex(key-handle)>
sync = false
data-protection-keychain = true
accessible = when-unlocked-this-device-only
```

The service/account values contain no repository ID, device ID, signer, or
private role bytes. `SecItemAdd` is create-only; a duplicate is read back and
accepted only when the strict capability bytes are exact. Removal deletes only
that local Keychain item. It never edits a repository record or emits an
authority/ledger event.

When data lookup misses, the native bridge probes only a namespaced legacy
`SecKey` application tag. A present key whose external representation fails is
reported as `Keychain_non_exportable_key`; an exportable but unsupported key
item is also rejected. The adapter never returns, logs, or persists either
representation. The normal generic-password path is the explicit local
fallback for the present raw-capability model; replacing it with provider-held
signing would require a future capability-model change.

The bridge maps `errSecInteractionNotAllowed`, authentication failure, and
user cancellation to `Keychain_locked`, maps service-not-available and other
unexpected Security.framework statuses to `Keychain_unavailable`, and never
attempts to unlock Keychain. Malformed/mismatched data is rejected after the
pure core reconstructs and checks it against the signed bootstrap.

## Consequences

- macOS gains explicit local enrolment/open/removal mechanics, but no CLI,
  server recovery, user identity, membership, remote sharing, or implicit
  trust decision.
- An enrolled device reopens after process restart if its Keychain item is
  available; private capability bytes are not repository persistence.
- A locked or unavailable login Keychain does not prompt, retry through a
  plaintext store, or open the repository.
- A failed bootstrap publication can leave a Keychain item without a usable
  repository, as with ADR-053. The adapter does not automatically delete it.
- The native integration test mutates one random Keychain item and is opt-in;
  Linux cannot verify Security.framework compilation or runtime behaviour.

## Model and invariant impact

```text
Keychain_locator = (fixed-service, versioned-account(Key_handle))
Keychain_custody(Key_handle) = encode_v1(Capability)
Bootstrap = signed(repository, device, Key_handle, signer, commitments)
```

1. Only the signed public 32-byte key handle selects local custody.
2. Private capability bytes are neither repository bytes nor public locator
   attributes.
3. Open succeeds only if the recovered capability satisfies every bootstrap
   commitment and signer binding.
4. Locked, unavailable, missing, malformed, mismatched, occupied, and
   non-exportable states all refuse opening or enrolment explicitly.
5. Enrolment and removal change local Keychain state only; signed repository
   authority changes remain a separate transition.
6. The cross-service Keychain/bootstrap sequence is non-atomic and never
   overwrites a repository bootstrap or a different occupied capability.

## Persistent-format and migration impact

The repository bootstrap format remains `local-bootstrap-v2.cbor` unchanged.
The Keychain value reuses the strict versioned local-capability text record and
is intentionally not a repository artifact or fixture. The public Keychain
account grammar is covered by a deterministic golden vector. There is no
reader for legacy `SecKey` material and no automatic migration.

## Verification

- Unit tests use an injected Keychain backend to prove local enrolment/reopen,
  repository-byte exclusion, locked/unavailable/non-exportable refusal,
  create-only occupied handling, malformed/mismatched data refusal, and local
  removal without repository mutation.
- A seeded generated test varies repository ID, device ID, and public key
  handle and proves same-process-recreated service state reopens the matching
  capability.
- The public account grammar has a canonical golden vector; no fixture contains
  raw private capability material.
- `YEOKCHAM_RUN_KEYCHAIN_INTEGRATION=1 make keychain-integration` is an
  explicit macOS-only test that creates one random item through Security.framework,
  reopens it, removes only that item, and verifies the missing result. It is
  outside normal aliases because it mutates the caller's Keychain.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` remain required.

## CLI and user impact

No public key-management command is added. A future explicit enrolment command
may use this adapter and must expose the typed error without printing private
bytes. It must not create a signed repository join/removal merely because a
local Keychain item was added or deleted.
