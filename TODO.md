# Implementation TODO

The roadmap is ordered. The local byte-correct model must exist before semantic or distributed features.

## Active vertical slice

- Milestone: 0 — Project and model foundation.
- Task: create the Dune project root (complete).
- Types: none; model types begin after project tooling is established.
- Invariants: Dune accepts the project metadata and a clean build succeeds.
- Tests: `dune build @all` passes with OCaml 5.5.0 and Dune 3.24.1.
- ADR changes: none; no architectural choice changes.

## Milestone 0 — Project and model foundation

### Project setup

- [x] Create Dune project.
- [ ] Select supported OCaml version.
- [ ] Configure formatting and linting.
- [ ] Configure unit and property-test CI.
- [ ] Add licence and contribution guide.
- [ ] Add ADR process.
- [ ] Add reproducible development commands.
- [ ] Add benchmark-result schema.
- [ ] Add fixture generator.

### Core identities and encoding

- [ ] Define typed IDs.
- [ ] Define hash abstraction.
- [ ] Select initial hash implementation.
- [ ] Select portable canonical encoding through ADR.
- [ ] Define object envelope.
- [ ] Define format version and feature flags.
- [ ] Add golden encoding fixtures.
- [ ] Reject unknown mandatory features.

### In-memory reference model

- [ ] Define file, tree, and snapshot types.
- [ ] Define scratch event and checkpoint.
- [ ] Define retention reason.
- [ ] Define pure event application.
- [ ] Define simple in-memory repository.
- [ ] Add generated directory-tree tests.

### Exit criteria

- [ ] Canonical object bytes are stable in golden tests.
- [ ] Snapshot identity is independent of timestamps.
- [ ] In-memory model passes generated operation sequences.
- [ ] Persistent code does not use OCaml `Marshal`.

## Milestone 1 — Canonical object store and snapshots

### Object store

- [ ] Implement immutable object write.
- [ ] Implement object read and verification.
- [ ] Implement atomic temporary-write-and-rename.
- [ ] Implement object-type envelope.
- [ ] Implement content-addressed path layout.
- [ ] Implement corruption detection.
- [ ] Implement rebuildable SQLite index if needed.

### Filesystem scanning

- [ ] Initialise `.paengi`.
- [ ] Exclude `.paengi`.
- [ ] Add ignore-file support.
- [ ] Scan regular files.
- [ ] Preserve executable mode.
- [ ] Preserve symlinks safely.
- [ ] Hash file content.
- [ ] Store trees canonically.
- [ ] Produce root snapshot.
- [ ] Reuse unchanged content.

### Large content

- [ ] Define inline versus chunk-manifest threshold.
- [ ] Implement fixed or content-defined chunks after benchmark.
- [ ] Implement file manifest.
- [ ] Add already-compressed fixture.
- [ ] Add large changing binary fixture.

### Materialisation

- [ ] Materialise snapshot to empty directory.
- [ ] Compare exact bytes and modes.
- [ ] Reject path traversal.
- [ ] Handle safe symlink creation.
- [ ] Add dry-run materialisation plan.

### Exit criteria

- [ ] Snapshot round trip is exact.
- [ ] Corruption is detected.
- [ ] Generated filesystem fixtures pass.
- [ ] Unknown file types remain byte-correct.

## Milestone 2 — Scratch history and restore

### Checkpoint creation

- [ ] Create initial checkpoint.
- [ ] Compute change set between snapshots.
- [ ] Record scratch event.
- [ ] Record resulting checkpoint.
- [ ] Add explicit `paengi checkpoint`.
- [ ] Add debounced polling mode.
- [ ] Create safety checkpoint before destructive operations.
- [ ] Add timeline query.

### Restore

- [ ] Restore retained checkpoint.
- [ ] Add dry-run.
- [ ] Preserve current work in a safety checkpoint.
- [ ] Handle untracked paths explicitly.
- [ ] Handle conflicts with external filesystem changes.
- [ ] Add restore verification.

### Pinning and tags

- [ ] User pin.
- [ ] User unpin.
- [ ] Automatic recent-window retention.
- [ ] Capsule-boundary retention placeholder.
- [ ] Validation-boundary retention placeholder.
- [ ] Timeline displays retention reason.

### Exit criteria

