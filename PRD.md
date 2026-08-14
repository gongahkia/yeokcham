# Product Requirements Document

## 1. Product summary

Yeokcham is a local-first version-control system that separates scratch, intent, and release history.

It automatically records working-directory states, lets users curate those
states into logical change capsules, composes capsules into workspaces, emits
immutable releases, supports explicit Git migration, and will exchange selected
native history directly between peers.

## 2. Product objectives

### O1 — Remove safety-commit pressure

Users should receive automatic recovery without manually creating permanent commits.

### O2 — Make intent first-class

A logical feature or fix should have stable identity independent of its current implementation revision.

### O3 — Support composable work

Users should be able to enable and disable several capsules in one workspace.

### O4 — Make history retention purposeful

Scratch history should compact according to explicit retention rules while preserving pinned or important states.

### O5 — Make conflicts persistent and local

Unresolved application conflicts should not make the entire repository unusable.

### O6 — Preserve exact source bytes

Semantic features must be sidecars over a byte-accurate canonical store.

### O7 — Make Git adoption reversible

Yeokcham should preserve selected Git history, let users explicitly adopt it,
and export selected Yeokcham history to Git without claiming semantic
equivalence.

### O8 — Become a native peer VCS

Yeokcham should exchange explicitly published capsule revisions and releases
between peers without requiring a hosted service.

## 3. Core user journeys

### J1 — Automatic checkpointing

1. User runs `yeokcham init`.
2. Yeokcham records a base snapshot.
3. Filesystem changes are observed or scanned.
4. Yeokcham records scratch events and checkpoints.
5. User can inspect a timeline.
6. User restores a selected checkpoint.

Acceptance condition: restored bytes, modes, symlinks, and supported metadata match the recorded state exactly.

### J2 — Curate a change capsule

1. User performs several messy edits.
2. User selects a checkpoint range or current diff.
3. User runs `yeokcham capsule create`.
4. Yeokcham proposes file operations and optional semantic operations.
5. User supplies a name and description.
6. Yeokcham records a stable capsule ID and immutable first revision.
7. Scratch checkpoints included in the capsule become pinned according to policy.

Acceptance condition: applying the capsule revision to its declared base recreates the intended snapshot or yields explicit conflict values.

### J3 — Revise a capsule

1. User enables a capsule.
2. User edits the workspace.
3. Yeokcham records scratch checkpoints.
4. User folds selected work into the capsule.
5. Yeokcham creates a new capsule revision.
6. Stable capsule ID remains unchanged.
7. Old revisions remain addressable according to retention policy.

Acceptance condition: revision identity changes, logical capsule identity does not.

### J4 — Compose a workspace

1. User selects a base release.
2. User enables capsules A, B, and C.
3. Yeokcham orders them using dependencies and explicit precedence.
4. Yeokcham materialises the workspace.
5. Conflicts are recorded as values.
6. Unrelated files remain usable.

Acceptance condition: composition is deterministic for the same base, revisions, order, and policies.

### J5 — Retarget a capsule

1. Base release changes.
2. User asks Yeokcham to retarget a capsule.
3. Yeokcham attempts semantic-anchor replay.
4. Yeokcham falls back to token or textual context.
5. Yeokcham records successful operations, uncertain operations, and conflicts.
6. User resolves or accepts the result.
7. Yeokcham creates a new capsule revision.

Acceptance condition: no ambiguous transformation is silently treated as certain.

### J6 — Create a release

1. User selects base and capsule revisions.
2. Yeokcham verifies dependency closure.
3. Yeokcham materialises the exact snapshot.
4. Configured validation commands run.
5. Yeokcham records test evidence.
6. Yeokcham creates an immutable reproducible release. Production release
   signing remains a later FR-021 capability; the current deterministic
   test-only attestation does not sign a release.

Acceptance condition: release snapshot is reproducible from stored objects and declared composition.

### J7 — Migrate from and exit to Git

1. User selects Git refs to preserve.
2. Yeokcham inventories and archives their reachable Git provenance.
3. The user explicitly adopts selected imported work into Yeokcham capsules,
   workspaces, or releases.
4. The user selects releases or ordered capsule revisions for Git export.
5. Yeokcham creates a valid Git repository and records mapping receipts.

Acceptance condition: supported imported Git checkout bytes and selected
reachable provenance survive preservation/exit, and every Yeokcham export
passes `git fsck` and matches its selected snapshot bytes.

### J8 — Exchange a publication with a peer

