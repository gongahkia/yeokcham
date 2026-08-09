# Architecture

## 1. System overview

Yeokcham consists of a pure model core surrounded by storage, filesystem, parser, and CLI adapters.

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

### V2 local command boundary

V2-011 begins the executable split at the repository-root boundary.
`yeokcham_local_service` exposes typed root classification, V2 admission,
initialization, explicit archive, explicitly confirmed reset, and read-only
status/timeline/storage/verification outcomes. It delegates durable work to the
cutover, object-store, and inspection adapters and contains no command-line
parsing or rendering. `yeokcham_local_command` parses exact arguments and
renders those outcomes deterministically; its sole effectful operation invokes
the service. The executable remains the adapter that selects the command and
writes output. Its checked-in V1 demonstration exception stays outside the
reusable V2 service, so it cannot make a legacy root V2-ready.

This is a shell refactor, not a V2 model or persistent-format transition. Later
V2-011 slices can move the remaining command groups through the same boundary
without making command parsing a second source of canonical transitions.

V2-012 adds `yeokcham_local_daemon` beside that service boundary. It owns only
a versioned runtime socket, discovery file, and session capability outside the
strict `.yeokcham` layout. Binding a per-root endpoint is the singleton claim;
explicit stale recovery is based on connection refusal, never a PID kill. Its
small authenticated protocol currently offers liveness and controlled shutdown,
not repository mutation or durable authorization.

V2-013 adds `yeokcham_watcher` as a pure adapter boundary. Linux and macOS
observations normalize to sorted, unique, bounded relative-path scan requests;
rename includes both paths, while overflow and watcher loss request a whole-root
scan. These requests are advisory only: exact scanning remains authoritative and
normalization cannot create a checkpoint or canonical event. The Linux source
adapter recursively watches a non-symlink root with inotify, pairs in-tree move
cookies, and registers new directories before returning an advisory request.
Queue overflow, root loss, unmount, and incomplete watch coverage request a
whole-root rescan and explicit watcher restart. macOS FSEvents remains outside
the implementation until it is built and verified on macOS.

V2-014 currently supplies the pure `yeokcham_v2_scratch_scheduler` core. A
caller supplies positive monotonic-clock quiet-period and maximum-latency bounds;
the core coalesces normalized requests, emits each due scan once, and requests no
checkpoint publication for an unchanged exact scan. It neither reads a working
tree nor persists a checkpoint. ADR-053 replaces ADR-052's initial bootstrap
format with a canonical signed repository/device/public-signer/key-handle
bootstrap and a Linux Secret Service custody adapter for role-separated local
capabilities. It is not user identity, policy, a mutable scratch head, or an
automatic authority decision. ADR-054 frames each decrypted V2 object with an
authenticated canonical kind, so exact scratch snapshots and causal ledger
events can share the opaque create-only object namespace. ADR-055 builds a
device-scoped local scratch view over those frames: it publishes an immutable
snapshot first and a causally linked signed ledger event second, rejects
divergence rather than choosing a head, and treats an exact unchanged snapshot
as a no-write result. Its exact scanner and narrow scratch service carry an
explicit scan result into that durable transition. Daemon integration remains
separate; the daemon cannot invent snapshot bytes, keys, or a conflict
resolution.

## 2. Proposed OCaml workspace