- [ ] A directory can be edited, checkpointed, and restored exactly.
- [ ] State-machine tests cover edit/checkpoint/restore sequences.
- [ ] Restart does not lose accepted checkpoints.

## Milestone 3 — Scratch compaction

### Retention policy

- [ ] Define policy configuration.
- [ ] Implement recent full-retention window.
- [ ] Implement periodic thinning.
- [ ] Implement storage budget.
- [ ] Ensure pins override expiry.
- [ ] Add `paengi compact --dry-run --explain`.

### Compaction planner

- [ ] Calculate retained checkpoint set.
- [ ] Calculate reachable objects.
- [ ] Identify removable events and objects.
- [ ] Estimate storage before and after.
- [ ] Plan periodic materialisation boundaries.
- [ ] Verify every retained snapshot in temporary generation.

### Safe publication

- [ ] Write new generation.
- [ ] Verify new generation.
- [ ] Atomically publish generation ref.
- [ ] Retain old generation during grace period.
- [ ] Add crash injection.
- [ ] Add idempotent restart.

### Experiments

- [ ] Implement reachability-only baseline.
- [ ] Implement chain-collapse strategy.
- [ ] Implement inverse-pair elimination only where exact.
- [ ] Benchmark retention policies.
- [ ] Publish storage versus restore-latency results.

### Exit criteria

- [ ] Property test proves retained-state equivalence.
- [ ] No pinned checkpoint is deleted.
- [ ] Crash at every publication point leaves a valid generation.
- [ ] Dry-run explains every removal.

## Milestone 4 — Change capsules

### Capsule types

- [ ] Define capsule.
- [ ] Define immutable capsule revision.
- [ ] Define dependency.
- [ ] Define exact file transition operation.
- [ ] Define textual operation and fallback.
- [ ] Define validation evidence.
- [ ] Define current-revision ref.

### Creation

- [ ] Create capsule from two checkpoints.
- [ ] Create capsule from current diff.
- [ ] Record stable capsule ID.
- [ ] Create first revision.
- [ ] Pin required scratch boundaries.
- [ ] Add title and description.
- [ ] Add `paengi capsule show`.

### Revision

- [ ] Enable capsule for editing.
- [ ] Fold selected scratch work into capsule.
- [ ] Create new immutable revision.
- [ ] Preserve old revision.
- [ ] Keep capsule ID stable.
- [ ] Add revision diff and history.

### Split and combine

- [ ] Propose path-based split.
- [ ] Require user confirmation.
- [ ] Combine compatible capsules.
- [ ] Preserve provenance.
- [ ] Add tests for dependency updates.

### Exit criteria

- [ ] Messy scratch sequence can become one coherent capsule.
- [ ] Stable identity and immutable revision properties pass.
- [ ] Applying a revision to its declared base reproduces expected snapshot or explicit conflict.

## Milestone 5 — Workspaces and conflicts

### Dependency graph

- [ ] Validate acyclic required dependencies.
- [ ] Detect conflicts-with declarations.
- [ ] Derive deterministic order.
- [ ] Support explicit precedence.
- [ ] Add `paengi work explain-order`.

### Composition

- [ ] Set base snapshot or release.
- [ ] Enable capsule revision.
- [ ] Disable capsule revision.
- [ ] Materialise selected composition.
- [ ] Produce per-operation outcomes.
- [ ] Record resulting workspace snapshot.
- [ ] Preserve safety checkpoint before rematerialisation.

### Conflict values

- [ ] Define conflict kinds.
- [ ] Persist conflict objects.
- [ ] List and inspect conflicts.
- [ ] Keep unrelated operations available.
- [ ] Resolve conflict.
- [ ] Record resolution provenance.
- [ ] Reattempt application after related changes.

### Exit criteria

- [ ] Composition is deterministic.
- [ ] Multiple non-overlapping capsules coexist.
- [ ] Overlapping operations create inspectable conflicts.
- [ ] Repository remains usable with unresolved conflicts.

## Milestone 6 — Releases and validation

### Validation

- [ ] Configure commands.
- [ ] Run command against a specific snapshot.
- [ ] Record exit status and duration.
- [ ] Bound output.
- [ ] Hash retained output.
- [ ] Add optional environment fingerprint.
- [ ] Pin passing checkpoints according to policy.

### Release

