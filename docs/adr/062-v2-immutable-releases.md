# ADR-062 — V2 immutable releases and exact validation linkage

- Status: Superseded by ADR-073
- Date: 2026-08-12
- Deciders: maintainer
- Supersedes: None
- Superseded by: ADR-073
- Governing issue: [#143](https://github.com/gongahkia/yeokcham/issues/143)
- Related decisions: ADR-027, ADR-048, ADR-054, ADR-061

## Context and problem statement

V2 has authenticated exact snapshots, immutable capsule revisions, and durable
workspace attempts, but no release history. V1 release and validation records
cannot be reused because their envelope, object reference, and binding formats
are outside the V2 root. A V2 release must independently reconstruct one final
snapshot, retain exact validation observations, reject unresolved composition,
and expose no partial publication after interruption.

## Decision drivers

- Release verification must use only immutable direct links, never a workspace
  head or a rebuildable index.
- A failed or mismatched validation observation must prevent release visibility.
- Release identity must remain reproducible across an interruption before its
  create-only binding.
- Parent ancestry must be explicit, acyclic, and independently verifiable.
- The first V2 slice must not imply that a caller-provided observation proves
  command execution or human approval.

## Considered options

### Reuse V1 validation and release objects

V1 references, envelopes, and mutable ref files are not V2 repository truth.
A bridge would violate the cutover boundary and make a legacy physical object
authoritative, so it is rejected.

### Make the current workspace head the release source

The head can advance after a release is published. Resolving it during release
verification would make old releases mutable in effect, so it is rejected.

### Run arbitrary validation processes in this slice

A V2 snapshot materialiser, bounded process runner, and platform lifecycle
semantics are a separate boundary. Pulling them into release composition would
broaden this client-neutral slice, so it is deferred. The record below is an
exact caller-provided validation observation, not a claim of runner execution.

### Canonical immutable releases with passed observation links

Store immutable validation observations and releases as typed V2 frames. A
release directly names its workspace revision, verified complete attempt,
parent links, exact final snapshot, and passed observations. This is selected.

## Decision outcome

ADR-054 frame v1 adds two payload kinds:

```text
kind = ... | 11 Validation_evidence | 12 Release
```

`Validation_evidence` records a logical validation identity, one exact snapshot
link, a nonempty caller-supplied check name, `Passed` or `Failed` status, an
observation timestamp, and mandatory feature bits. It is durable inspection
data only; it does not assert that a V2 process runner, signer, or reviewer
performed the check.

`Release` records its logical release ID, ordered direct parent release links,
one exact workspace revision link, one exact workspace-attempt link, base and
final snapshot links, ordered capsule revision links, resolution bindings,
canonical validation-evidence links, optional message, creation time, and
mandatory feature bits. Its logical ID is domain-separated over parent logical
IDs, workspace/revision and attempt logical links, base/final snapshot IDs,
ordered capsule logical links, resolution logical IDs, and message. It excludes
evidence links and observation/creation times; opaque object references remain
required physical verification links but are not logical identity material.

The pure composer rejects missing or duplicated evidence, duplicate parents,
self-parenting, and malformed or noncanonical record fields. The durable
adapter resolves the signed attempt binding and directly replays its workspace
revision. The attempt must contain no conflicts, and its exact base, ordered
capsules, resolutions, and final snapshot must equal the release declaration.
Every evidence link must resolve to a Passed `Validation_evidence` over that
final snapshot. Parent links must resolve to visible immutable releases and
their closure must be acyclic.

The sole visibility point is an expected-absent signed ADR-048 ledger event in
`release-<lowercase release-id hex>` targeting the `Release` frame. All
observation and release objects are create-only and durable before this binding.
An interruption may leave unreachable immutable objects, but no visible partial
release.

## Consequences

- A release is a distinct immutable composition record, not a workspace head
  alias or a release-current pointer.
- Validation linkage is exact but deliberately not an execution, review, or
  cryptographic-attestation claim in this slice.
- Later V2 execution and signing adapters can add observation sources without
  rewriting an existing release.
- V1 release, validation, and attestation objects remain outside V2 repository
  truth.

## Model and invariant impact

```text
verify(release) => replay(release.workspace_attempt) = release.final_snapshot
visible_release(r) => every evidence(r) is Passed and targets r.final_snapshot
release_parent(p) => p is visible and belongs to an acyclic parent closure
```

1. Release creation rejects a replay-invalid or conflict-bearing attempt.
2. Release verification never reads a mutable workspace head or an index.
3. The exact ordered capsules and resolution bindings equal the named workspace
   attempt and revision.
4. A visible release binding names exactly one Release object with the same
   logical release ID.
5. Repeating a visible logical release returns its verified release; a different
   physical target for that logical ID rejects.

## Persistent-format and migration impact

Frame tags 11 and 12 are additive. Tags 0 through 10 and their bytes remain
unchanged; the retained unknown-kind golden moves from tag 11 to tag 13. Every
new record is independently versioned, canonical, feature-gated, and protected
by the ADR-045 encrypted envelope plus ADR-046 opaque address. V2 never reads
or migrates V1 release/validation bytes. The approved V2 development policy has
no user repositories before this issue set closes.

## Verification

- Unit and generated tests cover canonical identity, malformed links, and
  noncanonical/identity rejection.
- Durable tests cover passed/mismatched/failed evidence, missing evidence,
  unresolved conflicts, exact replay after reopen, retry, parent physical-link
  rejection, and interruption before the release binding.
- Golden fixtures cover Validation_evidence, Release, and the shifted unknown
  kind; old object-frame goldens remain byte-identical.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` are required.
- No benchmark applies because this slice makes no performance claim.

## CLI and user impact

No command, materialisation, or process execution is added here. A later V2
client/service boundary will create observations and present release inspection
and verification. This slice makes those later actions depend on explicit,
inspectable immutable records.