```text
yeokcham/
  dune-project
  bin/
    yeokcham.ml
  lib/
    yeokcham_id/
    yeokcham_model/
    yeokcham_transition/
    yeokcham_store/
    yeokcham_snapshot/
    yeokcham_scratch/
    yeokcham_compaction/
    yeokcham_capsule/
    yeokcham_workspace/
    yeokcham_conflict/
    yeokcham_release/
    yeokcham_semantic/
    yeokcham_git/
    yeokcham_local_service/
    yeokcham_local_command/
    yeokcham_testkit/
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

- Yeokcham CBOR Profile 1: restricted deterministic CBOR for records, defined by [ADR-017](docs/adr/017-restricted-deterministic-cbor.md).
- Fixed Object Envelope 1 with object type, format version, payload length, and checksum, defined by [ADR-018](docs/adr/018-fixed-object-envelope.md); its object-format version and mandatory-feature rules are defined by [ADR-019](docs/adr/019-object-format-versions-and-mandatory-features.md).
- No `Marshal` for persistent repository data.

Object-store identity and storage-publication rules remain separate decisions.

ADR-020 resolves the initial store rule: a `Stored_object_id` is SHA-256 of the `yeokcham:object:v1\000` domain prefix followed by the exact Envelope-1 bytes. It is rendered as 64 lowercase hexadecimal characters at `.yeokcham/objects/<hex[0:2]>/<hex[2:4]>/<hex[4:64]>`. Writers use same-shard temporary files, file fsync, hard-link no-replace publication, and directory fsync; an existing final path is verified byte-identically or reported as collision/corruption. No overwriting rename fallback is permitted. Directory fsync unsupported by a filesystem weakens crash-durability guarantees and is documented rather than hidden.

### 4.3 Content IDs

Use a hash abstraction.

Initial implementation may use SHA-256 for portability. Benchmark BLAKE3 later if a maintained binding and distribution story are acceptable.

The model must not expose hash-algorithm assumptions everywhere.

### 4.4 Object database layout

Conceptual local layout:

```text
.yeokcham/
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
- Excludes `.yeokcham`.
- Applies ignore rules.
- Identifies changed paths.
- Hashes content.
- Chunks large files according to policy.
- Stores file manifests and trees.
- Produces a snapshot ID.
- Reuses unchanged object identities.

The initial scanner implements exact-path `.yeokchamignore` entries, excludes the root `.yeokcham`, stores Content/Tree/Snapshot schemas from ADR-021, and stores Chunk/File_manifest schemas from ADR-022. It keeps files at or below 64 KiB as Content v1 and streams larger files through deterministic Buzhash-64-v1 chunks (64-byte window; 16/64/128 KiB min/average/max). It supports regular files, executable mode, and symlinks without following them. Sockets, FIFOs, character devices, block devices, and other unsupported kinds return structured path/category errors before a snapshot is published.

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

Strategies should be pluggable and independently benchmarked. M3's checked-in
`scratch-retention-policies-v1` evidence exercises only the implemented
recent-window, periodic, and storage-budget selectors against a deterministic
pinned trace; it is not a general workload or performance claim.

Milestone 3 provides a deterministic planner over the verified ancestry. It
applies explicit recent-window/periodic/storage-budget policy and reports
reachable-object accounting before generation construction. The storage budget
is charged only to each selected source Checkpoint/Event pair, not shared
snapshot-content objects: protected retention and the logical scratch head are
mandatory, then optional recent and periodic checkpoints are selected in a
documented deterministic order. A protected-only overrun is reported rather
than silently removing recovery state. Immutable
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
4. Remove exact adjacent inverse edit pairs only after source and reduced
   replay both reach the retained target snapshot.
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

The Milestone 4 capsule service combines the pure `yeokcham_capsule` transition
core with `yeokcham_capsule_store`. ADR-025 adds immutable `Capsule_v1` and
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
`yeokcham_capsule.Parent_resolver` accepts synthetic logical parent graphs for
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

`yeokcham_workspace` remains the pure resolver/application core. ADR-026 adds
`yeokcham_workspace_store` as the persistence and guarded-materialisation shell:
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

`yeokcham_release` is a read-mostly durable adapter over verified immutable
workspace revisions and attempts. Release creation holds the existing
repository writer lock, rejects unresolved attempts, replays the exact attempt,
runs required validation through `yeokcham_validation`, writes immutable evidence
and a `Release_v1`, verifies reproduction, then creates the release binding.
The binding at `refs/releases/<release-id>` is expected-absent and is the only
visibility point. A crash before it leaves unreachable immutable objects only.

