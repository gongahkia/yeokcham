# Implementation progress

Updated November 14, 2026. This is the shared implementation ledger. Follow
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
- Current blocker: none. On November 12 the old session `20722` was missing and
  PID `118787` was absent. The interrupted v2 profile retained 132 verified records;
  checked resumption is live in session `79434`, PID `154851` at launch, after
  revalidating all ten retained checkpoints and preserving the accepted prefix.
  The 10-MiB tier passed all 140 measured samples and 12 excluded warmups;
  the 100-MiB tier completed capture/no-op/small-edit and the cold undo/warmup groups.
  Ten warm undo/restore samples remain. The committed
  [measurement checkpoint](implementation/results/G01-measurement-checkpoint.json)
  preserves 270 measured records and all 24 warmups at its observation time.
  Later native OS, resource, and human
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
| [G01: Build the measurement harness and capture the local baseline](implementation/goals/G01-baseline.md) | Verified design baseline | in_progress | `5761fd69ff6856324a3ae265a58c8e3e8c785247`, `b1e78a92c6d095e30d78d1355af6b5fbcc215c42`, `48fd99a7a765dd12cb0ddcf54c80501b8fff2f28`, `547bef4cd33c44d1068159a305b230d5ffd22b41`, `c14443cca934b3666c439d4448925ed8b06addc8`, `b0fa2492957a1e1c801833b12fe6aac7f95dd0a9`, `e5beeefcff25590cb4cf50ab02c7e2d4428a25d6`, `950a450f080f8f5a62e7e460910099dd157e8841`, `e3ccae824c1aa03f4b6f984006e69033cefd95d1`; [attempt 06](implementation/reports/G01-attempt-06.md) | 100-MiB undo/restore, compact full results, acceptance audit; next G01 |
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
- November 7, 00:07 SGT checkpoint: original session `29807` / PID `107969`
  confirmed live after repeated polls. The 10-MiB initial-capture case has accepted
  five cold samples, three excluded warmups and two warm samples, with no recorded
  failures. Full counts and the 100-MiB tier remain outstanding; this is a verified
  wait, not a blocked condition. Snapshot: external `checkpoints/attempt-02.json`.
- November 7 harness audit: an exact destination restore took 4.963 seconds;
  redundant untimed in-place validation took minutes and added navigation proofs
  to the prepared history. Replaced only that harness verification with captured
  checkpoint restoration to an empty destination; measured undo remains unchanged.
  Corrected storage allocation to include directory blocks and tightened the seed
  check. Run/summary schema v2 records the verifier and its duration.
- Original session `29807` was deliberately terminated, confirmed exit 143, after
  preserving all 13 accepted records and interruption context in external
  `preliminary-cancellation.json`. No runtime failure was hidden. Do not poll or
  restart that old handle; v2 will use a fresh full profile with no mixed timings.
- Harness v2 committed as `547bef4`; `make build`, `make lint`, `make ci`, ten
  focused tests and the pinned-export v2 smoke passed. New full profile is live
  in session `20722` / PID `118787`, output `source-local-v2` under the external
  artifact root. Original/new 10-MiB manifests are byte-identical, including
  tree SHA-256 `b6625b95d9d0e47d090658e1ac01f1660112dfa65aaa03f4ca4b3ee77b3f8160`.
- Next: finish both full v2 tiers, compact evidence, audit and handoff. Earlier
  live-run checkpoints above are historical; the old process exited 143.
- November 7, 00:59:43 SGT checkpoint: v2 session `20722` / PID `118787`
  confirmed live after 42m35s. Accepted 69 measured samples and six warmups:
  10-MiB initial capture 5 cold / 3 warmup / 30 warm; no-op 5 / 3 / 29.
  No failures; small edit, undo/restore and 100 MiB remain. External snapshot
  `checkpoints/attempt-03.json` and its SHA-256 are recorded in attempt 03.
- November 12 interruption audit: old process absent and session unknown; no
  benchmark process observed. The 10-MiB tier retained all capture/no-op/small-edit
  groups plus 5 cold / 3 warmup / 10 warm undo/restore records, without failures.
  Twenty warm undo records and the entire 100-MiB tier remain. Current machine,
  kernel, toolchain and filesystem identities match the original; free resources
  differ. Implementing checked resumption with preserved input snapshots.
- Resume checks: build/lint/CI and twelve focused tests passed, including real
  linear/branching interruption recovery, preserved samples, lock rejection and
  incompatible binary/machine/settings rejection. A local probe confirmed wait4
  RSS includes inherited launcher memory; label it an upper bound and retain
  isolated executable-memory comparisons under G19.
