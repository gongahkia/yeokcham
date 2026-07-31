# Architecture

## 1. System overview

Paengi consists of a pure model core surrounded by storage, filesystem, parser, and CLI adapters.

```text
CLI / future UI
      |
      v
Application Service
      |
      +------------------------+
      |                        |
      v                        v
Pure Repository Model      Materialiser
      |                        |
      v                        v
Object Store              Working Directory Adapter
      |
      +--> Scratch Journal
      +--> Capsule Store
      +--> Conflict Store
      +--> Release Store
      +--> Indexes
      |
      v
Filesystem / future remote backend
```

Semantic analysis is an optional sidecar:

```text
Changed bytes
   |
   +--> exact byte operation
   |
   +--> language parser
          |
          +--> semantic anchors
          +--> structured operation proposal
          +--> confidence and fallback
```

## 2. Proposed OCaml workspace

```text
paengi/
  dune-project
  bin/
    paengi.ml
  lib/
    paengi_id/
    paengi_model/
    paengi_transition/
    paengi_store/
    paengi_snapshot/
    paengi_scratch/
    paengi_compaction/
    paengi_capsule/
    paengi_workspace/
    paengi_conflict/
    paengi_release/
    paengi_semantic/
    paengi_git/
    paengi_cli/
    paengi_testkit/
  test/
  bench/
  fixtures/
  docs/
  scripts/
```

Do not split every type into a library at the beginning. The logical boundaries above are a target, not a requirement for the first commit.

## 3. Architectural rule: functional core, imperative shell

### Functional core

Pure functions should cover:

- Applying scratch operations.
- Building snapshots.
- Planning compaction.
- Applying capsule operations.
- Ordering capsule dependencies.
- Producing conflict values.
- Retargeting.
- Constructing release records.
- Verifying invariants.

### Imperative shell

Side effects should be isolated to:

- Filesystem scanning and watching.
- Object persistence.
- Working-directory writes.
- Process execution for validation.
- Git import/export.
- Network synchronisation.
- Clock and random identifiers.

This boundary is central to property testing.

## 4. Persistent storage

### 4.1 Object model

Use immutable content-addressed objects for:

- File chunks.
- File manifests.
- Trees.
- Snapshots.
- Scratch events.
- Checkpoints.
- Capsule revisions.
- Conflicts.
- Releases.
- Validation output digests.

Use small named refs or indexes for:

- Current workspace specification.
- Current capsule revision.
- Scratch head.
- Release names.
- Repository configuration.

### 4.2 Encoding

Persistent encodings must be:

- Versioned.
- Canonical.
- Portable outside OCaml.
- Length-delimited.
- Integrity-checked.
- Able to reject unknown mandatory features.

Recommended prototype approach:

- Paengi CBOR Profile 1: restricted deterministic CBOR for records, defined by [ADR-017](docs/adr/017-restricted-deterministic-cbor.md).
- Fixed Object Envelope 1 with object type, format version, payload length, and checksum, defined by [ADR-018](docs/adr/018-fixed-object-envelope.md); its object-format version and mandatory-feature rules are defined by [ADR-019](docs/adr/019-object-format-versions-and-mandatory-features.md).
- No `Marshal` for persistent repository data.

Object-store identity and storage-publication rules remain separate decisions.

ADR-020 resolves the initial store rule: a `Stored_object_id` is SHA-256 of the `paengi:object:v1\000` domain prefix followed by the exact Envelope-1 bytes. It is rendered as 64 lowercase hexadecimal characters at `.paengi/objects/<hex[0:2]>/<hex[2:4]>/<hex[4:64]>`. Writers use same-shard temporary files, file fsync, hard-link no-replace publication, and directory fsync; an existing final path is verified byte-identically or reported as collision/corruption. No overwriting rename fallback is permitted. Directory fsync unsupported by a filesystem weakens crash-durability guarantees and is documented rather than hidden.

### 4.3 Content IDs

Use a hash abstraction.

Initial implementation may use SHA-256 for portability. Benchmark BLAKE3 later if a maintained binding and distribution story are acceptable.

The model must not expose hash-algorithm assumptions everywhere.

### 4.4 Object database layout

Conceptual local layout:

```text
.paengi/
  format
  config
  objects/
    aa/bb/<object-id>
  refs/
    scratch-head
    scratch-generation
    workspaces/
      <workspace-id>/current
    capsules/
    releases/
  indexes/
    paths.sqlite
    scratch.sqlite
  journal/
  locks/
  trash/
  tmp/
```

