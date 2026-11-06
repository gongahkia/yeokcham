# Yeokcham implementation report: GNN — phase title

Replace every placeholder with observed facts. This is a template, not a completed
report. Follow [Implementation workflow](../IMPLEMENTATION_WORKFLOW.md).

- Attempt: NN
- Status: complete / in_progress / blocked
- Branch: main
- Starting commit: FULL_SHA
- Design baseline/revision: FULL_SHA and any documented amendments
- Predecessor report and verified commits: PATH; HASHES
- Platform/toolchain: actual OS, versions, relevant dependencies
- Report path: docs/implementation/reports/GNN-attempt-NN.md

## Delivered behavior

Describe what works now and what changed for the user or dependent components.
Separate working behavior from planned behavior, mocks, and deferred adapters.

## Acceptance evidence

| Criterion from goal | Evidence: file, test, artifact, or observed result | Result |
| --- | --- | --- |
| Exact criterion | Reproducible evidence | passed / not met |

## Verification

| Command/run | Tested commit or identified working-tree state | Outcome and artifact |
| --- | --- | --- |
| Exact command | Exact revision | Exit/result; actual test count if known |

List unavailable checks, baseline failures, and deferred checks explicitly.
Each permitted deferral names its owner in the progress coverage ledger.
No unavailable check is counted as passed.

## Commits and rollback

| Implementation commit | Atomic purpose | Format/data effect |
| --- | --- | --- |
| FULL_SHA | One coherent change | None or exact effect |

- Rollback order: exact newest-first hashes, including dependency caveats.
- Data/recovery implications: what a source revert does and does not restore.
- Handoff commit: the commit containing this report/progress update; obtain its
  hash with `git log -1 --format=%H -- REPORT_PATH`. Include the actual hash in
  the final chat response after committing, without amending this file.

## Design and interface notes

Record concrete module/API locations, schema versions/vectors, meaningful choices,
and any authorized design amendments. State downstream effects.

## Scope and worktree audit

- Changed paths and their purpose: exact list/summary.
- README changes: none, or each additive/accuracy correction with evidence.
- Preserved pre-existing changes: exact paths, or none observed.
- Remaining uncommitted changes: exact `git status --short` result.
- Secrets/large fixture handling: confirm actual artifact locations.

## Remaining work and next handoff

- Current-phase remaining criteria/blocker: exact list or none.
- Completed phases / total: based on the tracker, not a feature-quality estimate.
- Outstanding coverage gates: actual ledger entries.
- Next eligible phase: GNN, this phase again if incomplete, or none if finished.
- Next prompt source: exact path from the progress tracker.
- Evidence the next agent must verify: predecessor report and implementation hashes.

In the final response, return this filled report as one copyable Markdown block.
Then return the complete next goal file in a separate text block starting with
`/goal`, with predecessor references appended. An incomplete report chains back
to the current phase. The next prompt is for the user to paste; do not run it.
