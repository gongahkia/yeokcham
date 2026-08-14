# ADR-076 — Explicit Git archive capsule adoption

- Status: Accepted
- Date: 2026-08-15
- Deciders: maintainer
- Governing issue: [#234](https://github.com/gongahkia/yeokcham/issues/234)
- Supersedes: None
- Superseded by: None

## Context and problem statement

An archive retained by ADR-074 is foreign Git evidence and must remain so until
a user deliberately chooses a native interpretation. A Git commit does not by
itself express a Yeokcham capsule: Git parentage can be a merge, may be chosen
for operational rather than intent reasons, and does not provide a capsule
title, description, dependencies, workspace order, or release policy.

The migration path nevertheless needs a usable, durable way to adopt a chosen
Git change. It must keep the preserved archive and the existing Git-object
mapping connected to the resulting immutable capsule revision without changing
the user’s working tree or silently advancing its scratch head.

## Decision drivers

- Make a Git-to-Yeokcham conversion an explicit, inspectable user action.
- Retain enough provenance to find the selected archive, Git commit, imported
  transition, mapping, and native capsule revision later.
- Keep merge ambiguity visible rather than inferring a dependency or order.
- Reuse the byte-exact snapshot and capsule mechanisms already verified by the
  local core.

## Considered options

### Infer a capsule for every archived commit

- Preserves a familiar commit-by-commit migration surface.
- Incorrectly treats Git graph edges and commit messages as Yeokcham intent,
  especially for merges, and creates unreviewed native history.

### Require an explicit direct parent (or explicit root) and create one capsule

- Makes the source relation and user-authored capsule fields visible.
- Requires repeated user choices for a multi-commit migration and does not
  convert a Git merge into Yeokcham composition.

### Materialise the selected Git snapshot into the current working tree

- Would align the live tree with the adopted target.
- Introduces a destructive filesystem operation into a provenance command and
  makes publication failure harder to recover from.

## Decision outcome

Adopt only one explicitly requested archived Git commit at a time. The command
requires a user-supplied `--parent <git-object-id>` that must be one of the
commit’s recorded direct parents, or `--root` only when the selected commit has
no parents. It also requires a fresh capsule ID, title, and description.

The implementation reconstructs the immutable archive in a private temporary
Git repository, imports the selected commit (and selected parent when present)
through the existing verified bridge, and creates a detached pair of exact
scratch checkpoints. The parent snapshot, or a canonical empty snapshot for a
root commit, is the source; the selected commit snapshot is the target. The
pair is never installed as the repository’s mutable scratch head and does not
materialise to the working tree. It is retained as the resulting capsule’s
boundary evidence.

The direct parent choice is validated against the imported transition’s ordered
Git parent IDs. For a merge, choosing one parent creates only the exact
snapshot delta from that chosen parent; it does not imply a Yeokcham merge,
dependency, conflict resolution, or composition order.

After the immutable capsule revision is published, Yeokcham publishes a
create-only `Git_adoption_v1` receipt that connects archive, commit, optional
chosen parent, imported transition and mapping, capsule revision, and source /
target checkpoints. A retry with exactly the same values resolves the existing
receipt; a different value cannot replace it.

## Consequences

- Users can migrate selected, reviewable Git changes into native capsules while
  retaining an independently exit-able Git archive.
- A Git commit message is retained as foreign opaque metadata by the import
  bridge; it is not substituted for the required capsule title or description.
- Root commits and all merge parents remain available, but each desired source
  relationship must be selected explicitly.
- Adoption does not edit the working tree, create a workspace, release, or
  native peer-exchange record.

## Model and invariant impact

`Git_adoption` is an immutable value containing one archive ID, selected Git
commit, optional selected direct parent, imported-transition ID, Git-mapping
ID, capsule ID/revision ID, and source/target checkpoint IDs.

1. The receipt ID is derived from all of those fields under the
   `yeokcham:git-adoption:v1\000` domain.
2. Its archive, imported transition, and mapping must exist and agree on the
   selected Git commit; the mapping must name that transition.
3. The chosen parent is either absent for a root commit or appears exactly once
   in the transition’s parent list.
4. The source/target checkpoints and capsule revision are exact stored native
   values. Capsule boundaries retain both checkpoints.
5. Neither preservation nor adoption changes the mutable scratch head or the
   user’s filesystem.

## Persistent-format and migration impact

This adds Envelope object type `Git_adoption` and a create-only binding at
`refs/git-adoptions/<lowercase-adoption-id-hex>`. `Git_adoption_v1` is a
canonical versioned record. Existing archives, mappings, imported transitions,
checkpoints, and capsule records are unchanged. Unknown object types and
unknown mandatory features remain rejected. No old record is rewritten.

## Verification

- Unit and golden tests for receipt identity, canonical encode/decode, binding
  corruption, and incompatible field combinations.
- Real Git fixtures for root, ordinary, and merge commits; direct-parent and
  wrong-parent failures; archive-scoped import and `git fsck` reconstruction.
- Capsule replay checks prove that the detached checkpoint delta reaches the
  imported target snapshot and boundary retention is present.
- Generated tests vary supported file bytes and modes through archive exit,
  import, and adoption.

## CLI and user impact

The command is equivalent to:

```text
yeokcham git archive adopt <archive-id> --commit <git-object-id> \
  (--parent <direct-parent-id> | --root) \
  --as-capsule <capsule-id> --title <title> --description <description>
```

It prints the immutable adoption receipt, archive, Git commit, mapping,
capsule revision, and detached checkpoint boundary. It does not use the Git
commit message as native intent or update the user’s working tree.
