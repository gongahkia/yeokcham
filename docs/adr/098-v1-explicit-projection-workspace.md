# ADR-098 — V1 explicit projection workspace activation and update

- Status: Accepted
- Date: 2026-09-04
- Deciders: maintainers
- Implements: WS-001

## Context

ADR-086 deliberately makes bootstrap a verified receipt operation: it imports
shared history into a fresh local draft and does not write ordinary source
files. That leaves a new replica with verified bytes but no explicit way to
place its verified projection in an ordinary working root. Treating bootstrap,
receive, sync, or the advisory daemon as an implicit checkout would erase the
receipt boundary and turn remote observation into a source-writing action.

V1's projection is not a clone, a branch checkout, a delivery, or an authority
head selection. It is the exact current projection baseline already verified
by the project model. Open decisions remain visible model data; activation
does not choose candidates or resolve them.

## Current milestone and vertical slice

WS-001 adds `yeokcham workspace activate` and `yeokcham workspace update`.
The slice has these local types:

```text
projection_basis = {
  repository; imported_basis_id; snapshot; canonical_tree; source_fingerprint
}

workspace_projection_receipt = {
  repository; imported_basis_id; snapshot; canonical_tree;
  activation_generation; source_fingerprint
}

activate(basis, destination) -> materialisation_plan | typed_refusal
plan_update(basis, receipt, observed_tree, replace) -> materialisation_plan
                                                        | typed_refusal
```

`imported_basis_id` is the immutable signed bootstrap-basis ID. It is never a
remote alias, URL, credential, feed head, branch, delivery, or authority
selection. The canonical tree and source fingerprint bind the concrete exact
bytes, modes, and symlink targets that were projected. The receipt is local
workspace metadata, outside `Project`, authority, packages, relay data,
bootstrap artifacts, deliveries, and signed records.

The pure transitions return only plans or one of
`Nonempty_destination`, `Dirty_workspace`, `Missing_closure`,
`No_verified_basis`, `Receipt_mismatch`, or `Unsafe_path`. They have no
filesystem or network dependency. A clean receipt identifies exactly one
verified tree; a receipt cannot alter authority or shared history; and an
ordinary update cannot discard uncheckpointed bytes.

## Decision

Successful bootstrap creates a local, canonical, versioned projection-basis
record before it publishes its initial V1 state head. The record names the
verified immutable bootstrap basis and the imported project projection
baseline. It contains no remote URL or credentials. A repository initialized
by another local path has no such basis and workspace activation refuses rather
than guessing that an arbitrary local state is a portable shared basis.

`workspace activate` is the only operation that may materialise this basis
into the bootstrapped ordinary root. The root must contain no ordinary entries:
only the V1 metadata directory created by bootstrap is permitted. The adapter
loads and validates the exact snapshot closure, derives the existing snapshot
materialisation plan, and uses the existing local-service materialisation
primitive. It persists a deterministic pending receipt before writing source,
then atomically publishes that receipt only after source materialisation has
completed. A rerun may resume only this exact pending operation, whose
idempotent writer replaces partial ordinary output. This local pending record
does not change `Project`; activation therefore does not create a checkpoint
for an initially empty root.

`workspace update` is equally explicit. It first scans the ordinary root using
the established `.yeokcham` and `.git` exclusion boundary and compares the
resulting canonical tree root with the activation receipt. A difference is a
`Dirty_workspace` refusal. `--replace` authorizes replacement only after the
existing crash-safe in-place restore path has captured and durably retained the
local safety checkpoint and its proof. Its output includes those identifiers.
The receipt is advanced only after materialisation completes. This is the
existing prepare/apply/materialise/publish/recover restore journal, not an
activation shortcut.

Neither command contacts a relay, creates or signs a revision, selects an
authority head, resolves a decision, infers intent, or calls bootstrap, receive,
sync, or daemon code. Receipt paths remain incapable of ordinary-source
materialisation.

## Persistent-format impact

`projection-basis-v1` and `workspace-projection-receipt-v1` are canonical CBOR
local records under `.yeokcham/workspace/`. Both are create/replace-safe local
metadata records and are excluded from exact source scanning. They have schema
version 1, fixed field order, strict identifier validation, canonical-byte
round-trip checks, and golden fixtures. Unknown schema versions, malformed
identifiers, noncanonical bytes, and incompatible records are rejected.

They are not immutable object-store objects and do not extend the V1 canonical
object format. Replacing a receipt uses a deterministic staged pending file and
atomic rename; it represents only a resumable local prepared operation until
publication. A receipt write failure leaves the preceding published receipt
intact. Basis creation is create-only and collision-safe.

## Verification

Unit coverage exercises activation/update plans and every typed refusal.
Generated exact snapshot cases compare files, modes, and symlinks after
activation and update. Adapter and CLI journeys cover initial activation,
clean update, dirty refusal, `--replace` safety recovery, empty trees,
interruption/restart, receipt-write failure, corrupt/missing closures, stale
or incompatible receipts, and unsafe paths. Each refusal and receipt/closure
failure preserves ordinary source bytes; interrupted replacement is recovered
through the existing restore journal before a receipt is published; interrupted
initial activation is resumed only from its matching pending receipt. Focused
tests and `make ci` are required before WS-001 is marked complete.

## Consequences

A bootstrapped repository becomes usable only when a person explicitly asks to
activate it. This deliberately does not add clone semantics, automatic shared
work materialisation, branch checkout, remote selection, Git compatibility,
or a new authority/history category. JSON output waits for CLI-001's shared
versioned envelope rather than introducing a workspace-specific schema.
