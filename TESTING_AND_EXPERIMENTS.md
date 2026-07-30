# Testing and Experiments

## 1. Testing philosophy

paengi's strongest portfolio value comes from making its model falsifiable.

Each core claim should map to an invariant, generated test, benchmark, or comparative experiment.

Paengi is a local VCS and persistent-data-model project. Testing is limited to repository correctness and checked-in local fixtures; external security analysis is outside scope. Bounds checks, corruption detection, atomic writes, and malformed-input handling remain required storage-system behavior.

## 2. Test layers

### Unit tests

Cover:

- Canonical encoding.
- Object IDs.
- Path validation.
- Snapshot construction.
- File-mode preservation.
- Scratch-event application.
- Retention classification.
- Capsule identity and revision identity.
- Dependency ordering.
- Conflict construction.
- Release identity.
- Git mapping records.

### Property tests

Use QCheck or an equivalent maintained OCaml property-testing library.

Property tests use bounded counts and a printed, reproducible seed. Independent per-property random states must be derived from that base seed so test order cannot alter generated inputs. Codec tests must include deterministically sampled zero, boundary, near-limit, and malformed byte lengths.

Generate:

- Directory trees.
- Byte contents.
- Scratch operation sequences.
- Checkpoint graphs.
- Retention policies.
- Capsule operation sequences.
- Dependency DAGs.
- Conflicting edits.
- Compaction plans.
- Git-style commit sequences for bridge tests.

Core properties:

#### P1 — Snapshot round trip

Serialise, store, load, and materialise a snapshot; resulting filesystem model is identical.

#### P2 — Scratch replay

Applying scratch events from a retained boundary yields the expected checkpoint snapshot.

#### P3 — Restore exactness

Restoring a checkpoint reproduces exact bytes and supported metadata.

Milestone 2 additionally checks immutable event/checkpoint replay, CAS head
publication, pin identity preservation, deterministic bounded ancestry
traversal, reopen recovery, failed-publication head preservation, disposable
index recovery, unsupported-record rejection, polling debounce/no-duplicate
behaviour, and restore-plan external-mutation rejection. A failed
populated-directory restore is tested for an available safety checkpoint and no
target-head advancement; it is not represented as crash-atomic unless an
operation journal is implemented.

Milestone 3 additionally checks deterministic recent-window and periodic
selection, pin precedence, permutation-independent selection, retained logical
snapshot equivalence after activated generation compaction, direct generation
schema decoding/goldens, replay verification, post-compaction checkpointing and
retention changes, repeated generation activation, resolver corruption
rejection, and idempotent cleanup resume. Deterministic fixtures compare the
dry-run canonical cleanup IDs, expected types, object count, and exact stored
file lengths with quarantine and prune results. Candidate-boundary faults run
before and after every quarantine and prune movement, reopen the repository,
resume, and verify retained logical restoration, active-generation stability,
and idempotence. Missing, wrong-path/type, foreign-generation quarantine,
stale-generation, and corrupt-manifest states reject structurally. The current
cleanup scope excludes shared content-domain objects pending full cross-domain
reachability.

#### P4 — Compaction preservation

Before and after compaction, every retained checkpoint resolves to the same snapshot.

#### P5 — Compaction idempotence

Running compaction again without new data does not change repository meaning.

#### P6 — Capsule revision immutability

A revision ID never resolves to different content.

Milestone 4 checks exact transition replay over bounded generated scratch
states, explicit text-fallback conflicts, ancestry-validated checkpoint-range
derivation, persistent Capsule/Capsule_revision/current-ref canonical goldens
and inverse decoders, reopen resolution, idempotent retry, current-ref CAS,
failure before/after visibility, pinned boundaries, parent/type/corruption
rejection, split/combine replay, and a seeded create/fold/show/split/combine
restart state machine. The forced seed is reported by the property executable.
Current-working-diff creation additionally checks exact double-scan creation,
no-change non-publication, deterministic external mutation rejection before
checkpoint publication, pre-current-ref interruption with a safely retained
checkpoint, idempotent retry, and boundary retention after reopen.
Single-capsule editing additionally checks revision-result materialisation,
safety checkpointing of divergent work, bytes/mode/symlink exactness, anchor
reuse when the result is already current, stale apply rejection without target
head publication, and folding from the returned anchor into a new immutable
revision.
Split/combine tests additionally prove that plans are read-only and expose
selected/source order, output bases/results, composition, provenance, and pins;
unconfirmed calls reject; confirmed calls retain exact replay and sources; and
the seeded restart state machine includes current creation, edit, fold, and
confirmed split/combine. Parent-cycle coverage uses the pure logical resolver
with a synthetic cycle. Persistent tests separately retain wrong-ID, corrupt,
missing-parent, wrong-type, and cross-capsule-parent rejection; no impossible
hash-verifying cyclic object fixture is claimed.

#### P7 — Stable capsule identity

Creating a new revision does not change capsule ID.

#### P8 — Composition determinism

Identical workspace inputs produce identical result and conflict set.

#### P9 — Dependency safety

No materialisation silently omits an unsatisfied required dependency.

#### P10 — Conflict persistence

Unresolved conflicts survive restart and remain associated with the same application context.

#### P11 — Release reproducibility

Rebuilding a release yields the recorded final snapshot ID.

#### P12 — Git export bytes

Exported Git branch checkout matches the paengi release snapshot.

### State-machine tests

Model command sequences:

- Init.
- Edit.
- Checkpoint.
- Restore.
- Pin.
- Compact.
- Create capsule.
- Revise capsule.
- Enable and disable.
- Resolve conflict.
- Create release.

