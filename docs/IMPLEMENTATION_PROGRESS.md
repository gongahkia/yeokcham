# Implementation progress

Updated November 6, 2026. This is the shared implementation ledger. Follow
[Implementation workflow](IMPLEMENTATION_WORKFLOW.md) for execution, reports,
verification, commits, and rollback. Each new agent reads and updates this file.

## Current state

- Design baseline: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`.
- Branch: `main`; one implementation writer at a time.
- Active implementation phase: G01 (`g01-local-baseline-2026-11-06`).
- Next ready phase: none while G01 is in progress.
- Completed phases in this chain: **0 / 20**.
- G01 environment setup and measurement harness work has started; product runtime
  remains unchanged. Existing V1/undo functionality predates this chain.
- Current blocker: none. The full G01 profile is running; its restoration checks
  are slow on this WSL2 filesystem. Later native OS, resource, and human evidence
  gates remain pending; they are not presumed available or passed.

Update the active phase/session label and starting commit when work starts.
Update meaningful checkpoints while working, and reconcile all fields at closeout.
A completion report without supporting commits/tests does not complete a phase.

## Phase ledger

The default chain is sequential. Every phase requires the previous phase's
accepted report and implementation commits; domain dependencies are in the goal
files and TC08. Do not skip a failed phase or execute later prompts concurrently.

| Phase / copyable prompt | Prerequisite | Status | Implementation commits / latest report | Remaining |
| --- | --- | --- | --- | --- |
| [G01: Build the measurement harness and capture the local baseline](implementation/goals/G01-baseline.md) | Verified design baseline | in_progress | `5761fd69ff6856324a3ae265a58c8e3e8c785247`, `b1e78a92c6d095e30d78d1355af6b5fbcc215c42`, `48fd99a7a765dd12cb0ddcf54c80501b8fff2f28`; [attempt 01](implementation/reports/G01-attempt-01.md) | Live two-tier baseline, compact results, acceptance audit; next G01 |
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

- G01 session: `g01-local-baseline-2026-11-06`; starting commit
  `0f162112ecdad0bedf98997f9b2b5b3a58457e5d`, clean `main`.
- Verified `d03ac1e095af7c896eede2334c5a1f5fc50c4e74` is an ancestor;
  G01 has no predecessor implementation report. Other observed agent processes
  work in another project; no overlapping writer observed.
- Read G01, workflow, TC08, benchmark design, Makefile, CI, and install/undo docs.
  The inherited Next.js instruction has no applicable package: this is OCaml.
- Host is Fedora 44 under WSL2, not a native-platform acceptance machine.
  No opam switch existed; documented local setup and test-tool installation started.
- Generator determinism, exact byte/count and corruption/attribute checks pass
  (4 Python tests); source/monorepo/asset layouts and large-file controls implemented.
- `make setup` completed: OCaml 5.5.0, Dune 3.24.2, ocamlformat 0.29.0.
  First build passed. Early lint ran before formatter installation and failed;
  formatter setup completed and the new Dune stanza formatting was corrected.
- Initial test run found an environment-only OpenSSL path issue: Fedora has
  Homebrew OpenSSL, while tests default to `/usr/bin/openssl`. Re-run with the
  documented `YEOKCHAM_V1_TEST_OPENSSL` override; disposable SoftHSM is configured.
- Real CLI runner checks passed (4 Python tests, including linear/branching
  restores and intentional corruption rejection); pinned source export built and
  every tracked exported source file matches the pinned revision.
- Fixture implementation committed as `5761fd6`; build, lint and four fixture
  tests passed. Runner/summarizer tests now total eight passing checks.
- Pinned export `make ci` passed lint/runtime tests, then failed at `docs-check`
  because that pre-existing checker requires Git metadata absent from an archive.
  This is recorded, not suppressed; final full CI will run on the actual checkout.
- Runner/summarizer committed as `b1e78a9`. `make ci` passed on that commit
  with the OpenSSL override and configured SoftHSM token; no skipped test was
  counted as passed. Pinned runtime tests: 289 cases in 47 successful suites.
- Pinned-export smoke completed: 8-KiB/8-file, five-node branching history,
  executable/symlink attributes, all four operations, exact restores.
- Full G01 profile is running from the pinned export: 10-MiB/1,000-file and
  100-MiB/10,000-file, 10 nodes, 5 cold / 3 excluded warmups / 30 warm samples
  per operation. Process/session evidence and full logs remain outside Git;
  `/home/gongahkia/.cache/yeokcham-g01/source-local/summary.json` is the durable
  result, `source-local.log` the progress log. Do not restart a live run.
- Next: finish the selected measurements, compact evidence, audit and handoff.
- Large fixtures and full logs: `/home/gongahkia/.cache/yeokcham-g01`, outside Git.

## Evidence and coverage gates

These gates prevent a completed implementation stage from implying validation
that has not happened. Record exact tested revisions and evidence links. If later
runtime changes affect a gate, mark its evidence stale and revalidate it. A
subsequent documentation-only commit need not invalidate runtime evidence; record
that relationship explicitly.

| Gate | Owner phase(s) | State | Required evidence |
| --- | --- | --- | --- |
| Local existing-runtime baseline and reproducible runner | G01 | in_progress | [Environment](implementation/results/G01-environment.json) and [export smoke](implementation/results/G01-export-smoke.json) verified; selected two-tier run is live, not yet accepted |
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

- November 6, 2026, G01 attempt 01: committed fixture/runner/evidence; main CI and
  pinned export smoke passed. Full selected profile is running in exec session
  `29807`, runner PID `107969` at checkpoint. Revalidate the live process before
  continuing; never infer liveness from this ledger alone. G01 remains active,
  G02 remains pending; no phase-completion claim.