Release verification never trusts workspace-current or a rebuildable index: it
loads the release's physical workspace revision/attempt links and replays them.
Parent traversal is isolated behind a pure resolver seam for cycle tests.
`Requires_release.satisfied` uses only that verified parent graph; it cannot be
applied to `Workspace_revision_v1` because ADR-026 has no typed base-release
link. `Release_attestation_v1` is a separate Envelope type 22 object managed by
`yeokcham_release`; it has no release ref and cannot mutate a release. The v1
deterministic signer is test-only, not a production cryptographic mechanism.

Milestone 1 materialisation is intentionally narrower: it emits an inspectable dry-run plan and writes only to an existing empty destination with exclusive file creation. It preserves regular bytes, executable mode, directories, and symlink target bytes; unsafe decoded names and nonempty destinations reject. Workspace transactional replacement and safety checkpoints remain scratch/workspace work.

Milestone 2 restore is a guarded, but not crash-atomic, populated-directory
operation.  It scans and durably checkpoints differing current work, binds a
dry-run plan to that scan, rescans before applying, validates each safe path,
then rescans the result before target-head publication.  On an I/O failure the
safety checkpoint provides recovery; Yeokcham reports rather than conceals any
possible partial filesystem application.

## 10. Semantic sidecar architecture

### Phase 1: parser-assisted anchors

For TypeScript:

- Parse source.
- Identify declarations and structural paths.
- Attach textual fallback context.
- Detect simple declaration moves and renames.
- Avoid pretending to know semantics across dynamic behaviour.

For Rust M9-01/M9-02/M9-03:

- Parse only bounded top-level items from a verified snapshot virtual map.
- Return item kind, optional syntactic name, and UTF-8 byte spans.
- Resolve only caller-selected virtual roots, standard `foo.rs`/`foo/mod.rs`
  candidates, and inline modules from that map.
- Return root-scoped transient module/item path facts or explicit incomplete
  statuses; never infer a Cargo root.
- Return bounded canonical textual-fallback-required facts for macro
  definitions/invocations, outer attributes, and parser damage.
- Mark parser damage incomplete; preserve macro-heavy, invalid, and non-UTF-8
  files through textual fallback.
- Defer move/rename inference, name/type resolution, macro expansion,
  attributed/conditional modules, and semantic application.

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

### Milestone 7 bounded implementation

`yeokcham_semantic` currently supplies a Yeokcham-owned, dependency-free adapter
for supported top-level TypeScript declarations. It is a pure in-memory model,
not a persistent adapter: it receives source bytes and returns parse results,
proposals, matches, conflicts, or proposed result bytes. It has no object-store,
snapshot, ref, workspace, capsule, release, or CLI dependency.

Each proposal holds complete expected/replacement fallback bytes plus textual
context. The only automatic operation is a declaration-name rewrite located by
a unique same-kind/name/normalized-signature match. Normalized signatures retain
literals and remove only whitespace/comments and trailing parameter commas.
Structural and token-similarity matches report evidence but require manual
review. Parser errors, ambiguous anchors, low confidence, and textual-context
matches return explicit sidecar results without changing bytes.

This is an experiment boundary, not a persistent semantic format or a full
TypeScript parser integration. `yeokcham_typescript_adapter` is the separately
approved optional full-parser boundary: it invokes the locally pinned
TypeScript `5.9.3` Compiler API through protocol v1 with direct Node argv,
bounded stdin/stdout/stderr, and a timeout. It builds an in-memory virtual file
map only from a verified immutable `Snapshot_id`; it never reads the live
working directory, host `node_modules`, a global TypeScript package, or project
configuration/plugins outside that map.

The adapter returns language-neutral declaration evidence, diagnostics, UTF-8
byte spans, and parser/resolution completeness. Compiler symbols and internal
IDs never enter Yeokcham types or storage. A guarded `replace-node` request
checks exact preimage bytes and SHA-256, node kind and shape digest, splices the
selected byte range, reparses, verifies the structural context, and proves the
prefix/suffix unchanged. Adapter absence, timeout, malformed output, crash,
parse damage, resolution incompleteness, or size limits become a structured
semantic-unavailable result; exact textual fallback remains independent.

