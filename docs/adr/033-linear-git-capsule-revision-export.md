# ADR-033 — Deterministic linear Git capsule-revision export

- Status: Proposed
- Date: 2026-08-05
- Deciders: maintainer
- Supersedes: None
- Superseded by: None

## Context and problem statement

M8-09 must export an explicitly selected, ordered sequence of immutable Paengi
capsule revisions as Git commits. ADR-009 keeps Git as interchange only;
ADR-025 keeps capsule revision topology separate from releases; ADR-028 already
defines the immutable `export/commit -> exported-revision` mapping; and ADR-032
defines exact Git-tree construction for one release. The sequence policy must
now define selection identity, ordering, parentage, metadata, target ref,
retry, and partial-publication behaviour without converting workspace state,
conflicts, capsule parent links, or dependency relations into Git topology.

Current milestone: M8 Git Bridge. Vertical slice: one non-empty caller-declared
ordered list of persisted revision links, one existing absolute Git repository,
one exact Git commit per link, one deterministic linear Git ref, and one ADR-028
mapping per commit. It excludes workspace export, conflict conversion, automatic
ordering, merges, tags, signatures, remotes, Gitlinks, and release creation.

## Decision drivers

- Each selected revision must retain its distinct immutable capsule ID, revision
  ID, stored-object ID, declared base, and expected-result snapshot.
- Adjacent selections must prove an exact snapshot chain before any Git ref or
  Paengi mapping is published.
- The Git commit chain must be reproducible from the selected links and Git
  object format, with no ambient identity, clock, filters, hooks, or branch.
- Retry must either verify and complete the same external bridge state or fail
  explicitly; it must not update a capsule, workspace, release, or Paengi ref.
- Existing revision, mapping v1-v3, binding, and golden bytes must remain
  unchanged.

## Considered options

### Export the current revision of each named capsule

- Simple CLI selection.
- Cannot select historical immutable revisions and makes the exported set depend
  on mutable current refs.

### Derive Git parents from capsule parents or dependencies

- Reuses existing Paengi relationships.
- Misrepresents non-linear intent/dependency topology as Git history and cannot
  express a caller-declared composition order faithfully.

### Require ordered immutable revision links and emit a fresh linear chain

- Lets the caller choose exact historical objects and a visible order while
  preserving every other Paengi relation outside the Git parent graph.
- Requires link validation, chain validation, and a deterministic sequence ref.

## Decision outcome

Select the third option.

The export API accepts a non-empty ordered list of
`Capsule_store.revision_link` values. A CLI occurrence carries the exact
`<capsule-id>:<revision-id>:<stored-object-id>` triple, repeatable in declared
order. The implementation loads every object and rejects an object-type error,
any triple that disagrees with its decoded revision, duplicate links, malformed
IDs, or a list over an explicit configured export-commit bound. It validates
each revision and required snapshot object before Git publication.

For adjacent selected revisions `a` then `b`, the exporter requires
`a.expected_result = b.declared_base`. It rejects any mismatch with a structured
chain error. The first revision's declared base is recorded and verified but has
no synthetic Git commit: the first selected revision becomes a root commit whose
tree is its expected-result snapshot. Every later selected revision produces one
commit whose tree is its expected-result snapshot and whose sole Git parent is
the preceding exported commit. A no-op revision still receives its one selected
commit. This Git line is presentation of the declared sequence only; it neither
asserts a capsule-parent relation nor encodes dependencies, provenance,
workspaces, conflicts, resolutions, releases, or source-operation semantics.

Each tree uses ADR-032's exact snapshot exporter: byte-exact regular files,
executable modes, symlink targets, and tree structure; root emptiness is
supported and nested empty directories fail before publication. All commit
metadata is fixed: author and committer are `Paengi Export
<noreply@paengi.local>`; both timestamps are that revision's nonnegative
`created_at`, rendered in UTC; and the exact UTF-8 message is `Paengi capsule
<lowercase-capsule-id-hex> revision <lowercase-revision-id-hex>\n`. This is
interchange metadata, not Paengi authorship or capsule intent text.

