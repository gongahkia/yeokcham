# ADR-043 — Shared-directory encrypted bundle workflow

- Status: Accepted
- Date: 2026-08-06
- Deciders: maintainer (approved 2026-08-06)
- Supersedes: None
- Superseded by: None

## Context and problem statement

ADR-042 defines one caller-keyed encrypted object bundle but deliberately
excludes a file workflow. M10-08 needs a local USB/shared-directory boundary
that makes an already-complete ADR-042 bundle discoverable, inspectable, and
retryable without a network service, mutable-ref transfer, key discovery, or
new repository state.

Current milestone: M10 Local Synchronisation. Vertical slice: a programmatic
shared-directory adapter that exports one explicit object set to a create-only
final file, lists complete versus interrupted partial files, decrypts and
validates one caller-selected final file for inspection, and imports that file
through ADR-042's existing fully-validated create-only transition. It excludes
CLI/key-source conventions, directory watches, auto-import, peer discovery,
transport, ref/divergence reconciliation, sender/recipient identity, signing,
compression, encryption changes, key persistence, partial-file repair, file
deletion/cleanup, and secure deletion. No implementation begins before this
ADR is accepted.

## Decision drivers

- Preserve ADR-042 encrypted bytes, key boundary, verification order, and
  bounded import retry semantics exactly.
- Make only complete files eligible for caller-selected import.
- Expose interrupted publication as inspectable local state without treating it
  as a valid bundle or mutating it in place.
- Avoid a shared-directory cursor, daemon, lock service, or central authority.
- Preserve ADR-020 create-only object publication and no-ref-mutation boundary.

## Considered options

### Direct write to a caller-named bundle file

- Simple API.
- A reader cannot distinguish an interrupted write from a complete bundle and
  a later export could overwrite prior bytes.

### Shared mutable manifest and import cursor

- Could expose progress across devices.
- Introduces mutable shared state, ownership/recovery rules, a new format, and
  coordination semantics beyond this vertical slice.

### Create-only final files plus retained partial files

- Reuses exact ADR-042 bytes; complete files publish atomically while retained
  partials are explicitly non-importable and inspectable by name and size.
- An interrupted import has no cursor but is safely retryable because ADR-020
  object publication is create-only and byte-identically idempotent.

## Decision outcome

Select create-only final files plus retained partial files.

The adapter receives a caller-selected existing local directory, direct
ADR-042 32-byte key, and exact object IDs. It obtains a fresh opaque 16-byte
directory token from the OS CSPRNG and uses lowercase hex in exactly these
filenames:

```text
partial-v1 = .paengi-bundle-v1-<32-lowercase-hex>.partial
complete-v1 = paengi-bundle-v1-<32-lowercase-hex>.peng
```

The token is a non-secret collision-avoidance name component; it is not a key
ID, bundle ID, nonce, object ID, sender/recipient identity, or replay marker.
The complete file's bytes are exactly one `encrypted-bundle-v1` from ADR-042;
the filename is not authenticated bundle metadata and does not affect AEAD
associated data.

`export` first obtains the complete bounded encrypted bytes in memory from the
ADR-042 adapter. It creates one exclusive partial file in the target directory,
writes all bytes, fsyncs that file, then create-only publishes the complete
name without replacement and fsyncs the parent directory. It removes its own
partial only after complete-name publication. A failure leaves no complete file
or one complete exact bundle; an interrupted pre-publication partial remains
for inspection and is never repaired, overwritten, or imported. Name collision
retries are bounded and structured.

`list` reads the immediate directory only, rejects unsafe/unrecognised entry
types structurally, and returns sorted complete and partial descriptors
containing name and observed regular-file byte length. It does not decrypt,
follow links, import, delete, or mutate anything. `inspect` accepts one
caller-selected complete descriptor and direct key, reads it with the existing
bounded regular-file discipline, and calls ADR-042 decode/open only. Its
successful result exposes the sorted exact object IDs and count, not refs,
keys, inferred closure, sender, recipient, or synchronisation state. Partials
are not inspectable as bundles and always reject.