Neither module creates an object, ID, ref, schema, golden format, workspace
state, capsule revision, release, validation result, or attestation.
`yeokcham_textual_patch` is the independent baseline: it uses
only bytes, original spans, and bounded before/selected/after context. It
neither links to the Compiler API nor accepts declaration, parser, symbol, type,
or confidence evidence. Semantic persistence still requires separate format
approval and an ADR.

`yeokcham_semantic_retarget` is a separate pure selector over nonpersistent
evidence facts. It emits ordered candidate reports, completeness flags, alias
resolution status, selected stage, confidence, fallback status, and a concrete
uncertainty reason. `yeokcham_semantic_fixtures` is a checked-in versioned
40-case dataset used by both strategies; its oracle names expected bytes or a
safe conflict. The selector has no storage, compiler process, or permanent
identity dependency.

`yeokcham_semantic_experiment` runs both strategies with identical fixture bytes,
operation intent, oracle, splice validation, and classification rules. It emits
the checked-in version-1 report at
`docs/experiments/results/semantic-retargeting-v1.json`, checked against the
co-located JSON Schema by `make semantic-experiment`; `make check` validates
the checked-in result. Timings are host-specific evidence, never a correctness
gate. This experiment schema is documentation evidence only, not a Yeokcham
persistent format.

### Milestone 9 Rust syntax boundary

`yeokcham_rust_adapter` is a separate ephemeral protocol-v1 boundary approved by
ADR-035, ADR-036, and ADR-037. It invokes a caller-configured, directly executed local
helper built from `tools/yeokcham-rust-adapter/Cargo.lock`; analysis itself invokes neither
Cargo nor `rustc`. The helper uses pinned `tree-sitter 0.26.11` and
`tree-sitter-rust 0.24.2`, receives only sorted safe `.rs` source bytes
materialised from a verified immutable snapshot, and returns bounded top-level
syntax item evidence, parser diagnostics, UTF-8 byte spans, and explicit parser
completeness. M9-02 additionally accepts caller-selected safe virtual roots and
returns bounded root-scoped standard-module/item-path evidence or structured
incompleteness. M9-03 separately returns bounded canonical fallback facts for
macro-sensitive syntax, outer attributes, and parser damage; they only require
an independent exact textual path and do not expand or rewrite source.

The boundary neither receives nor reads a live path, repository path, Cargo
manifest/configuration, project dependency, host configuration, network,
macro expansion, or project code. It rejects invalid UTF-8 rather than changing
canonical bytes. Helper absence, malformed protocol, timeout, crash, bound
failure, invalid input, invalid snapshot, and parser damage return structured
unavailable/incomplete outcomes. It does not create model state or provide
Cargo/workspace roots, module attributes/configuration, imports, resolved
symbols/types, semantic identities, rewrites, or behavioural claims.
`yeokcham_typescript_adapter`, the pure sidecar experiment,
and `yeokcham_textual_patch` remain independent.

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
- Enforce time and output limits through a Yeokcham-owned runner interface.
- Clean temporary materialisation where possible; process-group termination is best effort by host.
- Never equate success with proof of correctness.

Milestone 6 adds immutable `Validation_evidence_v1`; it is not a mutable
workspace/scratch annotation and cannot advance canonical refs. Release creation
uses only evidence bound to the exact final snapshot.

`validation run --retain-passing-checkpoints` is the explicit M6-D01 exception
to a no-retention side effect: after evidence storage, it may append a
`Validation_passed` reason to every exact snapshot-matching scratch checkpoint.
It advances only `retention-head`; ordinary validation and release validation
continue to leave scratch/workspace/release refs unchanged. Failed or unmatched
evidence is an inspectable no-op, not an inferred checkpoint choice.

## 13. Git bridge

### Import architecture

Use a mature Git library or invoke Git plumbing through a controlled adapter.

