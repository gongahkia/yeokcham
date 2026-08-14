# ADR-053 — Linux Secret Service custody and bootstrap key handles

- Status: Accepted
- Date: 2026-08-09
- Deciders: maintainer (approved development roadmap)
- Governing issue: [#147](https://github.com/gongahkia/yeokcham/issues/147)
- Supersedes: ADR-052
- Related issues: [#145](https://github.com/gongahkia/yeokcham/issues/145), [#136](https://github.com/gongahkia/yeokcham/issues/136)

## Context and problem statement

ADR-052 established role-separated local capabilities and a signed public
bootstrap, but intentionally left private custody injected. V2-014 needs a
concrete provider before it can bind durable scratch publication to one local
device.

Linux Secret Service is the first platform provider. Its
[specification](https://specifications.freedesktop.org/secret-service/latest/ch01.html)
and [libsecret API](https://gnome.pages.gitlab.gnome.org/libsecret/libsecret-simple-api.html)
make two material constraints explicit: lookup attributes are not secret, and
the convenient libsecret store operation updates an item with matching
attributes. Repository/device/signer identifiers and raw key bytes therefore
cannot be mutable secret-store locators.

## Decision drivers

- Keep private capability material out of `.yeokcham`, command arguments,
  diagnostics, and disk fixtures.
- Return typed locked, unavailable, missing, malformed, and mismatched states
  before a repository opens.
- Preserve a signed public binding without inventing user identity, membership,
  recovery, or scratch-head authority.
- Avoid ordinary accidental updates through libsecret's matching-attribute
  store behaviour.
- Test platform interaction without ordinary tests mutating a desktop keyring.
- Intentionally break pre-user formats rather than retain migration readers.

## Considered options

### Put a private key file beside the bootstrap

This violates the local repository boundary and exposes private material in a
copyable working tree.

### Use repository, device, or signer IDs as Secret Service attributes

These public stable values would cause a repeated enrollment to match and
update an existing service item.

### Bind a random public key handle into the signed bootstrap

This locates one independently generated service item without treating
attributes as secrets or storing raw keys in the repository. It is selected.

### Add a direct libsecret or D-Bus binding now

The current OCaml dependency set has no supported libsecret/D-Bus binding.
Writing one or a partial encrypted D-Bus session broadens this milestone. The
first adapter invokes installed `secret-tool` and `busctl` binaries without a
shell behind an injected runner. A native binding can later preserve this
bootstrap/service contract.

## Decision outcome

The ADR-052 record and filename are replaced by `local-bootstrap-v2.cbor`:

```text
[
  2, repository-id, device-id, local-key-handle, ledger-signer-key-id,
  ledger-signer-public-key, envelope-key-commitment, address-key-commitment,
  mandatory-features, signature
]
```

`local-key-handle` is exactly 32 random bytes. It is public, opaque, bound by
the signature, and hexadecimal only for lookup. It is neither a key nor proof
of authorization. The signature domain is `yeokcham:v2:local-bootstrap:2\0`.
The version-1 record and filename are unsupported development formats and fail
closed.

`yeokcham_v2_secret_service` uses only these Secret Service attributes:

```text
application = io.github.gongahkia.yeokcham
schema      = v2-local-capability-1
key-handle  = lowercase-hex(local-key-handle)
```

The first two are fixed public namespace labels and the last is the signed
public handle. No raw envelope/address/signing key, repository ID, device ID,
or signer appears in an attribute or command argument.

Before lookup or store, the adapter reads the default collection's `Locked`
property through the session D-Bus. `true` returns `Secret_service_locked`; a
missing tool, failed command, unexpected reply, timeout, or excessive output
returns `Secret_service_unavailable`. The adapter does not request unlock.

The private service value is a strict, versioned text record containing hex
encodings of the three private role values. It goes to `secret-tool` only on
standard input. On retrieval it is strictly decoded, reconstructed through
`make_capability`, and checked against every signed commitment and signer
binding. It is not a repository format and has no golden file: even artificial
private values must not be written to disk fixtures or logs.

Enrollment reads an existing handle first. Exact material is idempotent;
different material returns `Secret_handle_in_use` without calling store. An
empty handle is stored before the create-only public bootstrap. A filesystem
failure can leave an unreachable service item, which is not automatically
deleted because a concurrent actor could have enrolled it.

`secret-tool` does not offer atomic create-without-replace. The 256-bit random
handle makes an accidental collision infeasible, but this is not a
cross-process transaction guarantee. A same-handle race can destroy local key
availability; signed commitments make subsequent open fail closed rather than
accept wrong material.

## Consequences

- Linux now has a concrete local custody provider for #145. #136 still needs
  typed encrypted scratch records, a causal publication rule, and transaction
  composition.
- The adapter introduces no user identity, recovery key, sharing, rotation,
  MLS state, browser credential, or mutable scratch head.
- macOS Keychain remains a separate #146 implementation; it may share fixtures
  but not Linux command semantics.
- The external command boundary has no shell, no retained diagnostic text, a
  4 KiB output cap, and a five-second deadline.
- There is no plaintext fallback for an unsupported, locked, or unavailable
  Linux Secret Service.

## Model and invariant impact

```text
Capability = (envelope-key, address-key, signing-private-key)
Key_handle = random 32-byte public locator
Bootstrap_v2 = signed(repository, device, key-handle, signer, commitments)
Custody(key-handle) = encoded(Capability)
```

1. Role bytes remain pairwise distinct on generation and decoding.
2. The signed bootstrap binds one exact key handle to repository/device/signer
   and both key commitments.
3. Attributes are public namespace labels plus that handle only.
4. Private bytes enter platform custody through standard input, never repository
   bytes, command arguments, or disk fixtures.
5. Open requires complete signed-bootstrap matching; every bad custody state is
   an explicit refusal.
6. Service custody and filesystem publication are intentionally non-atomic.

## Persistent-format and migration impact

`local-bootstrap-v2.cbor` and
`v2-local-bootstrap-v2.cbor.hex` supersede ADR-052's v1 record. Version,
handle, feature bits, signer ID, canonical CBOR, commitments, and the new
signature domain all verify before opening. `local-bootstrap-v1.cbor` and its
staging grammar are not read or migrated.

The private `v2-local-capability-1` service value is not a Yeokcham repository
object. Per the approved development policy, old local bootstrap records fail
closed rather than being converted.

## Verification

- Unit tests cover canonical bootstrap bytes, role reuse, tampering, mismatched
  capability, create-only publication, stale staging, and unknown entries.
- Injected shared custody tests cover stdin-only transfer, absence from
  repository bytes/arguments, restart open, locked/unavailable service,
  malformed/mismatched records, and occupied-handle refusal.
- A seeded 120-case property generates repository IDs, device IDs, and key
  handles, then proves enrollment reopens the matching capability.
- Routine tests deliberately do not mutate the host Secret Service. The explicit
  `YEOKCHAM_RUN_SECRET_SERVICE_INTEGRATION=1 make secret-service-integration`
  check creates one random-handle item, verifies enrolment and reopening through
  the production runner, clears only an item it initialized, then verifies the
  missing state. It remains outside normal test aliases. A configured Linux
  implementation needs this evidence before #147 can close, alongside hosted
  evidence deferred by #122.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` remain required.

## CLI and user impact

No public key-management command is added. A future authoring command may use
`create_and_enroll` and must report typed custody failures without printing
private values. There is no automatic fallback, unlock prompt, migration, or
credential export.