`import` accepts one caller-selected complete descriptor and direct key, reads
the exact bounded regular file, then delegates to ADR-042 import. Thus outer
decode, repository compatibility, AEAD authentication, every plaintext entry,
and Envelope/ID verification complete before the first `Paengi_store.put`.
An interrupted or I/O-failed import can leave only a valid immutable prefix;
retrying the same complete file is the only M10-08 resume operation and is
idempotent. The adapter never creates, reads, updates, reconciles, or deletes a
mutable ref, divergence binding, trust/device record, key record, or shared
cursor.

## Threat model and limits

The shared directory and its filenames are untrusted storage. ADR-042 provides
the bundle confidentiality/integrity boundary only when the caller supplies the
correct secret key and its nonce contract holds. Final-file name, token,
presence, byte length, modification/deletion, and partial-file presence are
visible and unauthenticated metadata. The adapter provides no sender identity,
recipient identity, authorisation, key recovery, password resistance,
rollback/replay prevention, availability, mutual exclusion across processes,
secure deletion, or assurance that filesystem permissions protect bytes.

The adapter reads at most ADR-042's maximum encoded outer-bundle size. It
returns structured errors for missing/non-directory roots, symlinks and other
non-regular entries, unsafe names, file-size or read changes, partial selection,
unsupported/corrupt bundle bytes, wrong key/repository, CSPRNG failure,
collision exhaustion, and all store failures. Authentication failure does not
distinguish an altered file from a wrong key.

## Consequences

- A USB mount or local shared directory can carry independently complete,
  caller-selected encrypted object bundles without a service.
- Users can list partial names/sizes and retry a failed import, but no API
  repairs or resumes an interrupted export byte stream.
- Final files accumulate until an explicit future retention/deletion decision.
- Filesystem permissions, key UX, transfer progress, and cleanup remain outside
  this decision.

## Model and invariant impact

New values are directory token, partial descriptor, complete descriptor, and
inspection result. They are separate from encrypted bundle bytes/key/nonce,
stored object, Envelope, ref, divergence set/binding, ref event, device,
trust map, and repository state.

- A complete descriptor names one exact regular file with a safe v1 name.
- A partial descriptor is never an importable or decryptable bundle.
- A failed inspection/authentication/validation transition calls no object
  publication transition.
- A retry imports only through ADR-020 create-only publication and cannot move
  a mutable ref or select/reconcile a divergence.
- Listing is observational and sorted; it does not make any shared file trusted.

## Persistent-format and migration impact

This adds no Paengi object, Envelope, ref, binding, repository, exchange-frame,
or encrypted-bundle byte format. It adds an external directory naming protocol
for v1 complete/partial file classes; old repositories require no migration.
Retained ADR-042 bundle fixtures remain the complete-file bytes fixture.

A future directory protocol retains v1 listing/import support or explicitly
rejects it before import. It must not overwrite a v1 complete/partial file or
reinterpret the filename as authenticated authority. Shared manifests, cursors,
deletion, cleanup, streaming resume, signing, recipient wrapping, passwords, or
CLI key handling require separate ADRs.

## Verification

- Deterministic filename/list ordering fixtures and retained ADR-042 complete
  bundle bytes; focused partial/final/no-symlink/no-overwrite failure coverage.
- Two-local-repository fixtures for export/list/inspect/import, missing objects,
  retained divergent refs, interrupted export partials, interrupted import
  retry, corrupt final bytes, and unchanged refs/bindings.
- Seeded bounded state-machine properties varying explicit object sets,
  partial/final discovery, collision/retry, import interruption/restart, and
  corruption; rejected files publish no object and retries preserve refs.
- `make check`, `make property-test PROPERTY_TEST_SEED=17`, and the persistent
  format audit.

## CLI and user impact

No CLI or key-source convention is introduced. A future CLI must require an
approved secret boundary, make final/partial state explicit, require the user
to select a file for inspection/import, and not claim that a file is from a
known peer, is replay-safe, repaired, or synchronised a ref.

## References

- [ADR-020 — Stored-object identity and immutable publication](020-stored-object-identity-and-publication.md)
- [ADR-042 — Encrypted offline object bundles](042-encrypted-offline-object-bundles.md)

## Implementation evidence

M10-08 implements `paengi_bundle_directory`, an external directory adapter over
ADR-042 bytes. It adds retained v1 filename ordering, focused
export/list/inspect/import/retry and rejection coverage, and the seeded
`bundle_directory_property_test`.

Verified on 2026-08-06:

```text
make check
make property-test PROPERTY_TEST_SEED=17
```