- Resumption committed as `b0fa249`; live session `79434`, PID `154851` at launch.
  Original 132 records are unchanged, all ten retained checkpoints reverified,
  and the in-flight sample was preserved separately. Exact commands, snapshot
  hashes, test log hashes and RSS probe are in
  [resumption evidence](implementation/results/G01-resumption.json).
  New progress log: external `source-local-v2-resume.log`; result directory is
  still `source-local-v2`. Revalidate liveness before further continuation.
- November 12: 10-MiB tier passed all 152 records (140 measured, 12 warmups).
  Independent audit checked exact bytes/count, manifest/tree hashes, all expected
  unique sample indices, finite metrics, unchanged original 132-record prefix and
  recomputed median/p95 summaries. Raw case SHA-256:
  `c437e7ed3233ed696e66c5bac2ebc67d7ef15df130941b9bb5b3d85daca7b874`.
  The same process moved to the 100-MiB tier; G01 remains incomplete.
- November 13, 00:22:38 SGT: session `79434` / PID `154851` confirmed live after
  53m55s. All ten 100-MiB checkpoints verified; first cold capture accepted.
  Total 141 measured records and 12 warmups accepted; no failures. Immutable
  external checkpoint `checkpoints/attempt-04.json`, SHA-256
  `c27c2b428bcf28855a1d7b7c3c342ecea76a9c97caa7a49ced4608f8b13ddc56`.
- November 13, 22:57:10 SGT: same process confirmed live after 2h44m01s.
  100-MiB capture passed 5 cold / 3 warmup / 30 warm samples; no-op child is
  executing. Overall 175 measured samples and 15 warmups accepted, no failures.
  Independent capture audit checked bytes/count, hashes, indices and metrics.
  External checkpoint `checkpoints/attempt-05.json`, SHA-256
  `8a097192384fd9dcf120277ad822c3c593c463a4d6e224b4ff24dffaa73e7fff`.
- November 13, 23:34:49 SGT: preserved all 207 accepted records in the committed
  59,942-byte measurement checkpoint, explicitly `in_progress`; it contains
  189 measured records and 18 excluded warmups. An independent reconstruction
  matched every raw sample field and verified hashes of the preserved external
  input snapshots. Checkpoint SHA-256:
  `aa194fea7ae47c0d9733d827b6814ef8ba4f5f985492241e28fc951cd5c54fbc`.
  The harness guide now contains exact checkpoint-export and read-before-resume
  instructions. Preserve the external fixture/history/signers; accepted samples
  must be skipped by checked resumption, not rerun or replaced.
- November 14, 00:34:13 SGT: the same process is live after 4h21m03s.
  100-MiB no-op completed all 38 records; capture/no-op are complete and small-edit
  is next. Refreshed checkpoint preserves all 228 records (210 measured and
  18 warmups) without changing the earlier 207 records. All raw fields, input
  hashes and the expected latest-node restored hash passed independent audit.
  Committed checkpoint SHA-256:
  `a67a6ec0fd3ca5aafefee01f6240e6d7273ffdf2245123d22bc885c8fffca242`.
  External audit `checkpoints/attempt-06.json`, SHA-256
  `b242e37b44c1cdb6cef1b75704689cc03caa07eab59c1c72778370c9424dc854`.
- November 14, 02:02:49 SGT: the same process is live after 5h47m57s.
  100-MiB small-edit completed all 5 cold / 3 excluded warmups / 30 warm samples;
  undo/restore is the final operation. The 72,664-byte checkpoint preserves all
  266 accepted records (245 measured and 21 warmups), including the earlier
  228-record prefix unchanged. Its SHA-256 is
  `c84ea3184da5d0867eb93a022a9b422ebe0249642c769b48532033b25154e2cb`.
  Independent audit matched every raw field/command, input hash, expected restored
  tree and recomputed statistic; the original 132 records also remain identical.
  Small-edit cold median/range: 117.061 / 107.465–146.031 seconds; warm
  median/p95: 71.043 / 108.231 seconds. These remain partial-profile results.
  External inputs: `checkpoints/documentation-1794592969254993262`; audit:
  `checkpoints/small-edit-complete-audit-1794592969254993262.json`, SHA-256
  `7aa7f8f085705baa279f6ae41d5b0a3df3521efeb23854aa549bdbf41e3a6517`.
  Reproducible independent diagnostic: external `audit_measurements.py`, SHA-256
  `0ed254515e0f06d3aa9b15db1a4b472ae2d5a4b079eb99286719dd926de56524`;
  invoke it with the committed checkpoint and optional previous checkpoint paths.
  At this observation, 35 measured undo records and three warmups remain.