Compare implementation state with a simple in-memory reference model.

### Failure-injection tests

Inject failure during:

- Object write.
- Checkpoint ref update.
- Compaction generation publication.
- Workspace materialisation.
- Capsule revision creation.
- Release creation.
- Git export.
- Index update.

Expected result:

- Old valid state.
- New valid state.
- Detectable recoverable staging state.

Generation failure states are: pre-activation immutable-object leftovers with
the prior ref unchanged; post-activation/pre-cleanup valid logical resolution
with excess objects; and partially quarantined manifest candidates resumed
idempotently. Candidate-level injection occurs before candidate zero, before
every later candidate, and after every candidate including the final movement
before normal completion. Permanent prune is tested separately from recoverable
quarantine; a prune retry accepts an absent candidate only when the active
generation's verified manifest names it.

## 3. Filesystem fixtures

Include:

- Empty files.
- Large files.
- Unicode names.
- Deep paths.
- Wide directories.
- Executable files.
- Symlinks.
- Rename chains.
- Delete and recreate.
- Invalid source files.
- Already-compressed binaries.
- Mixed line endings.
- Non-UTF-8 bytes where platform support permits.
- Files immediately below, at, and above the inline/manifest cutoff.
- Multi-chunk files, local large-file edits, and insertions near the beginning.
- Corrupt/missing/reordered chunks and manifests.
- Unsupported FIFOs, sockets, and device nodes where portable; each must return a structured path/category error without publishing a partial snapshot.

## 4. Scratch-history experiments

### E1 — Retention policy matrix

Generate or record realistic editing traces.

Compare:

- Keep every checkpoint.
- Time-window retention.
- Exponential thinning.
- Test-boundary pinning.
- Capsule-boundary pinning.
- Storage-budget retention.

Measure:

- Storage.
- Restore latency.
- Event replay length.
- Retained meaningful states.

### E2 — Compaction strategies

Compare:

- Reachability-only GC.
- Direct retained-snapshot preservation.
- Periodic snapshots plus deltas.
- Inverse-event elimination.
- Chunk-level deduplication.

Verify every retained state before comparing performance.

## 5. Capsule experiments

### E3 — Messy-to-curated workflow

Fixture:

- Implement feature.
- Add debug logging.
- Reformat unrelated file.
- Fix typo.
- Revert debug logging.
- Add tests.

Evaluate whether the user can create:

- One feature capsule.
- One optional formatting capsule.
- No permanent debug-log history unless retained intentionally.

### E4 — Capsule revision

Revise the same feature several times.

Verify:

- Stable capsule ID.
- Immutable revisions.
- Clear difference between implementation evolution and release history.

## 6. Composition experiments

### E5 — Parallel workstreams

Enable:

- Auth refactor.
- Logging fix.
- Parser experiment.

Test:

- Independent enable/disable.
- Shared-file overlap.
- Dependency declaration.
- Order explanation.
- Conflict localisation.

Compare conceptually with branch switching and virtual branches.

## 7. Semantic replay experiments

### Dataset categories

- Identifier rename.
- Function move.
- File move.
- Surrounding formatting.
- Added nearby duplicate.
- Base refactor.
- Signature change.
- Split function.
- Macro or generated code.
- Parse error.

### Baselines

- Exact precondition only.
- Text context patch.
- Token-based matching.
- Semantic-anchor matching.

### Outcomes

- Correct exact application.
- Correct uncertain application.
- Safe conflict.
- False positive.
- False negative.
- Validation pass or failure.

The report must highlight false positives prominently.

## 8. Performance benchmarks

Record:

- paengi commit.
- OCaml version.
- Compiler mode.
- OS and hardware.
- Filesystem.
- Fixture checksum.
- Cache state.
- Repetitions.
- Median and tail.
- Peak RSS.
- Bytes stored.
- Objects written.
- Replay depth.

Benchmarks:

- Initial scan.
- Incremental scan.
- Checkpoint creation.
- Restore.
- Timeline query.
- Compaction.
- Capsule application.
- Workspace rematerialisation.
- Semantic retargeting.
- Release creation.
- Git import/export.
- Large-content representation: encoded bytes, object count, reused bytes across versions, encoding, materialisation, and approximate allocation for deterministic content fixtures. These results choose a format but never act as CI timing thresholds.

## 9. Comparative demonstrations

For a small reproducible repository, document the equivalent workflow in:

- Git.
- Jujutsu.
- paengi.

Where practical, also show:

- Pijul.
- GitButler.
- Stacked Git changes.

The comparison should acknowledge features those tools already provide.

## 10. Release gates

### Model prototype gate

- Snapshot and restore property tests pass.
- Compaction preserves retained states.
- Process interruption during compaction preserves a valid generation.
- Storage statistics distinguish history classes.

### Local alpha gate

- Capsules and revisions work.
- Workspace composition is deterministic.
- Conflicts persist.
- Release reproduction works.
- CLI can explain states.

### Research beta gate

- TypeScript semantic adapter evaluated.
- False-confidence rate reported.
- Git import/export demonstrated.
- Comparative workflow report published.
- Repository format documented.

## 11. Suggested tooling

- Dune.
- Alcotest.
- QCheck.
- Bounded deterministic generated-input properties for pure codecs.
- SQLite bindings for indexes.
- Process-level benchmark scripts.
- `hyperfine` where appropriate.
- Golden fixtures for CLI and encodings.
- Git plumbing commands for bridge verification.
