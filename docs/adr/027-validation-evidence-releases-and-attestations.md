# ADR-027 — Validation evidence, immutable releases, and attestations

- Status: Accepted
- Date: 2026-07-31
- Deciders: task-authorized maintainer
- Supersedes: None
- Superseded by: None

## Context and problem statement

Milestone 6 adds local validation against immutable snapshots and immutable release
history. ADR-020 through ADR-026, including immutable object publication,
logical/physical identity separation, workspace attempts, conflicts,
resolutions, and CAS refs, remain unchanged.

`Workspace_revision_v1` stores a base snapshot but no declared base release.
Release ancestry must never be inferred from a shared snapshot. Consequently,
`Requires_release` cannot be satisfied correctly for durable workspaces under
ADR-026; this ADR records that schema blocker rather than changing v1.

## Decision drivers

- Execute validation only from an exact verified snapshot.
- Bound process time and captured output.
- Keep observations immutable and independent of mutable refs.
- Make release visibility create-only and crash-safe.
- Reproduce a release from immutable declared inputs.
- Keep signatures separate from the release identity.

## Decision outcome

### Validation evidence

Add Envelope-1 object type `Validation` v1. A command specification is a
canonical Profile-1 value:

```text
validation-command-v1 = [
  1, executable-text, [* argument-text], working-directory-components,
  timeout-milliseconds, maximum-stdout-bytes, maximum-stderr-bytes,
  environment-policy, [* environment-addition], retain-output,
  mandatory-features
]
environment-policy = 0 / 1                 ; empty / inherited process environment
environment-addition = [name-text, value-text]
```

The working directory is repository-relative, safe, and may be empty. Argument
order is significant. Environment additions are strictly bytewise ordered and
unique by name. The runner invokes `executable` with its argument vector
directly; a shell exists only when configured as that executable. The v1 runner
accepts non-negative timeout and output limits and rejects malformed commands,
unsafe paths, invalid environment names, duplicate additions, unsupported
versions, and unknown mandatory features.

`Validation_evidence_v1` is immutable:

```text
validation-evidence-v1 = [
  1, validation-evidence-id, snapshot-id, validation-command-v1,
  command-index, status, exit-code-or-null, signal-or-null, execution-error-or-null,
  duration-milliseconds,
  stdout-sha256, stderr-sha256, stdout-truncated, stderr-truncated,
  retained-stdout-object-or-null, retained-stderr-object-or-null,
  environment-fingerprint-bytes-or-null, runner-format-version, observed-at-unix-seconds
]
```

Status is passed, failed, timed-out, or execution-error. SHA-256 digests cover
all observed stream bytes, including bytes beyond retained limits. Retained
output, when requested, is a bounded Content v1 object containing only the
captured prefix. The logical `Validation_id` is derived from a canonical
identity preimage excluding its own ID, duration, and observation timestamp;
the physical `Stored_object_id` remains ADR-020's identity of the complete
Envelope-1 object. Repeated runs can therefore retain separate physical
observations without making timing a correctness input.

The process runner is an injectable Yeokcham-owned interface. The Unix adapter
materialises the verified snapshot into a fresh empty temporary directory,
directly executes the vector, drains both streams with configured bounds,
terminates the spawned process group on timeout where the host permits it, and
removes the temporary directory where possible. Process-tree termination is
best effort on hosts where descendants escape their process group; this is a
documented portability limitation. Command non-zero exit, signal, timeout, and
spawn error are evidence, not Yeokcham failures. Validation does not alter
scratch, workspace, or release refs.

M6-D01 adds an opt-in retention policy at the CLI boundary only:
`validation run --retain-passing-checkpoints`. After immutable evidence is
stored, the policy loads that evidence, requires `Passed`, and appends the
already-defined `Validation_passed validation-id` retention reason to every
scratch checkpoint with the exact evidence snapshot ID. It writes only the
ADR-023 `retention-head` log/ref; it does not advance scratch, workspace, or
release refs. Failed, timed-out, execution-error, and no-exact-checkpoint cases
append nothing. The existing retention reason tag `3` is reused, so no envelope
or schema migration is required. Reapplying the same evidence/checkpoint pair
is idempotent.

### Releases and release bindings

Add Envelope-1 object type `Release` v1:

```text
release-v1 = [
  1, release-id, [* parent-release-id], workspace-id, workspace-revision-id,
  workspace-revision-object-id, workspace-attempt-link-or-null, base-snapshot-id,
  [* capsule-revision-link], [* resolution-binding], final-snapshot-id,
  [* validation-evidence-link], message-or-null, created-at-unix-seconds
]
workspace-attempt-link = [workspace-attempt-id, workspace-attempt-object-id]
validation-evidence-link = [validation-id, validation-object-id]
```