Milestone 8's adapter resolves the configured Git executable before use,
accepts only an absolute existing repository directory, invokes Git by direct
argv with a bounded process runner, and verifies bounded `rev-parse` facts
before reading objects through `cat-file`. M8-01 imports one tree recursively
into immutable Content/Tree/Snapshot objects, maps only modes `100644`,
`100755`, and `120000`, and creates one ADR-028 immutable mapping binding.
Tree/blob bytes, entries, and nesting are independently bounded.

M8-02 reads one requested commit's raw header block after exact type
verification. It requires one tree header, retains ordered direct parent IDs,
verifies each declared parent is a commit object, imports the declared tree, and
establishes ADR-029's v1 opaque transition and Git-mapping v2 compatibility
forms. It rejects unsafe names, unsupported modes, malformed trees/headers,
missing or wrong-type objects, duplicate/self parents, and process/output-limit
failures before the applicable immutable binding. It neither recursively imports
the parent graph nor assigns metadata Yeokcham semantics. Git remains the owner of
Git-object, pack, delta, and compatibility parsing; Yeokcham has no general
Git-format compatibility contract. The preflight result is never a repository
identity or persistent metadata.

M8-04 imports a new `Imported_transition_v2` for each current commit import.
It requires exactly one nonempty raw `author` and `committer` header, retains
their byte values (including source timestamp/time-zone bytes), and stores the
exact message bytes as `Snapshot.Content`. It rejects duplicate, empty,
NUL-containing, or missing metadata headers before transition visibility, uses
Git-mapping v3 without changing mapping payload shapes, and prints only
hex-safe identity bytes plus the message Content ID. No author, timestamp,
message, or encoding interpretation is a Yeokcham semantic field.

M8-03 resolves one exact `refs/tags/<name>` ref with bounded direct-argv
plumbing. A direct commit/tree/blob ref becomes an opaque lightweight imported
tag. A ref resolving to a tag object retains the exact bounded raw tag-object
bytes in `Snapshot.Content`; exactly one matching `tag` header, target, and
target type are required. Imported tags and Git-mapping v3 bindings are
immutable provenance only: no tag becomes a Yeokcham release, capsule, or history
ref, and no signature is verified.

Import:

- Commit graph. M8-02 records direct ordered parent identities for one commit;
  it does not recursively import a graph.
- Trees and blobs. M8-01 implements a single tree/blob snapshot import, reused
  by M8-02 for the commit's declared tree.
- Author/committer/timestamp/message metadata. M8-04 retains exact source bytes
  in an opaque imported transition; it does not normalize or interpret them.
- Parent relationships. M8-02 stores direct ordered Git parent IDs only.
- Tags. M8-03 imports one lightweight or annotated tag pointing directly to a
  commit, tree, or blob; nested tag targets fail closed.
- Mapping records. M8-01 implements tree-to-snapshot mappings; M8-02 adds
  commit-to-opaque-transition mappings in v2; M8-03 adds tag-to-opaque-tag
  mappings in v3; M8-04 reuses the v3 commit mapping form for transition v2.

Imported commits initially become opaque transitions. Semantic inference is optional post-processing.

### Export architecture

Materialise snapshots and write:

- Git blobs.
- Trees.
- Commits.
- Refs.
- Mapping metadata.

