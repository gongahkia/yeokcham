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
    workspace
    capsules/
    releases/
  indexes/
    paths.sqlite
    scratch.sqlite
  journal/
  locks/
  tmp/
```

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

## 9. Workspace materialiser

Inputs:

- Base snapshot or release.
- Enabled capsule revisions.
- Dependency graph.
- Explicit precedence where needed.
- Resolution records.
- Policy.

Outputs:

- Materialised snapshot.
- Per-operation outcome.
- Conflict objects.
- Validation status.
- Working-directory update plan.

Working-directory update should be transactional where possible:

1. Compute target snapshot.
2. Create write plan.
3. Validate paths and symlinks.
4. Write temporary files.
5. Atomically replace files where supported.
6. Record pre-operation safety checkpoint.
7. Update workspace ref only after successful materialisation.

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

- Execute against a specific snapshot or materialised workspace.
- Capture exit status and duration.
- Hash output rather than retaining unlimited logs by default.
- Record environment fingerprint optionally.
- Enforce time and output limits.
- Never equate success with proof of correctness.

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