Parent order is significant and canonical as caller-declared. Any future
order-insensitive parent operation must sort IDs bytewise before constructing a
release. `Release_id` derives from the canonical release composition preimage:
parents, workspace/revision/attempt links, base, ordered capsules, resolution
bindings, final snapshot, and message. It excludes its own ID, evidence links,
and observational creation time, permitting a retry after a pre-binding crash
to reuse the same logical release identity. A visible binding chooses the one
complete immutable observation. Release evidence is still verified and all
required commands must pass before publication.

The canonical visibility binding is create-only:

```text
.yeokcham/refs/releases/<validated-lowercase-release-id-hex>
release-binding-v1 = [1, release-id, release-object-id, checksum]
checksum = SHA-256("yeokcham:release-binding:v1\\000" || encode([1, release-id, release-object-id]))
```

Publication holds the repository writer lock, verifies workspace/current
attempt/conflict context, recomputes application, runs required validation,
publishes immutable evidence and Release v1, verifies reproduction, then
creates the binding with expected-absent semantics. Equal retry returns the
already visible release; a different object under the same logical release ID
rejects. A crash before the binding can leave unreachable immutable objects but
exposes no release. Release listing enumerates validated bindings; indexes are
rebuildable and non-canonical. There is no mutable release-current ref.

Every release link is type, identity, and context checked. Reproduction starts
from the recorded base snapshot, reapplies the exact recorded capsule revisions
and resolution bindings in recorded order, and must reach the recorded final
snapshot. Evidence must bind to that final snapshot. Failed or timed-out
evidence remains inspectable but cannot satisfy a required command.

Parent traversal uses a pure resolver seam for synthetic cycle tests. Persistent
readers still reject invalid parent links; a cryptographically valid
content-addressed persistent cycle is not required as a fixture.

### Requires_release blocker

`Requires_release r` is satisfied only when `r` equals the explicitly declared
base release or occurs in that base release's verified transitive parent closure.
It is not satisfied by snapshot equality. ADR-026 has no base-release field,
and release creation cannot reconstruct that fact from `base_snapshot` without
violating the model. Implementing it requires additive `Workspace_revision_v2`
with an optional-or-required typed base-release link plus v1/v2 coexistence,
v2 current refs or a tagged revision link, migration by fresh immutable v2
revisions, retained v1 readers/goldens, and order/application policy that uses
the verified ancestry resolver. The smallest safe design is an additive v2
whose `base` is `Snapshot_id * Release_link option`, leaving v1 unsupported.
Milestone 6 therefore keeps ADR-026's structured `Required_release_unavailable`
error and records this blocker rather than changing its schema. The pure
`Requires_release.satisfied` seam implements exactly the stated base-or-parent
closure rule for callers that already possess a typed base Release ID; v1
workspace selection cannot provide that input.

### Attestations

Add Envelope-1 object type `Release_attestation` (type code 22) v1:

```text
release-attestation-v1 = [
  1, release-id, signer-identity-text, algorithm-identifier-text,
  signature-bytes, signed-at-unix-seconds
]
```

Attestations are separate immutable objects and never alter `Release_v1` or
`Release_id`. V1 supplies an interface and deterministic test signer only; it
does not claim cryptographic authenticity, key management, or a production
signature format.

## Consequences

- Passing validation is bounded observational evidence, not a proof of correctness.
- Releases are immutable and visible only through verified create-only bindings.
- Logical release identity remains distinct from its physical object and from
  evidence observations.
- Process clean-up and descendant termination vary by host capabilities.
- Requires-release dependency support is blocked pending an additive workspace
  schema; no ancestry is inferred from snapshots.

## Model and invariant impact

- Evidence binds one exact snapshot and cannot validate another.
- Output bounds cap retained bytes and Content-object growth.
- Validation never advances canonical refs.
- A Release's declared links resolve exactly and reproduction reaches its final
  snapshot.
- Parent closure is acyclic and resolved only through immutable releases.
- An attestation binds a release identity without changing it.

## Persistent-format and migration impact

This is additive: Validation v1, Release v1, Release_attestation v1, and
release bindings are new. ADR-020 through ADR-026 object bytes, refs, and
goldens remain unchanged. Legacy repositories lack release bindings. Future
format changes require retained v1 decoders/goldens and fresh immutable objects;
no object or binding is rewritten in place.

## Verification

- Golden fixtures and inverse decoders for evidence, Release v1, attestations,
  and release bindings.
- Focused runner tests for pass, fail, signal, timeout, execution error, and
  stream limits with deterministic runner injection.
- Reopen, corruption, interrupted-publication, idempotency, reproduction,
  parent-cycle-seam, and restart/state-machine tests with seed 17.
- Existing ADR-020 through ADR-026 fixtures remain byte-identical.

## CLI and user impact

`validation run`, `release create`, `release show`, `release verify`, and
`release list` expose exact snapshot validation and immutable releases.
Attestation inspection is library-level in v1; production signing is deferred.