- November 14, 03:15:37 SGT: the same process is live after 7h00m45s.
  All five cold undo samples and all three excluded warmups passed; thirty warm
  undo samples remain. The 74,753-byte checkpoint preserves 274 records
  (250 measured and all 24 warmups), retaining the earlier 266-record prefix
  unchanged. Checkpoint SHA-256:
  `bf33bce3570e762d3291e7d5923213183aaacd547ca12ca2be4b4e069bd8f0ee`.
  Independent audit matched all raw metrics/commands, input hashes, expected
  restored trees and recomputed statistics. Cold undo median/range:
  480.815 / 423.613–724.747 seconds; full warm statistics are still pending.
  Inputs: external `checkpoints/documentation-1794597337635867450`; audit:
  `checkpoints/undo-warm-start-audit-1794597337635867450.json`, SHA-256
  `37df515102db381fbf17509caba5ed4ed046ed3f736f2decfc5005209a62e627`.
  The preceding small-edit checkpoint/ledger update is committed as
  `5a69bb5b0a557f85b7f472be6af8fc7e16dc4163`. No runtime or harness code changed.
- November 14, 04:30:20 SGT: the same process is live after 8h15m27s.
  Ten of thirty measured warm undo samples passed; twenty remain, with no failures.
  The 77,015-byte checkpoint preserves 284 accepted records (260 measured and
  24 warmups), including the earlier 274-record prefix unchanged. SHA-256:
  `45fbaabe06adf68753e43907381bb8d7ae8b04f304851ee5698b9712950bf786`.
  Independent audit matched raw fields/commands, input hashes, restored-tree
  identities and statistics. Inputs:
  `checkpoints/documentation-1794601820212616890`; audit:
  `checkpoints/undo-warm-10-audit-1794601820212616890.json`, SHA-256
  `8ef16dd6cf4e1c7a1510a846b130a04a1628d0c3efe7a048eb0690a1c7622cb6`.
  The preceding cold-undo/warmup checkpoint is committed as
  `35a95f7f0ce0df5c5400e666eeae02b876e280f6`; runtime/harness code remains unchanged.
- November 14, 05:44:44 SGT: the same process is live after 9h29m51s.
  Twenty of thirty measured warm undo samples passed; ten remain, with no failures.
  The 79,121-byte checkpoint preserves 294 records (270 measured and 24 warmups),
  including the earlier 284-record prefix unchanged. Checkpoint SHA-256:
  `3a728403a717dd5afd902559db06ebf211d8e963f2cea30d83557593583dc9b6`.
  Independent audit matched all raw fields/commands, input hashes, restored-tree
  identities and recomputed statistics. Inputs:
  `checkpoints/documentation-1794606284073373022`; audit:
  `checkpoints/undo-warm-20-audit-1794606284073373022.json`, SHA-256
  `6d87482b90bd503753d7e5b5000cc047f13a674216910ace34edaf9df14c5e0d`.
  The preceding ten-warm-sample checkpoint is committed as
  `1b69a3ac3f20b1e10158d6626703a09ed6a22e17`; runtime/harness code is unchanged.
- Large fixtures and full logs: `/home/gongahkia/.cache/yeokcham-g01`, outside Git.

## Evidence and coverage gates

These gates prevent a completed implementation stage from implying validation
that has not happened. Record exact tested revisions and evidence links. If later
runtime changes affect a gate, mark its evidence stale and revalidate it. A
subsequent documentation-only commit need not invalidate runtime evidence; record
that relationship explicitly.

| Gate | Owner phase(s) | State | Required evidence |
| --- | --- | --- | --- |
| Local existing-runtime baseline and reproducible runner | G01 | in_progress | [Environment](implementation/results/G01-environment.json), [v2 correction evidence](implementation/results/G01-harness-v2.json), [v2 export smoke](implementation/results/G01-export-smoke-v2.json), and [resumption checks](implementation/results/G01-resumption.json) verified; full v2 profile is live, not yet accepted; RSS is a launcher-inclusive upper bound |
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

- November 7, 2026, G01 attempt 02: revalidated original live process and ancestor
  commits; observed first accepted baseline samples. Saved a durable external
  observation and this continuation report. No runtime/harness changes or new
  implementation phase; G01 stays active while the full profile runs.

- November 7, 2026, G01 attempt 03: corrected untimed verification and allocation
  accounting, preserved the deliberately cancelled v1 evidence, passed corrected
  build/lint/CI and ten focused checks, and started/observed the full v2 profile.
  G01 remains active; its incomplete measurements are not a completion claim.

- Future workflow preference from the user: after the current run and pasted
  handoff, use coordinator-managed agents in separate branches/worktrees, deduplicate
  work, resolve conflicts, test integration and synchronize local/remote main.
  Reconcile the workflow before that subsequent work. Current G01 stays within its
  original phase boundary; later work still needs dependency ordering and evidence.

- November 13, 2026: user requested durable documentation to avoid repeating the
  long measurement work. Keep the versioned partial checkpoint current at operation
  boundaries/handoffs, retain its external inputs, and begin continuation by
  reading the ledger/latest report/checkpoint and verifying actual process state.