Milestone 2 uses immutable Envelope-1 objects for scratch events, checkpoints,
and retention changes. `refs/scratch-head`, `refs/retention-head`, and the
additive `refs/scratch-generation` use canonical, checksummed ref bytes and
same-directory temporary-write, lock, compare-and-swap, rename-over, and
directory-fsync publication from ADR-023.  Timeline and path indexes remain
rebuildable cache data and cannot be required to recover history.

SQLite may be used for rebuildable indexes and queries. Canonical objects must remain independently readable.

## 5. Snapshot engine

The snapshot engine:

- Scans the working directory.
- Excludes `.paengi`.
- Applies ignore rules.
- Identifies changed paths.
- Hashes content.
- Chunks large files according to policy.
- Stores file manifests and trees.
- Produces a snapshot ID.
- Reuses unchanged object identities.

The initial scanner implements exact-path `.paengiignore` entries, excludes the root `.paengi`, stores Content/Tree/Snapshot schemas from ADR-021, and stores Chunk/File_manifest schemas from ADR-022. It keeps files at or below 64 KiB as Content v1 and streams larger files through deterministic Buzhash-64-v1 chunks (64-byte window; 16/64/128 KiB min/average/max). It supports regular files, executable mode, and symlinks without following them. Sockets, FIFOs, character devices, block devices, and other unsupported kinds return structured path/category errors before a snapshot is published.

Initial implementation should use full or metadata-assisted scans. Filesystem watching is a later optimisation.

## 6. Scratch journal

The scratch service records:

- Parent checkpoint.
- Observed file operations.
- Resulting snapshot.
- Timestamp.
- Tags and validation state.
- Retention reasons.

A checkpoint may be created by:

- Explicit command.
- Debounced scan.
- Before restore.
- Before capsule operation.
- Before workspace rematerialisation.
- After configured validation passes.
- Periodic safety policy.

An event/checkpoint pair is persisted before scratch-head publication.  The
timeline walks checkpoint parents from that head in ancestry order and verifies
event/base/result/replay agreement.  User pinning appends a Retention_change
object and moves retention-head; it never rewrites a checkpoint.

## 7. Compaction engine

Compaction is a plan-then-commit operation.

```text
analyse scratch graph
  -> determine retained boundaries
  -> calculate reachable objects
  -> propose event/snapshot replacements
  -> estimate storage
  -> verify retained states in temporary generation
  -> atomically publish new generation
  -> retain old generation during grace period
```

Strategies should be pluggable and independently benchmarked.

Milestone 3 provides a deterministic planner over the verified ancestry. It
applies explicit recent-window/periodic/storage-budget policy and reports
reachable-object accounting before generation construction. Immutable
Checkpoint v1 parent/event links still require a generation layer rather than
record rewriting.

ADR-024 implements that additive generation layer. `refs/scratch-generation`
is an ADR-023 mutable CAS ref to a bounded-segment immutable generation root.
The scratch resolver returns logical and physical checkpoint identities, with
active aliases preceding direct lookup. Generation construction creates direct
retained-snapshot deltas, verifies replay, then publishes the ref under a
repository compaction lock. Cleanup begins only after publication and moves
manifest-listed obsolete scratch records to same-filesystem quarantine. Content,
trees, snapshots, chunks, and manifests are outside cleanup until canonical
cross-domain reachability exists.

The dry-run planner simulates the compacted physical chain without writing it,
then emits the exact canonical cleanup candidate IDs, expected types, counts,
and stored object-file lengths. Activation rederives that set before manifest
storage and rejects any mismatch. Cleanup supports deterministic test-only
fault boundaries immediately before and after every candidate operation; the
imperative shell reopens and revalidates the active generation and manifest on
resume. This mechanism does not add rollback or persistent cleanup state.

Initial strategies:

1. Delete expired unpinned checkpoint records while preserving referenced snapshots.
2. Content garbage collection.
3. Collapse event chains between retained snapshots.
4. Remove exact inverse edit pairs when proof is straightforward.
5. Keep periodic full snapshots to bound replay depth.

Never make semantic guesses during scratch compaction.

## 8. Capsule engine

A capsule service supports:

- Creation from two snapshots.
- Creation from selected scratch checkpoints.
- Revision.
- Split.
- Combine.
- Dependency declaration.
- Application.
- Retargeting.
- Inspection.

The first capsule representation should use exact file transitions and textual edits. Semantic operations come later.

