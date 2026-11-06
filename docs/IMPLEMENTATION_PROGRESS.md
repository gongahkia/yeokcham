# Implementation progress

Updated November 6, 2026. This is the shared implementation ledger. Follow
[Implementation workflow](IMPLEMENTATION_WORKFLOW.md) for execution, reports,
verification, commits, and rollback. Each new agent reads and updates this file.

## Current state

- Design baseline: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`.
- Branch: `main`; one implementation writer at a time.
- Active implementation phase: none.
- Next ready phase: [G01 — local baseline](implementation/goals/G01-baseline.md).
- Completed phases in this chain: **0 / 20**.
- Handoff workflow and all 20 goal prompts are prepared; runtime implementation
  from this chain has not started. Existing V1/undo functionality predates it.
- Current blocker: none for starting G01. Later native OS, resource, and human
  evidence gates remain pending; they are not presumed available or passed.

Update the active phase/session label and starting commit when work starts.
Update meaningful checkpoints while working, and reconcile all fields at closeout.
A completion report without supporting commits/tests does not complete a phase.

## Phase ledger

The default chain is sequential. Every phase requires the previous phase's
accepted report and implementation commits; domain dependencies are in the goal
files and TC08. Do not skip a failed phase or execute later prompts concurrently.

| Phase / copyable prompt | Prerequisite | Status | Implementation commits / latest report | Remaining |
| --- | --- | --- | --- | --- |
| [G01: Build the measurement harness and capture the local baseline](implementation/goals/G01-baseline.md) | Verified design baseline | ready | — | All criteria in prompt |
| [G02: Implement canonical records, identities, and shared interfaces](implementation/goals/G02-canonical-records.md) | G01 | pending | — | All criteria in prompt |
| [G03: Implement causal authority, member identity, and review-policy evaluation](implementation/goals/G03-authority-policy.md) | G02 | pending | — | All criteria in prompt |
| [G04: Implement deterministic composition and exact integration plans](implementation/goals/G04-composition-plans.md) | G03 | pending | — | All criteria in prompt |
| [G05: Implement native ignore rules and reliable portable capture](implementation/goals/G05-capture-ignore.md) | G04 | pending | — | All criteria in prompt |
| [G06: Persist history and indexes incrementally with atomic roots](implementation/goals/G06-incremental-history.md) | G05 | pending | — | All criteria in prompt |
| [G07: Implement lossless compression, indexed packs, and safe collection](implementation/goals/G07-compression-packs.md) | G06 | pending | — | All criteria in prompt |
| [G08: Synchronize immutable shared history with verified offline coverage](implementation/goals/G08-shared-sync.md) | G07 | pending | — | All criteria in prompt |
| [G09: Implement private account identity, device enrollment, and recovery custody](implementation/goals/G09-private-identity.md) | G08 | pending | — | All criteria in prompt |
| [G10: Implement complete encrypted backup and exact private-history restoration](implementation/goals/G10-private-archive.md) | G09 | pending | — | All criteria in prompt |
| [G11: Implement automatic private retention and inherited settings](implementation/goals/G11-retention-settings.md) | G10 | pending | — | All criteria in prompt |
| [G12: Implement native optional and required review workflows](implementation/goals/G12-review-workflow.md) | G11 | pending | — | All criteria in prompt |
| [G13: Implement exact recoverable integration and remove delivery friction](implementation/goals/G13-recoverable-integration.md) | G12 | pending | — | All criteria in prompt |
| [G14: Complete native workspace and ordinary CLI journeys](implementation/goals/G14-workspace-cli.md) | G13 | pending | — | All criteria in prompt |
| [G15: Implement the durable per-user background scheduler](implementation/goals/G15-background-core.md) | G14 | pending | — | All criteria in prompt |
| [G16: Integrate managed macOS and Linux services](implementation/goals/G16-macos-linux-services.md) | G15 | pending | — | All criteria in prompt |
| [G17: Implement Windows support immediately after macOS/Linux service work](implementation/goals/G17-windows-support.md) | G16 | pending | — | All criteria in prompt |
| [G18: Validate and refine the complete effortless CLI experience](implementation/goals/G18-experience-audit.md) | G17 | pending | — | All criteria in prompt |
| [G19: Collect full benchmark evidence and resolve measured regressions](implementation/goals/G19-performance-evidence.md) | G18 | pending | — | All criteria in prompt |
| [G20: Verify the complete design and close the implementation ledger](implementation/goals/G20-final-validation.md) | G19 | pending | — | All criteria in prompt |

Allowed states: `pending`, `ready`, `in_progress`, `complete`, `blocked`,
`rolled_back`. Record the reason and exact remaining criteria for a blocked or
partial phase. Do not relabel a partial phase complete to expose the next prompt.

## Current-phase checkpoints

No implementation checkpoints yet. Replace this paragraph with the active
phase, session label, starting SHA, finished checkpoints, next action, and any
unexpected pre-existing/overlapping changes. Preserve completed checkpoints in
that phase's report when advancing.

## Evidence and coverage gates

These gates prevent a completed implementation stage from implying validation
that has not happened. Record exact tested revisions and evidence links. If later
runtime changes affect a gate, mark its evidence stale and revalidate it. A
subsequent documentation-only commit need not invalidate runtime evidence; record
that relationship explicitly.

| Gate | Owner phase(s) | State | Required evidence |
| --- | --- | --- | --- |
| Local existing-runtime baseline and reproducible runner | G01 | pending | Commands, fixture hashes, source SHA, local build/CI outcomes, small ordinary-source results |
| Canonical records, causal policy, deterministic composition | G02-G04 | pending | Golden/negative/property cases and actual interfaces |
| Capture/history/storage integrity and maintenance recovery | G05-G07 | pending | Exact-byte tests, restart/collection/pack fault cases, incremental work measurements |
| Shared offline coverage and concurrent-history preservation | G08/G13 | pending | Missing closure, offline unvisited state, receipt permutation and journal evidence |
| Private recovery and complete archive before eviction | G09-G11 | pending | Fresh-device recovery, rejected unauthorized access, interrupted manifests, protected-root tests |
| Review/confirmation boundaries and public/private separation | G12-G14 | pending | Both toggles, direct/required/offline paths, no private publication or false approval |
| Background lifecycle and resource behavior | G15-G17 | pending | Restart/wake/pause/credential/disk-pressure cases and measured scheduling behavior |
| Native macOS validation | G16/G20 | pending | Real macOS candidate-revision build/tests and service/fidelity journeys |
| Native Linux validation | G16/G20 | pending | Real Linux candidate-revision build/tests and systemd/fidelity journeys |
| Native Windows validation | G17/G20 | pending | Real Windows candidate-revision build/tests and login-service/fidelity journeys |
| Complete automated CLI journeys | G18/G20 | pending | Text/JSON/noninteractive/recovery/source/document flows, actual outputs |
| Nontechnical comprehension evaluation | G18/G20 | pending | Actual participant observations and resolved findings; an agent walkthrough is insufficient |
| Full source, monorepo, binary/asset performance evidence | G19 | pending | Full selected tiers/sample counts, equivalent baseline comparisons, correctness gates, hardware/limits |
| Integrated CI, packaging and self-hosted server smoke | G20 | pending | Candidate-revision required checks and applicable disposable package/container journeys |

Resource or host limitations belong here with concrete evidence, owner, and the
next action. Only explicitly deferred gates may wait while a bounded phase
completes; its own required checks must pass. All mandatory gates must close
before the overall implementation is reported complete.

## Reports and reconciliation

Use [Report template](implementation/REPORT_TEMPLATE.md) and append attempt
reports under `docs/implementation/reports/`. Put a clickable report link in the
phase row when the file exists, with exact implementation commit hashes. Reports
include rollback ordering, format/data implications, check outcomes, README
changes, and the next prompt source. Do not invent future file links or SHAs.

When reconciling a pasted report, verify the commits are in current `main`, inspect
the implementation and recorded evidence, then correct this ledger if needed.
Retain previous attempt reports. A source revert also updates phase status and
invalidates dependent results; keep completed-looking reports as historical
records, not current proof.

## Coordination log

- November 6, 2026: user authorized copyable, report-chained implementation goals,
  tracked progress, atomic commits on main, and README edits limited to accurate
  additions or corrections of obvious outdated/wrong content. Prepared the
  workflow and 20 phase prompts. No implementation goal has been started here.