1. User explicitly publishes a capsule revision or release.
2. User fetches from a local-path or SSH peer.
3. Yeokcham exchanges only missing verified immutable objects.
4. Yeokcham shows an integration proposal or a divergence value.
5. User explicitly integrates the publication into local work.

Acceptance condition: peer exchange neither shares scratch checkpoints by
default nor mutates a workspace, ref selection, or working tree without an
explicit user operation.

## 4. Functional requirements

### FR-001 Repository initialisation

Yeokcham shall initialise a repository without requiring Git.

### FR-002 Canonical snapshot store

Yeokcham shall store exact file bytes, directory structure, executable mode, and supported symlink information.

### FR-003 Automatic scratch history

Yeokcham shall create scratch checkpoints automatically through scanning first and filesystem events later.

### FR-004 Restore

Yeokcham shall restore any retained scratch checkpoint.

### FR-005 Scratch timeline

Yeokcham shall display checkpoint time, changed paths, size, tags, validation state, and retention status.

### FR-006 Pinning

Users and system policies shall be able to pin checkpoints against compaction.

### FR-007 Compaction

Yeokcham shall compact unpinned scratch history while preserving all retained checkpoint states.

### FR-008 Capsule creation

Yeokcham shall create a change capsule from selected scratch history or snapshot differences.

### FR-009 Stable capsule identity

A capsule shall keep a stable logical ID across immutable revisions.

### FR-010 Capsule revision

Each capsule revision shall be immutable and content-addressed or cryptographically identified.

### FR-011 Dependencies

A capsule may declare dependencies on other capsules or releases.

### FR-012 Capsule composition

Yeokcham shall deterministically compose selected capsule revisions into a workspace.

### FR-013 Enable and disable

Users shall enable and disable capsules without treating each as an alternative branch checkout.

### FR-014 Conflict values

Yeokcham shall represent conflicts as persistent repository objects.

### FR-015 Continued operation

Unrelated operations shall remain available while conflicts exist.

### FR-016 Retargeting

Yeokcham shall attempt to apply a capsule revision to a changed base and create a new revision or conflict set.

### FR-017 Raw fallback

Every semantic operation shall have an exact-byte or textual fallback sufficient for safe failure.

### FR-018 Semantic sidecars

Yeokcham shall support structured operations for at least one language after the byte model is stable.

### FR-019 Validation evidence

Yeokcham shall record configured build, test, type-check, or lint results against capsule revisions and releases.

### FR-020 Release creation

Yeokcham shall create immutable reproducible release snapshots.

### FR-021 Release signatures

Yeokcham shall support signing releases after the local model is stable.

### FR-022 Git preservation and adoption

Yeokcham shall preserve selected reachable Git objects, refs, topology, and
metadata as opaque foreign provenance, then require an explicit adoption action
before creating Yeokcham concepts.

### FR-023 Git export

Yeokcham shall export selected yeokcham history to a valid Git repository.

### FR-024 Storage statistics

Yeokcham shall report scratch, capsule, release, chunk, and retained-history storage separately.

### FR-025 Integrity verification

Yeokcham shall verify object hashes, snapshot reachability, capsule dependencies, and release reproducibility.

### FR-026 Peer publication

Yeokcham shall let users explicitly publish capsule revisions and releases.
Scratch checkpoints shall remain local by default.

### FR-027 Direct peer exchange

Yeokcham shall fetch, verify, and propose integration of selected peer
publications over a local path and SSH without requiring a hosted service.

## 5. Non-functional requirements

### NFR-001 Deterministic transitions

Core repository state transitions shall be expressible as pure or isolated deterministic functions.

### NFR-002 Property-testability

Compaction, composition, restoration, and retargeting shall expose testable invariants.

### NFR-003 Byte correctness

Unknown or unsupported file types shall remain exactly reproducible.

### NFR-004 Visible uncertainty

Semantic operations shall carry confidence or outcome states rather than collapsing ambiguity into success.

### NFR-005 Local-first operation

The initial usable prototype shall require no server.

### NFR-006 Portable formats

Persistent formats shall not depend on OCaml runtime serialisation.

### NFR-007 Inspectability

Users shall be able to inspect capsules, revisions, conflicts, checkpoints, and release composition through the CLI.

### NFR-008 Performance measurement

Compression, chunking, semantic replay, and compaction claims shall be benchmarked.

## 6. CLI concept

Names may change, but the product model should remain visible.

