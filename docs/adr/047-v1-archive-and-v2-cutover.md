# ADR-047 — Explicit V1 archive and V2 cutover boundary

- Status: Superseded by ADR-073
- Date: 2026-08-09
- Deciders: maintainer (approved 2026-08-09)
- Supersedes: None
- Superseded by: ADR-073
- Governing issue: [#132](https://github.com/gongahkia/yeokcham/issues/132)

## Context and problem statement

V2 is a clean-slate repository format, not a V1 compatibility layer. The
current public `yeokcham init` path is nevertheless hybrid: it writes the V2
root declaration, then invokes the V1 snapshot and scratch adapters. That
produces V1 Envelope-1 objects and `scratch-head` under a root whose `format`
file declares version 2. Consequently, root-format bytes alone cannot safely
classify all existing `.yeokcham` directories as V2 or V1.

V2-010 must make the cutover explicit without silently overwriting, repairing,
or attempting to reinterpret V1 history. Its archive must preserve every
legacy byte and supported filesystem mode independently of the future V2 root.

## Decision drivers

- A V1 repository must never be silently opened as V2 or overwritten by V2
  initialization.
- The archive must remain independently recoverable if V2 initialization or a
  later reset step fails.
- Classification must fail closed for malformed, mixed, or unsupported layouts.
- The boundary must not add a V1 runtime compatibility path to V2.
- Destructive replacement requires an unmistakable caller action.

## Considered options

### Infer legacy state from the root `format` file alone

- Benefits: small implementation and no directory traversal.
- Costs and risks: rejects the actual hybrid root written by the current CLI;
  it would misclassify V1 data under the version-2 root declaration.

### Copy V1 data into a new V2 repository

- Benefits: a user remains in one working directory.
- Costs and risks: creates an unapproved V1-to-V2 semantic migration, doubles
  the scope, and makes an interrupted copy difficult to distinguish from a
  complete replacement.

### Explicit same-parent archive, verification, then fresh V2 initialization

- Benefits: keeps the legacy directory tree byte-for-byte intact, permits an
  atomic same-filesystem relocation, and gives reset a verified recovery point.
- Costs and risks: users must choose an archive name and make an explicit
  cutover decision; cross-filesystem archive destinations are intentionally not
  supported in the first slice.

## Decision outcome

If accepted, V2 introduces a standalone repository-boundary adapter, separate
from the V1 object/scratch store, with the following transitions:

```text
detect(root) = Empty | V2 | Legacy | Mixed_or_unknown | Incomplete
plan_archive(root, archive_name) = checked legacy inventory
archive(plan) = relocated legacy root + archive manifest
reset(plan, confirmation) = archived legacy root + fresh empty V2 root
```

`detect` accepts `V2` only when the version-2 root declaration and every
required root entry are valid and the root contains no recognised V1 objects or
V1 mutable refs. It recognises the existing hybrid form as `Legacy` when its
objects and refs validate under the V1 formats. A malformed, partially
recognised, mixed, symlink-containing, or otherwise unsupported tree is
`Mixed_or_unknown` and rejects before archive or reset. It is never repaired or
guessed into a format class.

The caller supplies one safe, previously absent archive basename in the same
parent directory as `.yeokcham`. Archiving first validates a complete,
canonical inventory of the legacy tree, then atomically renames `.yeokcham` to
that sibling archive path and fsyncs the parent. The archived directory is the
unchanged legacy tree; it remains recoverable by an explicit reverse relocation
outside the V2 runtime. A canonical, versioned `legacy-archive-manifest-v1`
sibling file records sorted relative paths, node kinds, modes, sizes, and
SHA-256 digests (or exact symlink-target bytes where a future supported legacy
layout permits them). The adapter rereads the archive and requires the manifest
to match before it reports archive success or permits reset.

`reset` requires the already verified archive path, the matching manifest, and
an explicit `--confirm-v2-reset` action. It does not delete the archive, mutate
it, or create V2 state before archive verification. It then calls the V2 root
initializer, which creates only the empty V2 root. A failure after relocation
but before V2 publication leaves the independently recoverable archive and no
accepted replacement root; retry is explicit and idempotent.

The public `init` command must use this boundary: empty roots initialize V2
only; legacy or mixed roots return a typed refusal that names the explicit
archive/reset flow. Existing V1 command behavior remains available only until
the accepted cutover adapter replaces the hybrid `init` path. This is not a
V1 migration, import, compatibility mode, or automatic data conversion.

## Consequences

- V2-001 cannot be considered complete while the public `init` command writes
  V1 objects beneath a V2 root declaration.
- V2 ledger and local-authoring work can rely on an unambiguous V2-only root
  only after this boundary is implemented.
- Users retain their legacy repository as a separate archive rather than as a
  live V2 history.
- Cross-filesystem copying, archive compression, V1 data conversion, and
  automatic cleanup of incomplete archives remain out of scope.

## Model and invariant impact

The adapter introduces explicit classification, archive-plan, and reset-plan
values. It must maintain these invariants:

1. A `Legacy`, `Mixed_or_unknown`, or `Incomplete` root never reaches V2
   object, ref, scratch, or workspace transitions.
2. An accepted archive has the same regular-file bytes and modes as the
   preflight inventory, with no followed symlink or skipped path.
3. A reset leaves either the verified archive with no accepted replacement
   root, or the verified archive plus an empty V2 root; it never leaves an
   accepted partially initialized root.
4. Repeating archive or reset cannot overwrite an archive, V2 root, or legacy
   data.
5. The archive manifest is evidence about the external archive, not canonical
   V2 history or a substitute for V1 data.

## Persistent-format and migration impact

`legacy-archive-manifest-v1` is a versioned external recovery artifact, not a
V2 object, ref, ledger event, or repository identity. It requires canonical
encoding, fixed valid and invalid golden fixtures, strict ordering, bounded
paths and sizes, and rejection of unknown mandatory features. The V2 root
format remains unchanged. V1 objects are relocated byte-for-byte and are never
rewritten, re-encrypted, or decoded into V2 objects by this transition.

## Verification

- Unit tests cover V2, historical V1, current hybrid, malformed, mixed,
  incomplete, and symlink-containing roots; every non-V2 classification
  refuses ordinary V2 initialization.
- Golden tests cover archive manifest encoding/decoding, ordering, malformed
  fields, feature rejection, and exact legacy tree inventory.
- Generated tests create bounded V1-shaped directory trees and prove archive
  byte/mode equality, no-overwrite behavior, and reset idempotency.
- Failure injection covers every preflight, relocation, manifest, fsync, and
  V2-publication boundary; reopening must expose only a verified archive, a
  verified V2 root, or an explicit resumable refusal.
- `make check`, `make property-test PROPERTY_TEST_SEED=17`, and focused
  archive/reset tests remain required.

## CLI and user impact

The future CLI exposes explicit archive inspection and reset commands, each
requiring a caller-selected archive name and reset confirmation. `init` no
longer creates a scratch checkpoint or any V1 object after V2 cutover. It
returns a typed, inspectable legacy/mixed-root refusal rather than modifying
the directory. Command spellings and output remain subject to the implementation
issue, but the explicit confirmation and independently recoverable archive are
not optional.
