# ADR-054 — V2 typed encrypted object frames

- Status: Accepted
- Date: 2026-08-09
- Deciders: maintainer (approved V2-01 continuation)
- Supersedes: None
- Superseded by: None
- Governing issue: [#136](https://github.com/gongahkia/yeokcham/issues/136)
- Related issues: [#127](https://github.com/gongahkia/yeokcham/issues/127), [#128](https://github.com/gongahkia/yeokcham/issues/128), [#145](https://github.com/gongahkia/yeokcham/issues/145)

## Context and problem statement

ADR-045 deliberately encrypts opaque plaintext. ADR-048's first adapter treated
that plaintext as a ref-ledger event unconditionally. That was sufficient while
the only V2 durable value was a ledger event, but it makes an exact scratch
snapshot impossible to publish in the same immutable object namespace: a
snapshot is either rejected as a corrupt ledger or placed in a second namespace
that no ledger target can name.

V2-014 needs an immutable exact snapshot followed by a causal scratch ledger
event. The model needs a typed plaintext boundary before it can add that
publication rule. This is independent of Linux custody and applies to every
future client and platform.

## Decision drivers

- Preserve one encrypted, opaque, create-only V2 object namespace.
- Make object type explicit only after authenticated decryption, never as a
  server-visible path or envelope field.
- Require canonical bytes and fail closed for unknown kinds or features.
- Preserve the distinction between a scratch snapshot and its later causal
  ledger publication.
- Permit the development-only V2 format break approved by the maintainer;
  there are no user repositories to migrate.

## Considered options

### Keep decoding every plaintext as a ledger record

This prevents typed scratch values and makes generic verification conflate a
valid non-ledger object with corruption.

### Store scratch snapshots in a parallel directory

That directory would be outside the opaque object-address model, so a ledger
target could not refer to it without a second identity, publication, and
verification design.

### Canonically frame each decrypted plaintext with its kind

This retains the existing envelope/address/publication rules while permitting
the adapter to select the correct strict decoder after authenticated decryption.
It is selected.

## Decision outcome

Every ADR-045 envelope plaintext is now exactly one canonical
`v2-object-frame-v1` value:

```text
Object_frame = [1, kind, canonical-payload-bytes, mandatory-features]
kind = 0  ref-ledger-event-v1
     | 1  exact-scratch-snapshot-v1
```

`canonical-payload-bytes` is the exact canonical encoding accepted by the
selected payload decoder. Kind `0` contains ADR-048's complete ledger record.
Kind `1` contains `Yeokcham_model.Snapshot` canonical bytes: sorted safe paths,
exact regular-file bytes, executable mode, directories, and raw symlink-target
bytes. Its embedding in the versioned V2 frame gives it an explicit V2 durable
meaning; it is not a V1 stored object.

The frame has an independent non-negative mandatory-feature mask. Readers
reject unsupported bits, unknown kinds, malformed payloads, and any input that
does not re-encode byte-for-byte. The ADR-046 address continues to bind the
complete outer encrypted envelope, hence the frame and its kind.

`yeokcham_v2_object_store` is the generic create-only adapter. It verifies an
address, decrypts and strictly decodes a frame before publication or loading,
and lists only canonical opaque paths. `yeokcham_v2_ledger_store` becomes a
typed view: it accepts only kind `0`, verifies its signature and repository,
and enumerates ledger frames while still rejecting malformed encrypted objects.
It no longer assumes every object is a ledger event.

The next #136 slice publishes kind `1` before a signed kind `0` scratch ledger
event that targets it. This ADR does not select a scratch head, infer intent,
define authorization, or make the scheduler/daemon mutate a repository.

## Consequences

- A valid encrypted scratch snapshot and a valid ledger event can coexist in
  `.yeokcham/objects` without exposing their kinds to unkeyed storage.
- Repository verification can count/validate all objects while causal analysis
  operates only on ledger frames.
- An old development envelope that directly contains a ledger payload rejects;
  no migration reader, conversion, or compatibility fixture is retained.
- Generic object publication stays create-only; an orphan snapshot is a valid
  unreachable immutable object, not a changed scratch history.

## Model and invariant impact

```text
Object_kind = Ledger_event | Scratch_snapshot
Object_frame = (version, kind, canonical-payload, mandatory-features)
```

1. Every decrypted V2 object decodes to one known typed frame and re-encodes
   exactly.
2. A kind determines the only payload decoder; a ledger decoder never accepts a
   scratch snapshot as a ledger event.
3. The opaque object address binds the complete frame through the authenticated
   outer envelope.
4. Exact scratch bytes, modes, directories, and symlink targets remain
   authoritative; semantic sidecars cannot substitute for them.
5. Generic storage grants neither ref selection, key authority, user identity,
   trust, nor repair authority.

## Persistent-format and migration impact

`v2-object-frame-v1` is canonical CBOR inside the existing ADR-045 envelope.
It has schema version `1`, kind codes `0` and `1`, and mandatory feature mask
`0` initially. Golden fixtures cover both frame kinds and malformed/unknown
kind/feature inputs. The earlier development plaintext shape, which was a raw
ledger record, is intentionally unsupported. Per maintainer direction, there
is no migration or old-format fixture because no user data exists before all
GitHub issues close.

## Verification

- Unit tests cover canonical framing, strict type separation, feature/kind
  refusal, address binding, and generic create-only storage.
- Generated tests prove arbitrary exact snapshots survive frame
  encode/decode and remain distinct from ledger payloads.
- Persistence tests cover an interrupted or repeated generic object
  publication and prove no immutable overwrite.
- Golden fixtures cover one ledger frame, one scratch snapshot frame, and fixed
  invalid frame categories.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` are required.

## CLI and user impact

No CLI command is added. The frame is an internal durable boundary. Future
inspection may identify a verified object kind only after decryption; it must
not present a causal ledger result as a selected scratch head.