The deterministic target ref is
`refs/heads/paengi/capsule-linear-<sequence-sha256-hex>`, where the suffix is
SHA-256 of the domain-separated canonical concatenation of each ordered raw
capsule ID, revision ID, and stored-object ID, including fixed-width lengths.
The sequence digest is external ref naming only; it is not a Paengi object,
identity, ref, schema, or assertion. The ref is create-only unless it already
names the exact computed tip. A different existing tip fails explicitly.

After all commits and the full chain verify, the exporter creates or verifies
the target ref. It then creates or verifies one ADR-028 v1
`Exported_revision` mapping per commit, with the exact capsule ID, revision ID,
revision stored-object ID, expected-result snapshot, Git object format, and
commit ID. The ref and mappings are separate visibility points. An interruption
after ref creation or between mappings leaves an explicit retryable incomplete
bridge state; retry must verify every pre-existing commit/ref/mapping and only
publish missing exact mappings, otherwise fail. Unreferenced Git objects after a
pre-ref failure are external artifacts, never Paengi state.

## Consequences

- One exact selected revision yields one exact Git commit; a selected sequence
  yields a root-plus-linear-parent Git chain.
- A caller must name stored revision objects explicitly; current capsule refs
  are not consulted to choose historical content.
- A destination ref cannot be overwritten by a different sequence tip.
- An exported Git line is inspectable Git interchange, not a replacement for
  capsule/revision history or a source of Paengi truth.
- Nested empty directories remain unrepresentable in this slice.

## Model and invariant impact

The pure export result is:

```ocaml
type revision_export = {
  source : Capsule_store.revision_link;
  snapshot : Snapshot.id;
  tree : git_object_id;
  commit : git_object_id;
  mapping : Git_mapping_id.t;
}

type revision_sequence_export = {
  exports : revision_export list;
  target_ref : string;
}
```

- The selected input is non-empty, ordered, and has no duplicate exact links.
- A link's capsule, revision, and stored-object IDs agree with its decoded
  immutable object; its base and result snapshots are valid.
- Adjacent result/base snapshot IDs are equal before external publication.
- Export `i` has exactly one Git parent when `i > 0`, namely export `i - 1`;
  export zero has none; each commit tree exactly names that export's result.
- A visible mapping validates the exact exported revision object and result
  snapshot it names; no mapping changes a Paengi current ref or release.
- Retry cannot mutate a selected revision, Git mapping, or target ref.

## Persistent-format and migration impact

No new Paengi persistent object, ref, schema, or mapping payload is added.
M8-09 reuses ADR-025 revision objects and ADR-028 v1 `Exported_revision`
subjects. Mapping v1-v3 decoders and all current goldens stay byte-identical.
The selection list, sequence digest, temporary Git index/message files, and Git
objects are invocation or external interchange artifacts, not canonical Paengi
storage.

## Verification

After acceptance, implementation must add focused fixtures for empty/root and
nested trees, regular bytes, executable files, symlinks, no-op revisions,
non-adjacent base/result mismatches, malformed/mismatched links, duplicate
links, chain length bounds, deterministic metadata/ref/retry, ref collision,
partial mapping restart, mapping corruption, and injected pre-ref/between-
mapping interruption. Successful fixtures must run `git fsck --full` and check
out each commit against its revision result snapshot. Bounded generated chains
must prove exactly one commit per selected link, tree equivalence, sole-parent
linearity, and deterministic retry. `make format`, `make check`, and a seeded
property run are required before issue closure. Persistent bytes do not change,
so existing mapping/revision goldens must remain valid.

## CLI and user impact

After acceptance, `paengi git export revisions --repository
<absolute-git-directory> --revision <capsule-id>:<revision-id>:<stored-object-id>
...` reports each immutable source link, result snapshot, Git tree/commit,
target ref, and mapping IDs. It reports the fixed metadata policy and explicit
incomplete/retryable state. It does not infer ordering, export a workspace,
convert a conflict, or claim that the Git line is capsule topology.
