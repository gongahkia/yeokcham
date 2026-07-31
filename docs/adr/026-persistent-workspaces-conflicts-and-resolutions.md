# ADR-026 — Persistent workspaces, conflicts, and resolutions

- Status: Accepted
- Date: 2026-07-31
- Deciders: maintainer (approved Milestone 5 continuation)
- Supersedes: None
- Superseded by: None

## Context and problem statement

Milestone 5 currently validates a selected set of durable capsule revisions and
derives one deterministic order, but does not persist a workspace, an
application attempt, conflicts, or resolutions. ADR-020 through ADR-025,
their object identities, schemas, refs, goldens, capsule semantics,
scratch-head semantics, and guarded-restore contract are accepted and remain
unchanged.

## Decision drivers

- Keep logical workspace identity, immutable workspace revision identity,
  stored-object identity, application-attempt identity, conflict identity, and
  resolution identity type-distinct.
- Make each selected workspace state independently inspectable and replayable.
- Keep conflicts immutable, local, and usable without blocking unrelated work.
- Publish workspace visibility through one checksummed CAS ref; never use
  last-writer-wins replacement.
- Reuse the guarded scratch materialiser without claiming cross-ref atomicity.

## Considered options

### Mutable workspace document

- Reduces object count.
- Rewrites selected state and conflicts in place, losing immutable history.

### Store only a materialised snapshot

- Makes checkout direct.
- Loses selected revision provenance, local conflicts, and reproducible partial
  application.

### Immutable workspace objects plus a current ref

- Preserves selection history, exact conflict context, and CAS publication.
- Requires versioned codecs, logical/physical link validation, and recovery
  coverage.

## Decision outcome

Add immutable Envelope-1 `Workspace`, `Workspace_revision`, and
`Workspace_attempt` object types. Existing reserved `Conflict` and
`Resolution` types receive their first v1 schemas. No existing object type code,
schema, object ID, ref, or golden changes.

`Workspace_id` is an opaque caller-supplied 32-byte stable logical identity.
`Workspace_revision_id`, `Workspace_attempt_id`, `Conflict_id`, and
`Resolution_id` are 32-byte SHA-256 logical identities over their respective
canonical identity preimages. A `Stored_object_id` remains ADR-020's SHA-256
identity of complete Envelope-1 bytes. Every durable logical revision link
therefore carries its logical identity and verified physical object ID.

All payloads are Profile 1 arrays with schema version `1`, Envelope object
format version `1`, and mandatory feature mask `0`. All unordered collections
are bytewise sorted and unique; ordered operations and resolved application
order retain order. Timestamps are observational metadata and excluded from
logical-ID preimages. No preimage includes its object’s own derived logical ID.

```text
workspace-v1 = [
  1, workspace-id, created-at-unix-seconds,
  initial-name-or-null, initial-description-or-null
]

capsule-revision-link-v1 = [capsule-id, capsule-revision-id, revision-object-id]
workspace-parent-link-v1 = [workspace-revision-id, revision-object-id]
resolution-binding-v1 = [conflict-id, resolution-id, resolution-object-id]
precedence-edge-v1 = [before-capsule-revision-id, after-capsule-revision-id]

workspace-revision-v1 = [
  1, workspace-id, workspace-revision-id, parent-link-or-null,
  base-snapshot-id, [* selected-capsule-revision-link-v1],
  [* precedence-edge-v1], [* resolved-capsule-revision-id],
  [* resolution-binding-v1], provenance-v1, created-at-unix-seconds
]

workspace-attempt-v1 = [
  1, workspace-attempt-id, workspace-id, workspace-revision-id,
  base-snapshot-id, [* ordered-capsule-revision-link-v1],
  starting-checkpoint-id, starting-snapshot-id, [* operation-outcome-v1],
  resulting-snapshot-id, [* conflict-id], created-at-unix-seconds
]

conflict-v1 = [
  1, conflict-id, workspace-id, workspace-revision-id, attempt-id-or-null,
  base-snapshot-id, capsule-id, capsule-revision-id, operation-index,
  conflict-kind, [* affected-path], current-entry-or-null,
  [* candidate-resolution-description], created-at-unix-seconds
]

resolution-v1 = [
  1, resolution-id, conflict-id, workspace-revision-id, attempt-id-or-null,
  selected-action-v1, expected-current-entry-or-null, created-at-unix-seconds
]
```

The workspace-revision identity preimage contains every field above except its
own logical ID and creation timestamp. It includes parent logical/physical
link, base, selected links, precedence, resolved order, resolution bindings,
and provenance. Its decoder verifies canonical ordering, duplicate rejection,
link type/identity agreement, exact required-capsule dependencies,
incompatibilities, cycles, stored-order recomputation, and that
`Requires_release` returns the existing structured unsupported error.

The only mutable workspace state is:

```text
.paengi/refs/workspaces/<lowercase-workspace-id-hex>/current

workspace-current-ref-v1 = [
  1, generation, workspace-id, workspace-object-id,
  workspace-revision-id, workspace-revision-object-id,
  latest-attempt-link-or-null, checksum
]

latest-attempt-link-v1 = [workspace-attempt-id, workspace-attempt-object-id]
```

The checksum is SHA-256 over `paengi:workspace-current-ref:v1\000` and the
same array without checksum. Generation is non-negative and strictly advances.
The ref uses the established repository writer lock, verified expected raw
bytes, same-directory temporary write, file fsync, rename-over, directory
fsync, and CAS. Validated ref directories may be listed; indexes are
rebuildable and non-canonical.

Creating a workspace, enabling/disabling a revision, changing precedence, and
activating a resolution publish fresh immutable workspace revisions before
CAS-updating the current ref. Identical retry is idempotent; divergent logical
workspace-ID reuse and stale refs reject. The current ref is the sole workspace
visibility point.

Pure application uses the existing deterministic dependency order. It applies
capsule operations in that order. A conflicting operation becomes one immutable
conflict value and is not applied; independent operations continue, and later
operations blocked by a prior affected path are recorded explicitly. Outcomes
distinguish exact application, already-satisfied operation, persistent
conflict, blocked dependency, rejected operation, and explicit resolution
action. Exact bytes remain authoritative; no conflict-marker text is written.
The same base snapshot, selected immutable revisions, precedence, resolution
bindings, and mandatory-feature set produce the same state, ordered outcomes,
and conflict values.

`Conflict_v1` has no mutable resolved bit. Its immutable capsule-revision and
operation-index pair identifies the exact stored operation and its
preconditions; the current entry captures the failed application context. A
`Resolution_v1` records the originating revision/attempt, explicit action, and
its expected current entry. V1 implements only the explicit `skip-operation`
action: it has no replacement content, mode, or path and leaves that operation
unapplied. Workspace-revision provenance records its activation. A resolution
rejects when its conflict is no longer an ancestor-context conflict for the
current base and selected revision; an unchanged descendant context may resolve
an unrelated older conflict. Activation is only through a new workspace
revision’s immutable resolution binding, so unrelated conflicts remain present.

Materialisation holds the repository writer lock; verifies workspace ref and
scratch head; scans and safety-checkpoints the working directory; resolves the
immutable revision; computes and publishes immutable conflicts and attempt;
plans, revalidates, materialises with the existing guarded path/symlink
protections, and rescans; then creates/reuses the resulting scratch checkpoint,
CAS-advances scratch head, rereads the expected workspace ref, and CAS-updates
its latest attempt. A guarded-apply failure does not advance the target scratch
head or workspace ref; the prior safety checkpoint can remain as the durable
record of pre-existing work. Immutable attempts/conflicts and a safety
checkpoint may remain unreachable after a crash.

Scratch-head and workspace-ref publication are not a transaction. If scratch
head advances but workspace-ref attempt publication fails, the exact resulting
snapshot remains the scratch head and a retry recomputes and republishes an
attempt; the implementation does not claim cross-ref atomicity or one shared
attempt ID across that boundary.

## Consequences

- Unresolved workspaces remain inspectable and support unrelated scratch work.
- Partial application is explicit and never reported as a full application.
- Every workspace revision and conflict context remains addressable after later
  selection or resolution changes.
- Directory-fsync limitations remain ADR-020/ADR-023’s documented limitation.

## Model and invariant impact

- A workspace has one stable logical identity and immutable revisions.
- Selected revision links resolve to the declared capsule/revision/object tuple.
- A workspace revision’s stored order equals recomputation from its selected
  revisions and explicit precedence; cycles and incompatible dependencies reject.
- Conflict and resolution objects are immutable; activation is a new workspace
  revision, never a mutation.
- Materialisation’s resulting snapshot is exact even when application is
  partial, and failure does not publish either mutable ref.

## Persistent-format and migration impact

This is additive. Legacy repositories simply lack `refs/workspaces/` and the
new object types. ADR-020 through ADR-025 data remains byte-identical. Future
schemas require retained v1 readers/goldens and a new ADR; no in-place rewrite
or migration is introduced here.

## Verification

- Golden fixtures and inverse decoders cover every v1 object and current ref.
- Alcotest covers reopen, immutable revisions, stale CAS, persistent conflicts,
  explicit resolutions, guarded materialisation, and external mutation abort.
- Seed-17 QCheck/state-machine coverage exercises create, enable, disable,
  reorder, materialise, conflict, resolve, and rematerialise.
- Failure tests cover stale refs and external mutation; the two-ref boundary is
  documented rather than transactionally hidden.
- Existing ADR-020 through ADR-025 goldens remain unchanged.

## CLI and user impact

`work create`, `work show`, `work enable`, `work disable`, `work explain-order`,
and `work materialise [--dry-run]` expose durable selection. `conflict list`,
`conflict show`, and `conflict resolve` inspect immutable conflict history and
require an explicit action. No graphical or full-screen UI is added.