- [ ] Validate dependency closure.
- [ ] Materialise final snapshot.
- [ ] Record exact capsule revisions and order.
- [ ] Record validation evidence.
- [ ] Create immutable release ID.
- [ ] Verify release reproduction.
- [ ] Add optional signing abstraction.
- [ ] Add release inspection.

### Exit criteria

- [ ] Release final snapshot is reproducible.
- [ ] Validation evidence is bound to snapshot.
- [ ] Release remains unchanged when capsules receive later revisions.

## Milestone 7 — TypeScript semantic sidecar

### Parser adapter

- [ ] Select parser integration.
- [ ] Parse valid TypeScript.
- [ ] Handle parse failure safely.
- [ ] Identify declarations and structural paths.
- [ ] Produce semantic anchors with textual fallback.
- [ ] Detect simple rename.
- [ ] Detect simple move.
- [ ] Detect replace-node proposal.

### Application

- [ ] Match exact semantic identity.
- [ ] Match structural path.
- [ ] Match syntax/token similarity.
- [ ] Fall back to text context.
- [ ] Emit confidence.
- [ ] Emit ambiguity conflict.
- [ ] Never discard exact fallback.

### Experiments

- [ ] Build retargeting fixture suite.
- [ ] Compare with textual patch baseline.
- [ ] Measure correct application.
- [ ] Measure safe conflict.
- [ ] Measure false confident application.
- [ ] Publish failure examples.

### Exit criteria

- [ ] Semantic sidecars improve at least one defined retargeting workload.
- [ ] False-confidence cases are reported.
- [ ] Unsupported or invalid files remain byte-correct.

## Milestone 8 — Git import and export

### Import

- [ ] Select Git adapter strategy.
- [ ] Import blobs and trees.
- [ ] Import commits and parents.
- [ ] Import tags.
- [ ] Preserve author and message metadata.
- [ ] Map Git commit IDs to Paengi objects.
- [ ] Represent imported commits as opaque transitions initially.
- [ ] Verify imported checkout.

### Export

- [ ] Export one release as one Git commit.
- [ ] Export ordered capsules as linear commits.
- [ ] Preserve configured author and messages.
- [ ] Write refs.
- [ ] Record Paengi-to-Git mapping.
- [ ] Run `git fsck --full`.
- [ ] Compare checkout bytes.
- [ ] Document lost Paengi semantics.

### Exit criteria

- [ ] Existing Git repository can become a Paengi repository.
- [ ] Paengi release can become a valid Git branch.
- [ ] Final bytes match.
- [ ] Bridge limitations are explicit.

## Milestone 9 — Rust semantic sidecar

- [ ] Add Rust parser adapter.
- [ ] Handle modules and item paths.
- [ ] Preserve macro-heavy code through fallback.
- [ ] Add move and rename fixtures.
- [ ] Compare with TypeScript results.
- [ ] Document language-specific limitations.

## Milestone 10 — Local synchronisation prototype

Do not begin until the local format and model are stable.

- [ ] Define immutable object exchange.
- [ ] Define signed ref events.
- [ ] Define device identity.
- [ ] Implement local HTTP object transfer.
- [ ] Preserve divergent heads.
- [ ] Add encrypted bundle export/import.
- [ ] Add two-device integration tests.
- [ ] Add offline USB/shared-directory bundle workflow.

### Exit criteria

- [ ] Two devices exchange missing objects.
- [ ] Divergent workspace or release refs are preserved.
- [ ] No central service is required.

## Milestone 11 — Portfolio demonstration

- [ ] Create scripted demo repository.
- [ ] Show automatic recovery.
- [ ] Show scratch compaction.
- [ ] Show messy edits becoming a capsule.
- [ ] Show multiple enabled capsules.
- [ ] Show persistent localised conflict.
- [ ] Show retargeting with uncertainty.
- [ ] Show immutable release.
- [ ] Show GitHub-ready Git export.
- [ ] Publish benchmark and research report.
- [ ] Compare honestly with Git, Jujutsu, Pijul, and GitButler.
- [ ] Record a concise architecture walkthrough.

## Prototype definition of done

Paengi is a successful portfolio prototype when:

- The three-history model is visible in a usable CLI.
- Scratch compaction is proven safe for retained states.
- Capsule identity and revision semantics work.
- Multiple capsules compose into a workspace.
- Conflicts persist without globally blocking work.
- Releases reproduce.
- At least one semantic retargeting experiment has honest results.
- A release exports to valid Git.