The Milestone 4 capsule service combines the pure `paengi_capsule` transition
core with `paengi_capsule_store`. ADR-025 adds immutable `Capsule_v1` and
complete `Capsule_revision_v1` Envelope-1 objects, and a checksummed
generation-CAS current ref at `refs/capsules/<capsule-id>/current`. Durable
creation/folding holds the repository writer lock, publishes immutable objects
and idempotent boundary pins before the current ref visibility point, and
revalidates exact replay on every resolution. History derives solely from
physical parent links; ref-directory enumeration is the rebuildable listing
mechanism. Split produces a validated base-to-intermediate then
intermediate-to-result chain; combine accepts only an explicit replay-valid
base/result source chain. No mutable capsule catalog is canonical.

`capsule create --current` uses no separate working-diff format. Under the same
writer lock it verifies a scratch head, double-scans the working directory, and
uses the ordinary scratch checkpoint writer for a verified difference. The
existing durable checkpoint-range creator then performs capsule publication.
An equal verified scan returns a structured no-change result. Immutable scan
objects left by a failed scan are unreachable; no scratch-head or capsule-ref
publication occurs before the checkpoint/current-ref visibility points.

Single-capsule editing reuses the guarded restore shell rather than creating a
workspace or edit-session schema. It verifies the current immutable revision,
safety-checkpoints divergent bytes, stages a normal Scratch_event/Checkpoint
for the exact revision result, and applies the guarded plan. The staged target
becomes `scratch-head` only after rescan verification; a failed apply leaves the
capsule/ref unchanged and never selects that target. The returned checkpoint is
the explicit input to normal range-based folding.

Split/combine planning is pure with respect to repository publication. The
planner derives deterministic snapshot identities from canonical tree/snapshot
bytes without writing objects, then exposes output revisions, bases/results,
provenance, ordering, and required pins to the CLI. The publisher requires an
explicit confirmation, obtains the writer lock, and rebuilds the plan from the
current verified immutable inputs immediately before publication. A narrow
`paengi_capsule.Parent_resolver` accepts synthetic logical parent graphs for
cycle tests; it supplements rather than bypasses the production durable
resolver's type/ID/parent checks.

## 9. Workspace materialiser

Inputs:

- Base snapshot or release.
- Enabled capsule revisions.
- Dependency graph.
- Explicit precedence where needed.
- Resolution records.
- Policy.

`paengi_workspace` remains the pure resolver/application core. ADR-026 adds
`paengi_workspace_store` as the persistence and guarded-materialisation shell:
immutable Workspace/Workspace_revision/Workspace_attempt/Conflict/Resolution
objects, checksummed CAS current refs at `refs/workspaces/<workspace-id>/current`,
and validated ref-directory listing. Its selected links bind logical capsule
revisions to exact physical objects; a stored resolved order must recompute.
Indexes remain rebuildable.

Outputs:

- Materialised snapshot.
- Per-operation outcome.
- Conflict objects.
- Working-directory update plan.

Working-directory update follows guarded scratch materialisation:

1. Lock, read the workspace ref, scan, and preserve divergent work in a safety checkpoint.
2. Re-resolve immutable workspace inputs and compute/store the attempt and conflicts.
3. Produce a guarded write plan and revalidate the working snapshot before writes.
4. Validate paths/symlinks, write temporary files, and atomically replace where supported.
5. Rescan the exact result and CAS-advance scratch head.
6. Re-read and CAS-update the workspace ref with the immutable attempt.

The final two ref publications are not cross-ref atomic. Recovery re-resolves
immutable workspace inputs and allows an exact retry when scratch-head
publication succeeded before workspace-attempt publication.

## 9.1 Release service

`paengi_release` is a read-mostly durable adapter over verified immutable
workspace revisions and attempts. Release creation holds the existing
repository writer lock, rejects unresolved attempts, replays the exact attempt,
runs required validation through `paengi_validation`, writes immutable evidence
and a `Release_v1`, verifies reproduction, then creates the release binding.
The binding at `refs/releases/<release-id>` is expected-absent and is the only
visibility point. A crash before it leaves unreachable immutable objects only.

Release verification never trusts workspace-current or a rebuildable index: it
loads the release's physical workspace revision/attempt links and replays them.
Parent traversal is isolated behind a pure resolver seam for cycle tests.

