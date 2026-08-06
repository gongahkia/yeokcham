# Comparative workflow analysis

## M11-11 scope and method

This is a qualitative workflow comparison, not a benchmark or compatibility
claim. It compares the checked Yeokcham demonstrations with the named tools'
official documentation. It does not execute a task in Git, Jujutsu, Pijul, or
GitButler, measure runtime/storage, assess usability, or establish feature
parity.

### Evidence and labels

- **[Implemented Yeokcham fact]** is covered by the linked local fixture and its
  focused test.
- **[Documented tool fact]** is a bounded statement from the linked official
  documentation, retrieved on 2026-08-06.
- **[Inference]** is an interpretation of those facts, not a tested result.
- **[Unverified]** marks a comparison that this repository has not executed.

Host discovery, before verification: macOS 26.5.2 arm64; `git version 2.55.0`
and `jj 0.43.0` were available. `pijul` and `but` were not installed. Their
absence is not an assessment of either tool.

## What the checked Yeokcham slice establishes

- **[Implemented Yeokcham fact]** Scratch checkpoints are exact retained
  snapshots; the fixture demonstrates restore and byte/mode/symlink fidelity.
  [M11-01 fixture](DEMO_REPOSITORY.md) and
  [M11-02 recovery fixture](DEMO_RECOVERY.md) are the evidence.
- **[Implemented Yeokcham fact]** A workspace selects immutable capsule
  revisions in explicit order without creating a Git branch.
  [M11-05 fixture](DEMO_WORKSPACE.md) is the evidence.
- **[Implemented Yeokcham fact]** A failed capsule operation becomes an
  inspectable persistent conflict while independent work continues. The only
  demonstrated resolution is explicit `skip`; unsupported replacement rejects
  without changing workspace state. [M11-06 fixture](DEMO_CONFLICT.md) is the
  evidence.
- **[Implemented Yeokcham fact]** An immutable release binds one final snapshot
  to its recorded validation evidence. The fixture's `/usr/bin/true` is only
  successful bounded-command evidence, not a quality, signature, or
  reproducible-build claim. [M11-08 fixture](DEMO_RELEASE.md) is the evidence.
- **[Implemented Yeokcham fact]** The Git bridge exports a verified release to a
  fresh local Git repository, checks `git fsck --full`, and never configures a
  remote or invokes `git push`. [M11-09 fixture](DEMO_GIT_EXPORT.md) is the
  evidence.

## Workflow comparison

| Workflow concern | Yeokcham evidence | Existing-tool credit | Limit and trade-off |
| --- | --- | --- | --- |
| Recover local states separately from curated work | **[Implemented Yeokcham fact]** Checkpoints are scratch history; capsules and releases remain distinct types. | **[Documented tool fact]** Jujutsu has an operation log whose view records repository state and can be selected with `--at-operation`. [Jujutsu concurrency design](https://jj-vcs.github.io/jj/latest/technical/concurrency/) | **[Inference]** Yeokcham's explicit three-layer vocabulary can make the durability decision visible. It does not establish easier recovery than Jujutsu. |
| Curate several changes in one directory | **[Implemented Yeokcham fact]** A workspace records selected revisions and explicit order. | **[Documented tool fact]** Git recommends topic branches; merging acts at branch level and cherry-picking at commit level. [Git workflows](https://git-scm.com/docs/gitworkflows) GitButler documents independently applied virtual and stacked branches in one working directory. [GitButler overview](https://docs.gitbutler.com/overview) | **[Inference]** GitButler is closer to Yeokcham's simultaneously composed local-work goal than ordinary one-branch checkout workflows. Yeokcham does not claim GitButler's branch UI, review flow, or upstream integration. |
| Keep conflict state inspectable while continuing unrelated work | **[Implemented Yeokcham fact]** The M11 fixture retains a typed `competing-edits` conflict and permits an explicit skip binding in a later workspace revision. | **[Documented tool fact]** Pijul models conflicts between changes; a resolution is itself a change and further patches can be applied while a conflict remains. [Pijul conflicts](https://pijul.org/manual/conflicts.html) Jujutsu documents conflicted bookmarks as usable repository state, though some commands reject them. [Jujutsu concurrency design](https://jj-vcs.github.io/jj/latest/technical/concurrency/) GitButler documents rebasing conflicted commits and resolving them later. [GitButler overview](https://docs.gitbutler.com/overview) | **[Inference]** Persistent conflicts are not unique to Yeokcham. Yeokcham's demonstrated distinction is the typed workspace-conflict/resolution object, not a claim of novel conflict theory or superior resolution UX. |
| Publish or collaborate through Git | **[Implemented Yeokcham fact]** Export creates a local Git commit/tree and typed mapping after preflight and `fsck`; no remote or push is part of the fixture. | **[Documented tool fact]** Git's documented distributed merge workflow copies branches to a remote with `git push`. [Git workflows](https://git-scm.com/docs/gitworkflows) GitButler documents virtual branches as Git-aware and its own integration constraints. [GitButler overview](https://docs.gitbutler.com/overview) | **[Inference]** Git remains the appropriate native choice when the needed workflow is Git refs/remotes and established Git-hosting interoperability. Yeokcham's verified export is deliberately narrower. |

## Interoperability boundary

**[Implemented Yeokcham fact]** Yeokcham's M8 bridge preserves supported checkout
bytes, executable modes, symlink-target bytes, selected export order, and an
object mapping. It intentionally does not reconstruct scratch checkpoints,
pins/compaction, capsule intent, workspace/conflict/resolution state, release
evidence, Git remotes, Git merge topology, tags, or signatures from an export.
The complete contract is [Git interchange](GIT_INTERCHANGE.md).

**[Inference]** A Yeokcham user who requires ordinary Git collaboration retains
the original Yeokcham repository as the source of Yeokcham semantics and treats
the exported Git repository as an interchange artifact. This is a real
operational cost compared with using Git directly; it avoids claiming that a
Git ref is an equivalent Yeokcham history.

## Unsupported cases and errors

**[Implemented Yeokcham fact]** The demonstrated Yeokcham boundary rejects invalid
fixture roots, malformed IDs, failed transitions, invalid Git destinations,
failed validation, and unsupported conflict replacement through structured
errors; tests assert non-publication or unchanged state where applicable.

**[Unverified]** This report did not run error paths in Git, Jujutsu, Pijul, or
GitButler. It makes no claim about their error structure, persistence safety,
performance, UX, or behaviour at a particular repository scale.

Yeokcham limitations relevant to this comparison:

- **[Implemented Yeokcham fact]** The release demonstration uses only
  `/usr/bin/true`; it provides no meaningful test-quality evidence.
- **[Implemented Yeokcham fact]** Git export is local-only in the fixture and is
  not full Git compatibility. The bridge explicitly rejects or omits several
  Git representations and policies.
- **[Implemented Yeokcham fact]** The optional semantic sidecars do not authorise
  automatic ambiguous source rewrites or become canonical storage.
- **[Unverified]** No comparative performance, storage, network reliability,
  multi-user collaboration, or production-readiness conclusion follows from
  this report.

## Reproducibility and verification

Run from the repository root:

```text
opam exec -- dune runtest test/test_demo_git_export.exe
opam exec -- dune runtest test/test_comparative_workflow_analysis.exe
make check
```

`test_demo_git_export` reruns the referenced final release/export fixture.
`test_comparative_workflow_analysis` asserts that this report retains the
evidence labels, source links, interoperability boundary, and unsupported-case
statement. Neither test executes the compared tools' workflows; the external
claims remain documentation citations.