M8-08 exports one verified immutable release as one root Git commit. It reads
only Yeokcham objects, hashes exact regular-file and symlink-target bytes with
filters disabled, builds trees through an isolated temporary index, and writes
the create-only `refs/heads/yeokcham/release-<release-id>` ref. Author and
committer are the fixed `Yeokcham Export <noreply@yeokcham.local>` identity at the
release `created_at` UTC timestamp; the message is exact release bytes or the
documented fallback. It then publishes ADR-028's `export/commit ->
exported-release` mapping. The Git ref and Yeokcham mapping binding remain
separate retryable visibility points. Nested empty directories, unsupported
nodes, invalid timestamps, bounds, malformed output, and ref collisions reject
explicitly.

M8-10 adds an optional complete release-export metadata value: distinct
configured author and committer name/email pairs plus exact non-NUL message
bytes. It validates this value before Git publication, uses the release
`created_at` UTC timestamp for both headers, rereads the commit to verify all
three fields, and retains the M8-08 path byte-for-byte when metadata is absent.
Configured metadata remains invocation input rather than Yeokcham state: it does
not alter the release, release object, final snapshot, or mapping payload. Its
create-only external ref is `refs/heads/yeokcham/release-<release-id>-metadata-<sha256>`
where the SHA-256 is a domain-separated length-delimited encoding of all five
configured byte strings. Thus different metadata has a distinct Git commit,
ref, and mapping ID, while identical retry is idempotent. M8-09 revision export
retains its fixed metadata policy; merge topology, tags, signatures, and
configured revision metadata are later work.

M8-09 exports a nonempty caller-declared ordered list of immutable revision
links. It replays and verifies each link before Git publication, requires every
adjacent expected-result/declared-base snapshot pair to match, and writes the
first result as a root commit then each later result with exactly one parent:
the preceding exported commit. Its create-only target ref is a SHA-256
domain-separated digest of the ordered capsule ID, revision ID, and revision
object ID triples. Each commit has fixed `Yeokcham Export` metadata at that
revision's `created_at` UTC timestamp, a fixed identity message, and an
ADR-028 `export/commit -> exported-revision` mapping. The Git line does not
encode capsule parents, dependencies, provenance, workspaces, conflicts,
resolutions, or releases. Ref and per-commit mapping visibility remains
separately retryable; malformed links, duplicate selections, chain mismatch,
bounds, nested empty directories, ref collision, and source corruption reject
explicitly.

## 14. Local synchronisation

M10-01 implements ADR-038's transport-neutral immutable-object exchange core
and in-process local-store adapter. `yeokcham_exchange` validates exact
length-delimited canonical CBOR frames, Hello compatibility, page ordering,
session/sequence/request membership, and every protocol budget before returning
a receipt candidate. `yeokcham_exchange_store` validates the exact Envelope-1
bytes and ADR-020 ID, then delegates publication to `Yeokcham_store.put`.

The adapter transfers caller-declared object IDs only. It does not infer graph
closure, move a ref, choose a divergent head, write a sync journal, or expose a
CLI/transport. A restart begins a new session and safely reoffers objects
already published before interruption.

M10-02 adds `yeokcham_ref_event` and `yeokcham_ref_event_store`. An immutable
Envelope-1 `Ref_event` expresses an exact Ed25519-signed proposed CAS
transition. Verification accepts only a caller-supplied bounded public-key map;
an absent key is explicitly untrusted. Event storage, transfer, verification,
replay/order evaluation, and divergence reporting never call mutable-ref CAS.
Key discovery/lifecycle, ref application, reconciliation, device identity, and
transport remain separate layers.

M10-03 adds `yeokcham_device` and `yeokcham_device_store`. A Device_identity v1 is
an immutable public Envelope-1 object binding one random opaque 32-byte device
ID to an Ed25519 public key and ADR-039 signer-key ID. Generation returns an
in-memory caller-owned private capability; the object store serialises public
declaration bytes only. A bounded caller-supplied registry resolves an already
verified ref-event signer to one device, unmapped, or ambiguous result. Device
resolution does not trust a key, modify an event/ref, choose divergence, or
persist registry state. Private-key storage, discovery, rotation, revocation,
and transport remain separate layers.

M10-04 adds `yeokcham_http_exchange`, a local HTTP/1.1 adapter over unchanged
ADR-038 frames. One `POST /v1/exchange` carries one bounded frame; destination
transient state accepts Hello, returns Want for Inventory, publishes each
verified Object through the existing adapter, and clears on End. The socket
adapter closes each request connection and restart reoffers caller-declared
immutable IDs. HTTP parsing, response status/body, frame, budget, store, and
interruption failures are structured. It has no CLI, authentication, persistent
session, ref operation, reconciliation, or divergence selection.

M10-05 adds `yeokcham_divergence` and `yeokcham_divergence_store`. The functional
core canonically encodes an Envelope type-28 `Divergent_ref_set_v1`: one
repository digest, safe ref name, observed ref state, and 2–4,096 sorted exact
`Ref_event` links. It accepts only caller-held ADR-039 verified events and
rejects duplicate IDs or a context mismatch. The store adapter reloads every
linked type-26 object, recomputes its event ID, verifies it against the bounded
explicit key map, and compares it to the stored set before use. A checksummed
`refs/sync-divergence/<ref>` binding points to one immutable canonical set;
publication serialises the binding namespace, unions only validated candidates,
uses its bounded CAS retry path, and never replaces a corrupt binding. It does
not read or write application refs, select a candidate, reconcile targets,
persist trust/device state, or add CLI mutation.

M10-06 adds `yeokcham_bundle` and `yeokcham_bundle_store`. The pure core canonically
encodes and validates ADR-042's external `encrypted-bundle-v1` header and
plaintext, verifies each exact Envelope-1 byte string against its stored-object
ID, and opens ChaCha20-Poly1305 only with the full canonical header as AAD. The
adapter reads only caller-declared immutable objects, obtains one 12-byte nonce
from the OS CSPRNG, and exports bytes without repository mutation. Import
completely decodes and validates before its first create-only `Yeokcham_store.put`;
a later publication failure leaves only a valid retryable immutable prefix. It
does not read or write a mutable ref, divergence binding, trust/device record,
or key record, and adds no CLI or key-source convention.

M10-08 adds `yeokcham_bundle_directory`, an external local-directory adapter over
unchanged ADR-042 encrypted bytes. It creates an exclusive `.partial` file,
fsyncs it, links one no-replace `.yeok` final file, and fsyncs the directory;
listing returns only sorted recognised regular final/partial descriptors. A
caller selects an abstract final descriptor for inspection or import. Inspection
fully authenticates/decrypts without publication; import reuses ADR-042's
complete validation and ADR-020 create-only publication. It has no directory
cursor, repair, deletion, watcher, service, ref/binding/trust/device mutation,
CLI, or key-source convention.

M10-11 documents the supported decentralised boundary: local in-process/TCP
exchange and caller-selected shared-directory bundles run with two repositories
and no central service. Neither path supplies peer identity, availability,
authorisation, key recovery, replay protection, ref synchronisation, or
automatic reconciliation; those remain caller-held or future decisions.

Future layers require separate decisions:

- Signed ref or operation events.
- Device key lifecycle.
- Conflict-preserving ref reconciliation.

Yeokcham does not require consensus for single-user multi-device use. It requires preserving divergent heads and letting the user reconcile them.

## 15. Observability

CLI inspection should make the model understandable:

```text
yeokcham timeline --graph
yeokcham capsule show --operations
yeokcham work explain-order
yeokcham conflict show
yeokcham compact --dry-run --explain
yeokcham release verify --explain
yeokcham storage stats --by-history
```

M12 implements the non-mutating subset as `status`, `timeline`, `storage
stats`, and repository-wide `verify`. `yeokcham_inspection` is an imperative
read adapter over verified immutable objects rather than a second source of
repository truth. It first enumerates object paths through `yeokcham_store`,
ignoring the dot-prefixed interrupted-publication temporaries tolerated by the
store and hash- and envelope-verifying each canonical object; higher-level
checks then reuse the snapshot, capsule, workspace, and release resolvers.
Storage accounting reports exact regular-file lengths. Retained checkpoint bytes
resolve logical IDs through the active compacted generation and de-duplicate
physical checkpoint IDs, so that subtotal is intentionally not summed into a
domain total. The layer has no write API, cache, repair action, or inferred
metadata.

Machine-readable JSON output should exist for experiments and future UI work.

## 16. Upgrade strategy

Persistent objects are immutable. Format upgrades should:

- Add new object versions.
- Create new refs or generations.
- Preserve old objects during migration.
- Include migration verification.
- Keep old-format fixtures.
- Never mutate the only readable copy in place.