Milestone 1 materialisation is intentionally narrower: it emits an inspectable dry-run plan and writes only to an existing empty destination with exclusive file creation. It preserves regular bytes, executable mode, directories, and symlink target bytes; unsafe decoded names and nonempty destinations reject. Workspace transactional replacement and safety checkpoints remain scratch/workspace work.

Milestone 2 restore is a guarded, but not crash-atomic, populated-directory
operation.  It scans and durably checkpoints differing current work, binds a
dry-run plan to that scan, rescans before applying, validates each safe path,
then rescans the result before target-head publication.  On an I/O failure the
safety checkpoint provides recovery; Paengi reports rather than conceals any
possible partial filesystem application.

## 10. Semantic sidecar architecture

### Phase 1: parser-assisted anchors

For TypeScript:

- Parse source.
- Identify declarations and structural paths.
- Attach textual fallback context.
- Detect simple declaration moves and renames.
- Avoid pretending to know semantics across dynamic behaviour.

For Rust later:

- Parse items and modules.
- Identify item paths.
- Record moves and renames.
- Preserve macro-heavy or invalid files through textual fallback.

### Semantic application order

1. Exact object precondition.
2. Stable semantic identity if present.
3. Structural path.
4. Token or syntax similarity.
5. Textual context.
6. Conflict.

Every step emits confidence and evidence.

### Parser boundary

Language adapters should implement an interface such as:

```ocaml
module type LANGUAGE_ADAPTER = sig
  type parsed
  val parse : bytes -> (parsed, parse_error) result
  val infer_operations :
    before:bytes -> after:bytes -> semantic_proposal list
  val locate_anchor :
    parsed -> semantic_anchor -> anchor_match list
  val apply :
    parsed -> semantic_operation -> semantic_apply_result
end
```

## 11. Conflict storage

Conflicts should contain enough data to:

- Explain what failed.
- Show base and candidates.
- Reattempt after related changes.
- Record resolution.
- Preserve history.
- Export a textual conflict representation if required.

A workspace may have conflicts and still permit:

- Timeline inspection.
- Capsule inspection.
- Changes to unrelated paths.
- New scratch checkpoints.
- Resolution of one conflict at a time.

## 12. Validation runner

Validation commands are user-configured.

The runner should:

- Resolve a specific immutable snapshot and materialise it into a fresh temporary directory.
- Directly execute the configured executable and argument vector without an implicit shell.
- Capture exit status, signal, timeout, duration, full-stream hashes, and bounded prefixes.
- Optionally persist only bounded output prefixes as Content objects.
- Record an environment fingerprint optionally.
- Enforce time and output limits through a Paengi-owned runner interface.
- Clean temporary materialisation where possible; process-group termination is best effort by host.
- Never equate success with proof of correctness.

Milestone 6 adds immutable `Validation_evidence_v1`; it is not a mutable
workspace/scratch annotation and cannot advance canonical refs. Release creation
uses only evidence bound to the exact final snapshot.

## 13. Git bridge

### Import architecture

Use a mature Git library or invoke Git plumbing through a controlled adapter.

Import:

- Commit graph.
- Trees and blobs.
- Author and timestamp metadata.
- Parent relationships.
- Tags.
- Mapping records.

Imported commits initially become opaque transitions. Semantic inference is optional post-processing.

### Export architecture

Materialise snapshots and write:

- Git blobs.
- Trees.
- Commits.
- Refs.
- Mapping metadata.

First export mode:

- Linear sequence.
- One Git commit per selected capsule revision.
- Release as branch head.
- Explicit author/message configuration.

Merge topology support is later.

## 14. Future synchronisation

Do not implement before the local model is stable.

Possible model:

- Immutable object exchange by content ID.
- Signed ref or operation events.
- Explicit device identities.
- Conflict-preserving ref reconciliation.
- Encrypted bundles for dumb storage.
- Local HTTP peer transfer.

Paengi does not require consensus for single-user multi-device use. It requires preserving divergent heads and letting the user reconcile them.

## 15. Observability

CLI inspection should make the model understandable:

```text
paengi timeline --graph
paengi capsule show --operations
paengi work explain-order
paengi conflict show
paengi compact --dry-run --explain
paengi release verify --explain
paengi storage stats --by-history
```

Machine-readable JSON output should exist for experiments and future UI work.

## 16. Upgrade strategy

Persistent objects are immutable. Format upgrades should:

- Add new object versions.
- Create new refs or generations.
- Preserve old objects during migration.
- Include migration verification.
- Keep old-format fixtures.
- Never mutate the only readable copy in place.
