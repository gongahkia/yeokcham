# ADR-029 — Opaque Git imported transitions

- Status: Accepted
- Date: 2026-08-05
- Deciders: maintainer (approved 2026-08-05)
- Supersedes: None
- Superseded by: None

## Context and problem statement

M8-01 imports an exact Git tree to a Yeokcham snapshot and persists an ADR-028
`import/tree -> imported-snapshot` mapping. M8-02 must additionally import a
Git commit and ordered parent identities without treating a Git commit as a
human-authored capsule or revision. ADR-028 v1 only permits
`import/commit -> imported-revision`; that target would fabricate capsule intent
and is therefore unsuitable.

Git commits may have zero or more ordered parents. The direct `cat-file commit
<object>` form returns raw uncompressed commit bytes; parent ordering is part of
the commit representation. [git-cat-file](https://git-scm.com/docs/git-cat-file)
[git-commit-tree](https://git-scm.com/docs/git-commit-tree)

## Decision drivers

- Preserve an imported commit ID, tree ID, exact snapshot, and ordered parent
  IDs without source-intent semantics.
- Keep Git and Yeokcham identities type-distinct and reject malformed input
  before canonical visibility.
- Retain ADR-028 v1 decoding and golden fixtures unchanged.
- Make one-commit import retryable and bounded without importing a repository
  graph or commit metadata prematurely.

## Considered options

### Reuse `Capsule_revision_v1`

- Reuses an existing durable record and ADR-028 v1 mapping subject.
- Requires generated capsule identity, title, description, and intent-like
  operations; violates ADR-009 and M8-06's no-fabricated-intent constraint.

### Store only a commit-to-snapshot mapping

- Minimal persistent surface.
- Loses ordered parent provenance and cannot distinguish a tree state from its
  commit occurrence.

### Add opaque imported-transition records and Git-mapping v2

- Retains exact commit/tree/snapshot/parent provenance while remaining outside
  scratch, capsule, workspace, and release histories.
- Requires one additive Envelope type, a new mapping payload version, bindings,
  typed identities, and retained v1 decoders.

## Decision outcome

Select the third option.

Add Envelope type `Imported_transition = 24` and a type-distinct
`Imported_transition_id`. An `Imported_transition_v1` records provenance only:

```text
imported-transition-v1 = [
  1, imported-transition-id, git-commit-id, git-tree-id, snapshot-id,
  [* ordered-parent-git-commit-id]
]
```

Every Git ID includes its SHA-1/SHA-256 format and raw exact-length bytes as in
ADR-028. The stored tree ID is the tree named by the raw commit header and the
snapshot is the verified result of importing that exact tree. Parent order is
the raw commit-header order. The record contains no author, committer, message,
tag, ref, branch, remote, working-path, capsule, revision, release, or raw
commit bytes.

The logical identity is:

```text
SHA-256("yeokcham:imported-transition:v1\\000" ||
        encode([1, git-commit-id, git-tree-id, snapshot-id, [* parent-git-commit-id]]))
```

The ID excludes itself and observations. Its physical `Stored_object_id`
remains ADR-020's Envelope identity. Visibility is one create-only binding:

```text
.yeokcham/refs/imported-transitions/<lowercase-imported-transition-id-hex>
imported-transition-binding-v1 =
  [1, imported-transition-id, imported-transition-object-id, checksum]
checksum = SHA-256("yeokcham:imported-transition-binding:v1\\000" ||
                 encode([1, imported-transition-id, imported-transition-object-id]))
```

ADR-028 v1 remains unchanged. Add `Git_mapping_v2`, in Envelope type 23,
containing the same v1 fields except its version is `2` and it adds this one
subject:

```text
imported-transition-v1-subject =
  [4, imported-transition-id, imported-transition-object-id]
import/commit -> imported-transition-v1-subject
```

`Git_mapping_id` v2 uses a new domain separator
`"yeokcham:git-mapping:v2\\000"`; its create-only binding uses the existing
versioned binding envelope with a v2 checksum domain. A v1 decoder accepts only
v1 records; a v2 decoder accepts only the stated v2 forms. No v1 record,
identity, binding, or golden byte changes.

M8-02 parses only the leading raw commit header block: exactly one `tree`
header, zero or more `parent` headers in observed order, and syntactically valid
same-format full IDs. It accepts unrelated standard or extension headers,
including continuation lines, without interpreting or storing them. It rejects
missing/duplicate/malformed tree headers, malformed parents, duplicate parents,
self-parent, missing/wrong-type tree or commit objects, output/size limits, and
untrusted paths. Author, committer, message, tags, recursive graph import, and
Git topology reconstruction remain later work.

## Consequences

- Imported commits have inspectable opaque provenance, not inferred intent.
- A parent can be recorded before it is imported; later imports join through the
  same typed Git ID without mutating either record.
- M8-02 imports one requested commit, not an arbitrary graph; a normal Git
  object cannot form a self-cycle, but malformed self/duplicate parent input
  fails closed.
- Importing the tree, publishing the transition, and publishing the v2 mapping
  are separate immutable visibility points. Retrying verifies/reuses exact
  objects or returns a structured mismatch.

## Model and invariant impact

- `imported_transition_id`, Git IDs, snapshot IDs, and stored-object IDs remain
  incompatible types.
- An imported transition’s commit, tree, snapshot, and parent IDs have one Git
  hash format and exact raw lengths.
- Its snapshot resolves to a stored Snapshot whose root was imported from its
  declared Git tree.
- Parent order is significant; parent IDs are unique and never equal the commit
  ID.
- No imported transition can advance or substitute for a scratch checkpoint,
  capsule, capsule revision, workspace, conflict, or release.

## Persistent-format and migration impact

This is additive: Envelope type 24, `Imported_transition_v1`, one new binding
namespace, and `Git_mapping_v2` are new. Decoders retain Envelope types 1–23,
`Git_mapping_v1`, and all current goldens byte-identically. Existing repositories
have no imported-transition bindings. No object or ref is rewritten in place.

## Verification

- Golden tests for deterministic SHA-1 transition and mapping v2 records/bindings,
  plus retained ADR-028 v1 goldens. SHA-256 fixture coverage remains pending.
- Fixtures for root, linear, and merge commits; exact tree snapshot bytes;
  ordered parents; reopen; and equal retry.
- Generated single-parent imports prove snapshot replay, parent identity, and
  retry identity determinism.
- Failure tests cover malformed headers, missing/wrong-type objects, parent
  limits, self-parent input, and corrupt bindings. Binding-interruption coverage
  remains pending.
- `make check` and `make property-test PROPERTY_TEST_SEED=17` pass. Benchmark
  commit import separately; no timing result is a correctness claim.

## CLI and user impact

After acceptance and implementation, `yeokcham git import commit --repository
<absolute-git-directory> --commit <full-git-commit-id>` reports transition,
snapshot, and mapping IDs plus the ordered parent Git IDs. It must explicitly
state that the record is opaque provenance, not a Yeokcham capsule or complete
Git history import.

## Implementation evidence

M8-02 implements the accepted format and command. Focused fixtures cover root,
linear, and merge commits; ordered parent preservation; retry/reopen; malformed
headers; missing/wrong-type parents; parent limits; self-parent rejection; and
corrupt transition bindings. Deterministic SHA-1 fixtures lock transition and
mapping-v2 Envelope/binding bytes; ADR-028's v1 golden remains unchanged.
Generated single-parent commit imports verify snapshot byte/mode materialisation,
direct-parent identity, and retry identity determinism. `make check`
and `make property-test PROPERTY_TEST_SEED=17` pass. SHA-256 fixture coverage
is not yet implemented.
