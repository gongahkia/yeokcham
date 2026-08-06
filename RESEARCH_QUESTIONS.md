# Research Questions

Yeokcham should produce measured answers, not only software.

## 1. Scratch retention

### Q1

How much automatic history is required for users to feel safe?

Variables:

- Full checkpoints retained for 24 hours, 72 hours, or seven days.
- Periodic checkpoints retained for weeks.
- Size-based versus time-based budgets.
- Test-passing and capsule-boundary pinning.

Measurements:

- Storage consumed.
- Maximum restore latency.
- Number of recoverable user-significant states.
- Number of deleted states users later attempt to access in a user study or self-study.

### Q2

Which compaction transformations produce meaningful savings without making recovery slow?

Compare:

- Snapshot-only retention.
- Event-chain retention.
- Periodic full snapshots plus deltas.
- Content-defined chunk storage.
- Inverse-event elimination.
- Formatting-only checkpoint collapsing where exact snapshot boundaries are not retained.

## 2. Capsule creation

### Q3

Can a useful capsule be inferred from a checkpoint range without pretending to know intent?

Possible signals:

- Path groups.
- Symbol groups.
- Temporal clusters.
- Test-state boundaries.
- Repeated co-edits.
- User-selected ranges.

Evaluation:

- How much manual correction is needed?
- Does the suggested capsule improve reviewability?
- Does it split unrelated edits safely?

The first implementation should present proposals, not automatic truth.

## 3. Composition

### Q4

When several capsules modify the same area, which dependency and ordering model is understandable?

Compare:

- Explicit total order.
- Dependency DAG plus deterministic tie-break.
- Path-local ordering.
- User-defined precedence only where overlap exists.

Metrics:

- Predictability.
- Number of required manual order constraints.
- Stability after capsule revision.

### Q5

Can capsule composition support several concurrent workstreams more clearly than branches or virtual branches?

Demonstration scenario:

- Authentication refactor.
- Logging fix.
- Experimental parser.
- One capsule enabled or disabled independently.
- Overlapping and non-overlapping changes.

## 4. Retargeting

### Q6

Does semantic-anchor replay outperform textual context for common refactors?

Datasets:

- Function rename.
- Function move.
- Class split.
- Module reorganisation.
- Formatting changes.
- Nearby unrelated edits.
- Duplicate similar functions.
- Macro-heavy Rust cases.

Outcomes:

- Exact correct application.
- Correct application with validation.
- Safe conflict.
- False confident application.
- Missed application.

False confident application is the most important failure metric.

### Q7

What confidence representation best communicates risk?

Candidates:

- Exact/high/medium/low/unknown.
- Match score plus evidence.
- Outcome categories only.
- Human-readable explanation of anchor resolution.

## 5. Conflict model

### Q8

Does storing conflicts as persistent values reduce workflow blockage?

Test:

- Create multiple conflicts in one workspace.
- Continue editing unrelated files.
- Revise another capsule.
- Resolve conflicts independently.
- Reattempt a capsule after base changes.

Measure:

- Operations that remain available.
- User understanding.
- Conflict lifetime and resolution traceability.

## 6. Release history

### Q9

Does separating release history produce a cleaner audit trail than squashed Git history?

Compare:

- Original scratch sequence.
- Intent capsules.
- Release composition.
- Exported Git branch.

Evaluate:

- Ability to explain why code exists.
- Ability to reproduce release.
- Ability to inspect implementation evolution.
- Storage cost.

## 7. Storage

### Q10

Which storage representation is appropriate for scratch versus release objects?

Potential result:

- Scratch history favours fast append and compaction.
- Release history favours immutable durable snapshots.
- Capsule operations favour small structured records.
- Large files favour chunk manifests.

Benchmark them separately rather than forcing one representation.

## 8. Git bridge

### Q11

What information is inevitably lost when mapping between Yeokcham and Git?

Likely losses:

- Scratch retention semantics.
- Stable capsule identity across rewritten Git commits.
- Persistent conflict state.
- Workspace composition.
- Semantic operation evidence.

The bridge should document loss rather than simulate perfect equivalence.

## 9. Evaluation against existing tools

For each demonstration, compare the user workflow with:

- Git.
- Jujutsu.
- Pijul where practical.
- GitButler for parallel work.
- A stacked-change workflow.

Do not compare only command count. Compare:

- Conceptual states users must manage.
- Recoverability.
- Review output.
- Storage.
- Failure visibility.
- External interoperability.
