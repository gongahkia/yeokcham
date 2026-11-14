# Implementation progress

Updated November 15, 2026. This is the shared implementation ledger. Follow
[Implementation workflow](IMPLEMENTATION_WORKFLOW.md) for execution, reports,
verification, commits, and rollback. Each new agent reads and updates this file.

## Current state

- Design baseline: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`.
- Branch: `main`; one implementation writer at a time.
- Active implementation slice: P2 local workflow, session `p2-local-2026-11-14`,
  starting clean main `56eb13d271421720299d7e3f0dcd589d80b4d153`.
  P1 core-workflow foundation is complete;
  continuation `p1-core-resume-2026-11-14` started on clean main
  `06f526d9f6f09cd06bd3b57a7a348f64ea17817a` and verified implementation
  `06b662a8bab5c783117e5fcf45e36b7d942cfc64`. See the
  [P1 report](implementation/reports/P01-attempt-01.md) and
  [acceptance receipt](implementation/results/P01-acceptance.json).
- Current pilot slice: P2 is in progress; P3/P4 are pending. The current priority remains the [complete pilot](PILOT_PLAN.md).
  P2 was separately invoked after P1; no P3/P4 work is authorized.
- Original G02 has partial coverage through P1, with its full remainder below.
  It is not complete and does not make full G03 ready.
- Completed full-design phases: **1 / 20** (G01). Completed pilot slices:
  P0 evaluation and P1 foundation. Existing V1/undo predates this chain;
  P1 adds pure records/validation and no new ordinary CLI workflow.
- Current blocker: none. Session `79434` exited 0 after both tiers passed all
  280 measured records and 24 excluded warmups. The
  [complete baseline and budgets](implementation/results/G01-baseline.md) and
  [lossless full summary](implementation/results/G01-baseline.json) preserve the
  accepted measurements. The partial checkpoint is historical. Independent audit
  verified the complete schedule, raw metrics, restored identities, statistics,
  budgets, full pristine contents and unchanged accepted prefixes. Later native
  OS, resource and human evidence gates remain pending. The
  [G01 completion report](implementation/reports/G01-attempt-07.md) records the
  acceptance audit and next handoff; do not rerun accepted measurements.

Update the active phase/session label and starting commit when work starts.
Update meaningful checkpoints while working, and reconcile all fields at closeout.
A completion report without supporting commits/tests does not complete a phase.

## Phase ledger

The original full-design chain below is sequential. Every full phase requires
its predecessor's accepted report and implementation commits; domain dependencies
are in the goal files and TC08. The November 14 core-workflow pilot uses separately
scoped slices before completing the whole design. Track each slice against the
original phase criteria; a partial slice does not complete a G-phase or bypass
its actual schema, authority, integrity or recovery dependencies. Do not execute
later full-phase prompts as a shortcut around an unfinished predecessor.

| Phase / copyable prompt | Prerequisite | Status | Implementation commits / latest report | Remaining |
| --- | --- | --- | --- | --- |
| [G01: Build the measurement harness and capture the local baseline](implementation/goals/G01-baseline.md) | Verified design baseline | complete | `5761fd69ff6856324a3ae265a58c8e3e8c785247`, `b1e78a92c6d095e30d78d1355af6b5fbcc215c42`, `48fd99a7a765dd12cb0ddcf54c80501b8fff2f28`, `547bef4cd33c44d1068159a305b230d5ffd22b41`, `c14443cca934b3666c439d4448925ed8b06addc8`, `b0fa2492957a1e1c801833b12fe6aac7f95dd0a9`, `e5beeefcff25590cb4cf50ab02c7e2d4428a25d6`, `950a450f080f8f5a62e7e460910099dd157e8841`, `e3ccae824c1aa03f4b6f984006e69033cefd95d1`, `5a69bb5b0a557f85b7f472be6af8fc7e16dc4163`, `35a95f7f0ce0df5c5400e666eeae02b876e280f6`, `1b69a3ac3f20b1e10158d6626703a09ed6a22e17`, `e385b9ce42fc0c708e0af95d52af92a33cb6ef43`, `7646362d80929e4f9cdccce0b90ac86beaa1a4a8`, `f924e0f480b4b5b7040b2ad3572790f171a8d745`; [attempt 07](implementation/reports/G01-attempt-07.md) | None for G01; next G02 |
| [G02: Implement canonical records, identities, and shared interfaces](implementation/goals/G02-canonical-records.md) | G01 | in_progress | Partial via P1: `0c1f910dcd8a4f4a7d10db81a199d83fa9774043`, `06f526d9f6f09cd06bd3b57a7a348f64ea17817a`, `51c374f499372349b235e68b32e7bf3e748d2718`, `f900fbc3432e1d7134a547eda4f2ec7366d6c991`, `06b662a8bab5c783117e5fcf45e36b7d942cfc64`; [P1 report](implementation/reports/P01-attempt-01.md) | Review/request/event/policy and account/settings/archive records; request/member identity and proof; full policy/review/archive/journal and crypto interfaces; corresponding vectors/tests. P1 does not complete G02. |
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

## Pilot slice ledger

| Slice | State | Evidence / remaining work |
| --- | --- | --- |
| P0 evaluation | complete | [Assessment](PILOT_PLAN.md), [receipt](implementation/results/PILOT-workflow-assessment.json); tiny WSL/test-signer walkthrough only |
| P1 core foundation | complete | [Interfaces](implementation/INTERFACES.md), [report](implementation/reports/P01-attempt-01.md), [acceptance](implementation/results/P01-acceptance.json); no P1 criteria remaining |
| P2 local work | in_progress | [Scoped task](implementation/goals/P02-local-workflow.md); native ignore matching/explanation and capture consistency landed; durable workspace/history identity foundation landed; authenticated branch list/create and private init landed; switch, local inspection CLI and safe recovery remain; P2 incomplete |
| P3 shared loop | pending | Clone/selected sharing/composition/journaled integration/conflicts; unstarted |
| P4 harden/handoff | pending | Representative/native/human and fault evidence; unstarted |

## Current-phase checkpoints

- P2 native-ignore checkpoint: root/nested byte-oriented glob/negation/escape
  matching, explicit parent re-inclusion and mandatory metadata exclusions now
  drive the real scanner. `ignore explain` supplies text/JSON domain results,
  winning source/line and explicit invalid-config/unavailable outcomes. Five
  module cases and four fresh-process CLI cases passed; existing snapshot
  materialization and 44 local-service cases passed. Build/lint and full `make ci`
  passed on this implementation tree with valid Dune cache reuse. The first CI
  found missing `help ignore`; the routing was corrected and its focused test
  and full CI passed. Capture-race/no-follow hardening, durable identities and
  branches, ordinary status/history/diff and preservation-aware recovery remain
  outstanding. P2 is not complete; no original full phase is closed. Logs are
  external under `/home/gongahkia/.cache/yeokcham-p2-20261114/`.


- P2 capture consistency checkpoint, November 15: descriptor-relative no-follow
  capture and final metadata/entry rechecks are implemented, with three bounded
  retries and bounded streaming reads. Seven filesystem cases exercise same-size
  writes, continuous instability, entry changes, late rule changes, symlink
  swaps, root replacement and mixed-file fidelity. Focused capture (7), ignore
  (5), materialization (3) and local-service (44) cases passed. `make build`,
  `make lint` and `make ci` exited 0 on the checkpoint tree, with valid Dune
  cache reuse; logs are `*-capture-final.log` in the session cache. Main advanced externally to
  `6f224e356219febfdad3fe077d67b2d67ead4f05` while work was active; that commit
  contains the native helper/Dune changes from this session and is preserved.
  No unrelated paths changed. P2 remains incomplete.

- P2 start: clean main and all P1 prerequisite ancestry verified; original
  G01/P0 evidence hashes unchanged. Existing local toolchain/SoftHSM environment
  is available. Strategy: native ignore and scan consistency, then durable
  local/core state and branch selection, then shared safe materialization and
  CLI journeys. Existing V1 root-wide destructive replacement is insufficient
  for P2 external-edit/ignored-file protection and will be hardened before the
  new selection commands rely on it. No benchmark rerun or storage replacement
  is planned without a measured need.


- P1 closeout, November 14: codecs, independent Python/OpenSSL vectors,
  identity-collision rejection and historical/current-admission trust boundaries
  landed in three buildable commits. `make build`, `make lint` and `make ci`
  passed on `06b662a`; CI executed 50 OCaml suites / 307 cases and 12 Python
  checks, with no reported skips and a configured disposable SoftHSM token.
  The three focused core suites total 18 cases and 2,200 property trials.
  Vector regeneration is byte-identical. Original G01/P0 evidence hashes match.
  Toolchain: OCaml 5.5.0, Dune 3.25.0, ocamlformat 0.29.0 on native Arch Linux.
  This is module/CI evidence, not full native product/service or human acceptance.
  Full G02 remains partial; this P1 checkpoint made P2 next eligible (P2
  has since started as recorded above). The final
  report/ledger is a separate documentation-only commit.

- P1 continuation, November 14: session `p1-core-resume-2026-11-14` starts
  on clean main `06f526d9f6f09cd06bd3b57a7a348f64ea17817a`. Verified the
  design, G01 handoff and pilot-assessment ancestry. Existing model/identity
  implementation and tests are retained for audit; the core codec has only an
  interface and is not complete. This native Arch Linux host initially has no
  opam/compiler and passwordless sudo is unavailable. Build tools are being
  established under the external task cache and a repository-local switch.
  Historical G01 external artifacts are absent here; committed measurements
  remain unchanged and will not be rerun. One writer owns model/record/trust.

- P1, November 14: verified clean main and ancestry of the pilot-plan and G01
  handoff commits. Pilot receipt SHA-256 is
  `d5ff0fd335fb2bd48b986a1f2c5289944d08ab91b974f1c616b7b13b545699df`;
  accepted G01 result/acceptance hashes match. Read the pilot task, workflow,
  progress, report template, TC01/TC02, TC03 identity boundaries, TC06 and TC08.
  The inherited Next.js rule has no applicable package in this OCaml checkout.
  One writer owns the common model/record/trust interfaces and registry.

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
- November 14, 06:58:12 SGT: the full v2 profile passed; session `79434` exited 0.
  Both tiers contain all 152 records each: 280 measured and 24 excluded warmups.
  The normal completed-run summarizer produced the 80,522-byte full summary,
  SHA-256 `03e105c1c9ad56178f20b67bc1132c1a5795015d4346dce6d3c9b5f4115ed88b`.
  Raw summary SHA-256:
  `91952fc8cb14e77f97a46f181b56755e92365c5271931878a408e358c106caea`.
  Independent full audit verified every raw field/command, unique scheduled
  index, allocation sum, expected tree hash, statistic/budget and pristine path;
  the 294-record checkpoint and original 132-record prefix are unchanged.
  Data audit: external `completion-measurement-audit.json`, SHA-256
  `f40ccffb4aa00ea953eca8ac41646c0a74f1382ab98a46ce80e5abd537d0d441`.
  Full raw snapshot: external `checkpoints/final-1794610728850154352`;
  `completion-raw-snapshot.json` records all five hashes and terminal exit.
  Final provenance audit reverified pinned source/executable/generator/runner,
  identical measurement AST, both machine identities and retained storage against
  `du -s -B1`. The readable baseline records exact investigation budgets and limits.
  The preceding twenty-warm-sample checkpoint is committed as
  `e385b9ce42fc0c708e0af95d52af92a33cb6ef43`. Phase checks/report still remain.
- November 14, 07:05:24 SGT: `make build`, `make lint` and `make ci` exited 0
  on clean `7646362d80929e4f9cdccce0b90ac86beaa1a4a8`, which commits the full
  baseline. Completion CI reused Dune's valid cached runtime/focused-test results;
  docs and workflow shell checks ran. No cached target is presented as freshly run.
  The twelve focused checks remain valid: tools/test sources are unchanged from
  `b0fa249`; runtime/README/Makefile/CI remain unchanged from the pinned revision.
  [Acceptance receipt](implementation/results/G01-acceptance.json), SHA-256
  `a83992829ec0900fbf8ee695f49a0ee4f65ce25b71a371590543779a66a55f72`, records
  all five passed criteria, actual exits, audits, snapshots, ancestry and scope.
  External completion build/lint/CI logs have SHA-256:
  `e90e1e244d9512c60ffb9a48589ca172a1059a79f19dbb267ecfa379fabcb5ff`,
  `2a19a33e28c32c5dea7a816aa16891c07e006878ee11e0c819c7aee6d260008d`,
  `4b875a04737d8700a4f8df61dd0c52c7fa16abc88e685dc13303b31ac4c4dc0f`.
  A separate report/tracker closeout remains; later coverage gates stay pending.
- November 14 closeout: [attempt 07](implementation/reports/G01-attempt-07.md)
  audits all five criteria as passed. Final acceptance evidence is committed as
  `f924e0f480b4b5b7040b2ad3572790f171a8d745`; it and the handoff contain only
  documentation/evidence after tested `7646362`, so code validation remains valid.
  G01 and its local baseline gate are complete; G02 is ready and unstarted.
  All other coverage gates remain pending. Preserve the complete metrics and
  external retained artifacts. The G01 runner exited; no later phase has started.
- Large fixtures and full logs: `/home/gongahkia/.cache/yeokcham-g01`, outside Git.

## Evidence and coverage gates

These gates prevent a completed implementation stage from implying validation
that has not happened. Record exact tested revisions and evidence links. If later
runtime changes affect a gate, mark its evidence stale and revalidate it. A
subsequent documentation-only commit need not invalidate runtime evidence; record
that relationship explicitly.

| Gate | Owner phase(s) | State | Required evidence |
| --- | --- | --- | --- |
| Local existing-runtime baseline and reproducible runner | G01 | complete | [Environment](implementation/results/G01-environment.json), [v2 correction evidence](implementation/results/G01-harness-v2.json), [v2 export smoke](implementation/results/G01-export-smoke-v2.json), and [resumption checks](implementation/results/G01-resumption.json) verified; [full local measurements](implementation/results/G01-baseline.md) passed and were independently audited; [completion checks](implementation/results/G01-acceptance.json) and [report](implementation/reports/G01-attempt-07.md) passed; later gates remain pending; RSS is a launcher-inclusive upper bound |
| Canonical records, causal policy, deterministic composition | G02-G04 | pending | P1 core records/identities/interfaces and trust tests passed ([report](implementation/reports/P01-attempt-01.md)); full G02 remainder, policy and composition evidence remain outstanding |
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

- November 14, 2026: user prioritized a complete everyday VCS workflow with
  essential primitives first and optional features later. The interrupted G02
  request did not start implementation. Completed P0: built current main,
  exercised 60 CLI invocations plus a foreground watcher in disposable projects,
  and passed 17 explicit walkthrough checks. Local recovery works on the tiny
  mixed fixture; ordinary clone/branch/switch/diff/integration remain gaps.
  Offline package receipt works, but activation/update refuse without a verified
  imported projection basis. Native init failed on this WSL host; subsequent
  mutations used disposable test signing, so native custody and real-user gates
  remain open. See [pilot scope, findings and next slices](PILOT_PLAN.md) and the
  [compact receipt](implementation/results/PILOT-workflow-assessment.json).
  G01 measurements are unchanged; G02 and all pilot implementation are unstarted.

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

- P2 durable-history checkpoint, November 15: new
  workspaces persist a generated P1 workspace ID, next sequence and history in
  the existing sole state-root wrapper. Appends use P1 allocation; namespace
  replacement, history collisions/deletion and stale roots refuse. New tests
  cover fresh writer processes, identical retries, exhaustion, actual crashes
  before/after root CAS and 150 randomized save/navigation/reopen trials. Seven
  new cases and existing undo (14), store (6), local-service (44) and GC (11)
  cases passed. `make build`, `make lint` and `make ci` exited 0; valid Dune
  cache reuse and full logs are recorded in `*-identity*.log` in the session
  cache. The initial store golden assertion was updated to inspect the preserved
  inner signed payload after initialization began wrapping history. The
  existing signed collaboration golden payload is retained inside the wrapper.
  Named authenticated branches, generated CLI names, readable local inspection
  and safe preservation-aware replacement remain outstanding. G06 paging/index
  replacement is not claimed. P2 remains in progress.

- P2 causal-head checkpoint, November 15: the P1 core
  pool now exposes causal branch event/accepted head sets and concurrent names.
  Three authenticated-record tests cover rename inheritance, six receipt-order
  permutations, explicit target reconciliation and equal-content branch identity.
  Focused tests, `make build`, `make lint` and `make ci` exited 0 on this tree
  with valid Dune cache reuse; logs are `*-branch-heads*.log` in the session
  cache. This is the minimum pure projection prerequisite; durable branch state, empty
  accepted genesis checks and actual branch/switch CLI operations remain to do.
  No P3 exchange/composition or full G03 completion is claimed.

- P2 authenticated-local-state checkpoint, November 15: `Store.Local` now creates real signed empty genesis/branch records
  and named fork metadata in the existing object store. Version-2 state wrappers
  publish this with workspace/history and selection under the same head CAS.
  Seven adapter cases pass, including fresh-process metadata selection,
  duplicate/collision/entropy refusal, signature/mapping/acceptance validation,
  late-record admission and compaction/GC protection of unselected private work.
  An integration test exposed the existing generic store's domain-prefixed
  physical hash versus P1's complete-envelope record hash. The root now retains
  and verifies both references; neither identity contract was changed. This is
  a store adapter checkpoint. Focused local-core (7), history identity (7),
  store (6), undo (14), GC (11) and local-service (44) cases passed, along with
  `make build`, `make lint` and `make ci` (valid Dune cache reuse). Exact logs
  are `*-local-core*.log` in the session cache. This is not usable CLI
  branch/switch completion. CLI init
  still uses the old path pending service wiring; safe replacement and ordinary
  status/history/diff journeys remain outstanding. No P3 work is claimed.

- P2 private-init/branch CLI checkpoint, November 15:
  CLI init now captures files privately against signed empty accepted genesis
  and generates IDs/defaults. Branch list/create are connected to real service
  and state operations, with text and JSON data. Seven new fresh-process Python
  cases pass. Two existing V1 proposal fixtures relied on implicit acceptance
  at init; they now establish their baseline through explicit existing V1
  share/deliver commands, retaining all substantive assertions. All 28 existing
  CLI cases pass, as do the 44 existing local-service cases. `make build`,
  `make lint` and `make ci` exited 0 with valid Dune cache reuse; exact logs
  are `*-local-cli*.log` and `*-local-branch-cli*.log` in the session cache.
  Switch, preservation-aware mutation/recovery and useful local
  status/history/diff still remain; P2 is incomplete. Native credential/service
  acceptance is not claimed by the disposable test-signer journeys.

- P2 bounded-content checkpoint, November 15:
  `Content.verify` and `load_bounded` provide complete closure checks without
  whole-file display buffers. Manifest verification streams CDC boundaries and
  full-content hashing. Five cases cover exact bounds/no writes, forged chunk
  boundaries, incorrect full-content IDs, length mismatches and missing chunks.
  The local-service closure boundary reuses the verifier. This is a prerequisite
  for truthful large-file availability/status/diff, not completion of those CLI
  journeys or safe materialization. Focused content (5), capture (7), package
  and local-service (44) cases passed. `make build`, `make lint` and `make ci`
  exited 0 with valid Dune cache reuse; exact logs are
  `*-stream-inspection*.log` in the session cache.

- P2 local-inspection domain checkpoint, November 15:
  real status/history/exact comparison APIs now expose changed paths, workspace
  positions, alternates, branch references, truthful availability and bounded
  readable text hunks. Working observations respect the writer boundary and
  pending recovery; saved-only comparisons never scan the live tree. Six domain
  cases pass; five text cases include 400 randomized exact-byte reconstructions.
  Focused cases, `make build`, `make lint` and `make ci` exited 0 with valid
  Dune cache reuse; exact logs are `*-inspection*.log`/`*-text-diff*.log` in
  the session cache. Main advanced externally to
  `0e629dc7c38637fcb9cf99cd8ec168bfe2572700`, which committed this session's
  text-diff module/test groundwork; those changes and updated tracking refs were
  preserved. No agent push was performed. CLI rendering/structured outcomes, safe switch/recovery and final acceptance
  remain outstanding. No P3 composition/acceptance is implemented by display
  hunks. Authenticated branch metadata additionally refuses unnamespaced history.

- P2 inspection CLI checkpoint, November 15: status,
  history, exact diff, changes/save and native ignore/branch results now carry
  real schema-2 domain data/outcomes/actions through the existing codec. Nine
  fresh-process inspection and eight branch Python cases pass; four schema
  cases preserve legacy golden compatibility and reject contradictory outcomes.
  Existing CLI testing caught JSON save being emitted before hook warnings;
  domain output is now deferred until post-success observers finish, and all
  28 existing CLI cases pass. Byte-path display/JSON tests also caught and fixed
  invalid UTF-8 output. External main commit
  `0e539d8` contains this session's schema/test foundation and is preserved.
  Focused schema/legacy codec/28 existing CLI plus nine inspection and eight
  branch Python cases pass; `make build`, `make lint` and `make ci` exited 0
  with valid Dune cache reuse. Exact final logs are `*-inspection-cli-final.log`,
  `test-cli-inspection-final.log`, and `test-*-json-final.log` in the session
  cache. Switch, safe application/interruption recovery and final P2 audit remain
  outstanding. No P3 work is claimed.

P2 continuation checkpoint: added descriptor-relative exclusive moves/atomic
exchanges, private streaming output and complete capture read sets. Five native
filesystem tests passed on this Linux filesystem, including original-inode
retention and no-follow refusal. These are prerequisites; safe journaled
application and CLI branch switching remain incomplete. No macOS/Windows
execution evidence is claimed.

P2 safe-application engine checkpoint: thirteen focused cases passed, including
nine fork/exit points across actual mutations, forty generated mixed
content/type/mode transitions, ignored-directory obstruction/preservation,
missing contents, oversized destination names, replaced parents, corrupted
plans and external edits before/after interruption or through an open original
file descriptor. Integration into journals/navigation/switch is still pending.
The prior native-primitives checkpoint passed `make build`, `make lint`,
`make ci`; the first `make format` exited 1 while promoting formatter output.

P2 journal/navigation integration checkpoint: new restores carry schema-3
physical-plan digests and exact history-node scope. The service uses staged
application for in-place restore and undo/redo; legacy partial journals without
identity evidence refuse unexplained replacement. Complete safety captures and
reserved target nodes remain in the authoritative state root. Branch selection
cannot implicitly overwrite its stored cursor. Focused service (45), journal
(6), local-core (7) and engine (13) suites passed; one new service case exercises
22 fork exits at real filesystem/safety/journal/metadata boundaries for clean
and dirty undo. The two changed legacy test expectations reflect P2's required
ignored-file preservation and external-edit refusal. P2 remains incomplete:
actual switch/CLI preview and recovery outcomes, copy-out safety, lock/GC crash
audits, final acceptance evidence and the report remain outstanding.

Journal checkpoint verification: `make build`, `make lint` and final `make ci`
exited 0 (`*-journal-scope-final.log` in the P2 external log directory). Initial
CI exited 2 because one older undo test constructed a legacy journal then
expected unknown partial bytes to be overwritten. It now terminates a real
planned navigation after its actual atomic mutation and verifies exact-node
recovery. Engine coverage is now fourteen cases, including root-path replacement
at the mutation boundary. The initial formatter runs exited 1 while promoting
output; subsequent lint passed. Unaffected Dune results may be cached; no G01
measurements were rerun.

P2 branch-switch checkpoint: actual named selection now preserves source private
work and target history positions, including equal contents at distinct nodes.
The native branch suite passed fourteen cases (seven new switch cases), including
fresh-process selection, unavailable targets, ignored obstructions, nine real
process exits around switch mutation/metadata and edits after Materialized.
The CLI branch suite passed fifteen cases (seven new), covering mixed text/binary
journeys, JSON exit-3 confirmation data/actions, preview without staging/history
writes, explicit confirmation, interactive cancellation, stale preview refusal,
unknown names and ignored-file preservation/conflicts. Navigation preview now
uses the same read-only target/filesystem preflight. Target validation streams
large contents. P2 remains incomplete: complete undo/redo/restore confirmation
and JSON recovery journeys, copy-out safety, lock/GC interruption audits and
final acceptance report/receipt are still required. P3 remains unstarted.

Branch-switch checkpoint verification: `make build`, `make lint`, `make ci`
exited 0; logs are `build-branch-switch.log`, `lint-branch-switch.log` and
`ci-branch-switch.log` in the P2 external log directory. Formatter promotion
exited 1 on its first run; lint subsequently passed. Focused native branch and
CLI journeys passed before the broad checks; unaffected Dune results may be
cached. README and accepted G01 measurements remain unchanged.

P2 durable-metadata audit checkpoint: journals/proofs now use the generic store's
fsynced temporary/create-only publication instead of writing final records in
place. Their decoders/readers are bounded at 8192 bytes. Mutable-ref writers use
an advisory gate plus atomically published existing-format owner markers;
confirmed-dead owners recover on retry, while unknown/live ownership evidence
is preserved. Exceptions release locks. GC now shares the workspace writer lock
before retention/head locks, protecting captures before root publication.
Seven new durability cases passed, including ten journal/proof publication exits,
three root-replacement exits while the writer lock is held, collision retention,
live/unknown owner refusal, concurrent writers, exception cleanup and a GC
attempt during actual pre-publication safety capture. Focused journal (6), proof
(3), identity (7), GC (11), undo (14), branch (14) and service (45) suites passed.
These are process-interruption checks on this Linux filesystem; ambiguous owner
markers are conservative refusals. Copy-out and remaining navigation CLI work
still block P2 completion.

Durable-metadata checkpoint verification: `make build`, `make lint`, `make ci`
exited 0 (`*-store-safety.log` in the P2 external log directory). The formatter's
first run exited 1 while promoting files; subsequent lint passed. Focused suites
ran before CI; unchanged Dune results may be cached. No accepted G01 benchmark
was rerun, and README is unchanged. Unknown or live owner markers are retained
rather than guessed away; diagnostic handling for those markers remains a
conservative refusal, including possible PID reuse.

P2 copy-out engine / byte verification checkpoint: added a schema-2 physical
scope for one whole-directory copy into a new/empty destination, sharing the
existing staged application engine. Workspace schema-1 plans remain readable.
The source state/history is outside copy-out's physical action scope. Typed
preflight errors now distinguish conflicts, unavailable capabilities/I/O and
integrity. In-place and copy-out application verify actual original/retained and
installed/staged bytes against the real snapshot trees, using bounded descriptor
verification in addition to fingerprints. The focused engine suite passed 22
cases, including six copy mutation exits, original empty-directory retention,
external writes through displaced directory descriptors, corruption before
replacement, a 2 MiB binary executable and edits preserving inode/size/mtime.
Actual copy-out service/journal/CLI routing is still outstanding; this checkpoint
does not claim the existing CLI copy-out path has been hardened. Complete
undo/redo/restore CLI confirmation/outcomes and final P2 evidence remain open.

Copy-out engine checkpoint verification: `make build`, `make lint`, `make ci`
exited 0 (`*-copyout-engine.log` in the P2 external log directory). Formatter
promotion exited 1 on its first run; subsequent lint passed. The 22-case engine
suite includes complete identity verification for large manifests and direct
byte corruption with preserved native metadata. Unaffected Dune results may be
cached. No G01 measurements were rerun. Copy-out is not yet exposed by the new
service/journal path, and P2 remains incomplete.

P2 copy-out service/journal checkpoint: existing restore-to-directory now uses
whole-directory staged installation. New schema-4 journals bind the exact target,
physical digest and canonical output path without source-history/branch updates.
The independent Python canonical emitter verifies a committed golden. Six new
native local-service cases (suite total 20) passed: no source head/counter/cursor
or branch-position changes, seven actual copy journal/mutation exits, identical
explicit operation retries, stale destination plan refusal, later destination
edits after Materialized, safety export while an original source selection is
conflicted, and completed-export journal pruning without permanent source pins.
Journal suite total 8 passed; original service45/GC11/undo14 suites passed. The
first service run exposed a changed legacy nonempty-destination error prefix;
the compatibility wrapper now retains that error shape without weakening safety.
P2 remains incomplete: ordinary restore syntax, complete selection confirmation,
consistent plan/JSON/exit/action handling and the final acceptance report/receipt
are still required. No later pilot slice started.

Copy-out integration's initial `make ci` exited 2: two tiny benchmark-harness
resume cases detected storage changes caused by recovery verification writing
journals into the measured fixture. The untimed verifier now uses a disposable
metadata replica and asserts original storage/head are unchanged. The eight-case
harness suite passed after that fix; accepted G01 measurements/artifacts were
not rerun or changed. A first standalone harness invocation supplied an
unsupported extra positional argument and was rejected by unittest; the correct
no-argument invocation passed. Final common-check evidence follows this fix.

Final copy-out routing verification: `make build`, `make lint`, `make ci` exited
0 (`*-copyout-routing-final.log`). Focused journal8/native-local20/service45/
GC11/undo14 and independent vector generation passed. Tiny harness8 passed;
unchanged Dune results may be cached. The final formatter pass exited 0 (the
initial routing formatter promoted files). README and accepted G01 evidence
remain unchanged. Consistent local selection CLI confirmation/plan/outcome
handling and final P2 acceptance evidence remain outstanding.

P2 exact selection-intent checkpoint: schema 5 binds a local selection plan and
exact history target, including metadata-only moves between equal contents.
The audit found the previous equal-byte direct-CAS path could interpret retry
after lost acknowledgement as another undo. It now journals the cursor/branch
move while keeping ordinary file inodes unchanged. No destructive source proof
is fabricated for equal-content selection. Plan-aware navigation/branch APIs
reject changed inputs; snapshot selection marks new target IDs provisional until
atomic publication and creates no invented ancestry. Independent schema-5
golden generation, journal9, undo16 and service45 passed; native-local suite now
also covers provisional snapshot-root publication and stale branch plans.
Complete CLI confirmation/plan/restore syntax and structured recovery journeys,
then the final P2 acceptance evidence, remain outstanding.

Selection-intent focused verification now includes native-local22 (provisional
snapshot roots and stale named-branch plans), journal9 and undo16. The earlier
14-case undo suite expected an absent restore record for equal-byte navigation;
that assertion now verifies unchanged inode/size/mtime/ctime plus a recovery
operation. This directly tests no ordinary rewrite while retaining metadata
crash recovery. A first selection-intent full CI passed; final checks below
cover the last stale-preflight and additional native-local test changes.

Final selection-intent verification: `make format`, `make build`, `make lint`,
`make ci` exited 0 (`*-selection-intent-final.log`). Final Dune test results were
cached from matching successful runs; focused journal9/undo16/native-local22 and
service45 ran during this checkpoint. No G01 measurements or README edits.
Complete local CLI flag/selection/recovery journeys and final P2 evidence remain
required before completion.
