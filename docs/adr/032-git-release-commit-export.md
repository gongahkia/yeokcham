# ADR-032 — Deterministic Git release commit export

- Status: Accepted
- Date: 2026-08-05
- Deciders: maintainer (approved 2026-08-05)
- Supersedes: None
- Superseded by: None

## Context and problem statement

M8-08 exports one immutable Paengi release as one independently inspectable Git
commit. ADR-009 makes Git an interchange format; ADR-028 already defines the
immutable `export/commit -> exported-release` mapping. The remaining policy
must define Git commit metadata, target ref, retry, exact tree construction,
and Git's inability to represent nested empty directories without changing the
Paengi release or pretending a Git commit is Paengi history.

Current milestone: M8 Git Bridge. Vertical slice: one verified stored release,
one existing absolute Git repository, one root commit, one deterministic branch
ref, and one ADR-028 mapping. It excludes release sequences, Git parents,
merges, tags, signatures, remotes, Gitlinks, and export of mutable workspaces.

## Decision drivers

- A checkout of the exported commit must match the release final snapshot in
  regular-file bytes, executable mode, symlink target, and tree structure.
- The release remains immutable and Git metadata cannot become Paengi author,
  capsule, revision, release, or intent semantics.
- Retry must either reproduce the same external commit/ref and mapping or fail
  explicitly; no Paengi ref may be updated.
- Git use remains bounded direct argv with structured errors and no shell,
  ambient author configuration, filters, or hooks.
- Existing release, mapping v1-v3, binding, and golden bytes remain unchanged.

## Considered options

### Use ambient Git identity, clock, and default branch

- Minimal caller input.
- Produces a different commit on retry and makes output depend on host state.

### Ask the caller for every Git author, message, timestamp, and ref

- Supports custom presentation metadata.
- Expands the first export API and makes a release-to-commit mapping less
  deterministic without a new persistent export-policy record.

### Deterministic root commit from release data and one fixed ref

- Makes the exported commit reproducible from the release and existing Git
  object format while retaining an explicit, inspectable metadata policy.
- Defers configurable metadata, linear release history, and alternate ref
  policies to a later recorded export-policy decision.

## Decision outcome

Select the third option.

M8-08 accepts a visible, verified Paengi release and an absolute existing Git
repository. It writes exactly one root Git commit whose tree is constructed
from the release final snapshot. The target ref is the create-only deterministic
name `refs/heads/paengi/release-<lowercase-release-id-hex>`.

Git commit metadata is fixed and not user identity: author and committer are
`Paengi Export <noreply@paengi.local>`; both timestamps are the release's
nonnegative `created_at` rendered in UTC. The commit message is the exact
release message bytes when present; an absent message is the UTF-8 fallback
`Paengi release <lowercase-release-id-hex>\n`. This metadata describes an
export operation, not the release's author or a signed assertion. Configurable
metadata is deferred because it requires a durable export-policy record.

The exporter reads the verified release and canonical snapshot objects, writes
raw blobs with filters disabled, constructs Git trees through an isolated
temporary index, creates the root commit through direct argv with an empty
environment plus explicit metadata variables, and verifies the produced commit
and tree. It does not read the Git working tree. Source content used for a
symlink blob is the stored link-target bytes, never a followed link.

Git lacks nested empty-directory entries. An empty root snapshot exports as the
empty root tree; a release containing any nested empty directory fails with a
structured unsupported-representation error before Git ref or Paengi mapping
publication. Gitlinks, unsupported snapshot node kinds, unsafe paths, invalid
release timestamps, malformed Git IDs/output, limits, and process failures
also fail explicitly.

After the commit/tree verifies, the exporter creates the deterministic Git ref
only if absent or already equal to the exact computed commit. It then creates
the existing ADR-028 `export/commit -> exported-release` mapping using the
verified release ID, release stored-object ID, final snapshot ID, repository
object format, and exact commit ID. The Git ref and Paengi mapping binding are
separate visibility points: an interruption after Git ref creation but before
mapping publication is an explicit retryable incomplete bridge state; a retry
must verify the same ref/commit and publish the same mapping or fail.

## Consequences

- One release has a deterministic root-commit export per Git object format.
- A destination ref cannot be overwritten by a different commit; Git objects
  may be unreferenced after a pre-ref failure and are not Paengi state.
- An exported Git commit is inspectable with normal Git tooling, but is not a
  Paengi release replacement and does not establish Git repository identity.
- Nested empty directories cannot be exported in this slice.

## Model and invariant impact

The pure export result is:

```ocaml
type release_export = {
  release : Release_id.t;
  release_object : Stored_object_id.t;
  snapshot : Snapshot.id;
  tree : git_object_id;
  commit : git_object_id;
  mapping : Git_mapping_id.t;
}
```

- `release`, `release_object`, `snapshot`, `tree`, `commit`, and `mapping`
  remain type-distinct.
- The Git tree recursively represents the exact release snapshot, except a
  nested empty directory is rejected before publication.
- A visible export mapping resolves to the verified release object and final
  snapshot named by the root commit's tree.
- Retry cannot advance or mutate a Paengi release, Git mapping, or target ref.

## Persistent-format and migration impact

No new Paengi persistent object, ref, schema, or mapping payload is added.
M8-08 reuses ADR-027 Release v1/binding and ADR-028 Git-mapping v1
`Exported_release` subject; v1-v3 mapping decoders and all current goldens stay
byte-identical. Temporary Git index/message files and destination Git objects
are external interchange artifacts, not Paengi canonical storage.

## Verification

- Unit fixtures: empty/root/nested trees, regular bytes, executable files,
  symlinks, exact/absent release messages, deterministic metadata, restart,
  ref collision, and mapping corruption.
- Bounded generated release snapshots: exact Git checkout oracle and export
  retry determinism for representable trees.
- Failure fixtures: nested empty directory, unsupported nodes, invalid
  timestamps, malformed/limited Git output, process failures, interruption
  before Git ref and before mapping binding, plus no Paengi release mutation.
- Run `git fsck --full` on successful destination fixtures, `make check`, and
  `make property-test PROPERTY_TEST_SEED=17`; record benchmarks separately.

## CLI and user impact

After acceptance, `paengi git export release --repository <absolute-git-directory>
--release <release-id>` reports the Git tree, commit, fixed target ref, and
mapping IDs in hex-safe form. It reports the deterministic metadata policy and
explicit incomplete/retryable state; it does not claim arbitrary Git export
compatibility, configurable authorship, or empty-directory preservation.