```bash
yeokcham init
yeokcham status
yeokcham timeline
yeokcham restore <checkpoint>
yeokcham pin <checkpoint>
yeokcham compact --dry-run

yeokcham capsule create --from <checkpoint-a>..<checkpoint-b>
yeokcham capsule list
yeokcham capsule show <capsule>
yeokcham capsule revise <capsule>
yeokcham capsule split <capsule>
yeokcham capsule combine <capsule-a> <capsule-b>
yeokcham capsule retarget <capsule> --onto <release>

yeokcham work base <release>
yeokcham work enable <capsule>
yeokcham work disable <capsule>
yeokcham work list
yeokcham work materialise

yeokcham conflict list
yeokcham conflict show <conflict>
yeokcham conflict resolve <conflict>

yeokcham release create
yeokcham release verify <release>

yeokcham import git <path>
yeokcham export git <destination>
yeokcham peer publish <capsule-revision-or-release>
yeokcham peer fetch <path-or-ssh-peer>
yeokcham peer integrate <publication>
yeokcham verify
yeokcham storage stats
```

## 7. Release scope

### Model prototype

- Exact snapshot storage.
- Automatic polling-based checkpoints.
- Restore.
- Pinning.
- Scratch compaction.
- Property tests.

### Usable local alpha

- Capsule creation and revisions.
- Workspace composition.
- Persistent conflicts.
- Release snapshots.
- CLI inspection.

### Git migration

- Git source capability report and preservation archive.
- Explicit Git adoption and valid Git exit/export.
- Mapping receipts and preservation/exit verification.

### Native peer exchange

- Explicit publication selection.
- Local-path transfer, then SSH transfer.
- Missing-object transfer, divergence, and explicit integration.

## 8. Explicit non-goals

- Perfectly inferring human intent from arbitrary edits.
- Automatically proving semantic equivalence.
- Eliminating every merge conflict.
- Permanent retention of every automatic checkpoint.
- Reproducing every Git topology exactly as native Yeokcham concepts.
- Supporting every programming language.
- Production multi-user hosting.
- Peer discovery, relays, NAT traversal, background synchronisation, web
  review, or IDE integration in the first native peer workflow.
- Concealing experimental limitations.

## 9. Success metrics

### Usability

- A developer can recover recent work without having made a manual checkpoint.
- A developer can turn messy scratch history into one coherent capsule.
- A developer can enable multiple capsules in one workspace.
- A developer can preserve Git history before adoption and exit to a valid Git
  repository later.
- A developer can exchange a selected release or capsule revision directly with
  a peer without sharing scratch history by default.

### Model correctness

- Restore reproduces retained snapshots exactly.
- Compaction never changes retained snapshots.
- Composition is deterministic.
- Capsule IDs remain stable across revisions.
- Release reproduction yields the same snapshot ID.
- Conflicts are preserved until explicitly resolved.

### Research value

- At least one compaction strategy has measured storage and recovery trade-offs.
- At least one semantic replay strategy is compared with textual replay.
- Results include false-confidence cases, not only successful demonstrations.
- The design clearly distinguishes itself from Jujutsu, Pijul, GitButler, and Git.

## 10. Major risks

### R1 — Model complexity without user value

Mitigation: ship a timeline, restore, capsule, and workspace demo before semantic research.

### R2 — Semantic replay appears safer than it is

Mitigation: explicit uncertainty states and validation evidence.

### R3 — Scratch history grows without bound

Mitigation: retention budgets, compaction, and storage statistics from the first prototype.

### R4 — Capsule composition becomes order-dependent and confusing

Mitigation: explicit dependency graph, deterministic order, and visible precedence.

### R5 — Git bridge distorts Yeokcham

Mitigation: make Git an import/export layer, not the canonical internal model.

### R7 — Peer exchange recreates hosted-system complexity

Mitigation: begin only with explicit local-path and SSH peers, immutable object
transfer, and user-confirmed integration.

### R6 — OCaml ecosystem friction

Mitigation: keep system boundaries simple, use portable external formats, and isolate platform-specific filesystem watching.

## 11. Open product questions

- What default scratch retention policy feels safe?
- Which checkpoints should be pinned automatically?
- Should a test-passing checkpoint always be retained?
- How should capsule dependencies be inferred versus declared?
- How should users understand composition order?
- When should formatting-only changes be automatically separated?
- What confidence scale should semantic replay expose?
- How much original scratch history should remain after capsule publication?
