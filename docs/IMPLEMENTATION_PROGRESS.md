# Implementation progress

Updated November 16, 2026. This is the shared implementation ledger. Follow
[Implementation workflow](IMPLEMENTATION_WORKFLOW.md) for execution, reports,
verification, commits, and rollback. Each new agent reads and updates this file.

## Current state

- Design baseline: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`.
- Branch: `main`; one implementation writer at a time.
- Active dogfooding follow-up: connected local history, responsive numbered
  diffs and readable terminal contrast. Started on clean `main`
  `fba3daa945eb2c670595ab660576be30b8b3d380`; this preserves that revision's
  removal of the HTML preview. P4 remains unstarted. Verification is pending.
- Scoped dogfooding follow-up: compact local CLI output is complete at
  `8693ff36dc7d27230df3d1b6cdaa745442719115` after actual first-use feedback.
  The full P4 task remains unstarted. See [presentation notes](implementation/cli-presentation.md)
  and [verification](implementation/results/cli-presentation-20261116.json).
- Active implementation slice: none after P3 closeout. P3 shared workflow,
  session `p3-shared-2026-11-15`, started on clean main
  `2c7329d3ee930a38d5e8654346fab5d28853c707` and is complete at implementation
  `2fe8b32e2014ee8f29d36ee2baafbc93d7176553`. All seven scoped criteria passed;
  [report](implementation/reports/P03-attempt-01.md),
  [receipt](implementation/results/P03-acceptance.json) and
  [scoped task](implementation/goals/P03-shared-workflow.md).
- Earlier completed slice: P2 local workflow, session `p2-local-2026-11-14`,
  starting clean main `56eb13d271421720299d7e3f0dcd589d80b4d153`.
  P1 core-workflow foundation is complete;
  continuation `p1-core-resume-2026-11-14` started on clean main
  `06f526d9f6f09cd06bd3b57a7a348f64ea17817a` and verified implementation
  `06b662a8bab5c783117e5fcf45e36b7d942cfc64`. See the
  [P1 report](implementation/reports/P01-attempt-01.md) and
  [acceptance receipt](implementation/results/P01-acceptance.json).
- Current pilot handoff: P1/P2/P3 are complete; P4 is eligible and unstarted.
  See the [P2 report](implementation/reports/P02-attempt-01.md) and
  [acceptance receipt](implementation/results/P02-acceptance.json). The current
  priority remains the [complete pilot](PILOT_PLAN.md).
  P3 was separately invoked after P2; P4 requires a separate invocation.
- Original G02 has partial coverage through P1/P3, with its full remainder below.
  It is not complete and does not make full G03 ready.
- Completed full-design phases: **1 / 20** (G01). Completed pilot slices:
  P0 evaluation, P1 foundation, P2 local work and P3 shared work. Existing V1/undo predates this
  chain; P2 adds durable signed local branches, inspection and safe selection.
  No original full phase beyond G01 is complete.
- P3 verification: final build/lint/CI and independent vectors passed on the exact
  source committed as `2fe8b32e2014ee8f29d36ee2baafbc93d7176553`. CI freshly
  reported 25 OCaml suites/353 cases and 81 Python cases, with no reported skips;
  other matching Dune results were cached. Focused final graph/CLI checks also
  passed. Controlled TLS includes 30 transport cases. Native custody/human and
  broad performance gates remain P4/original-phase work; optional Docker checks
  remain unavailable to this user. No required P3 verification is missing.
- Earlier P2 verification: all seven scoped criteria passed at
  `6826af74810bb4087bb4795781d0176276df2b9e`. Final source implementation is
  `e181ff9ec863740ceb511fb888b23472056ebd15`; the later commit updates existing
  container/source invocations for explicit confirmation. Fresh focused checks
  executed 197 OCaml cases and 46 Python cases; build/lint/CI passed. Final CI
  reused matching valid Dune results. Native macOS/Windows, container execution
  (Docker socket access denied), native onboarding and human/performance product
  gates remain owned by later phases. P2 does not close those gates.
- Accepted G01 baseline: session `79434` exited 0 after both tiers passed all
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
| [G02: Implement canonical records, identities, and shared interfaces](implementation/goals/G02-canonical-records.md) | G01 | in_progress | Partial P1 foundation and P3 scopes/pages/plans/resolutions; [P1 report](implementation/reports/P01-attempt-01.md), [P3 report](implementation/reports/P03-attempt-01.md) | Review/request/event/policy and account/settings/archive records; request/member identity and proof; remaining policy/review/archive/crypto contracts and corresponding vectors/tests. Pilot coverage does not complete G02. |
| [G03: Implement causal authority, member identity, and review-policy evaluation](implementation/goals/G03-authority-policy.md) | G02 | pending | Partial P2/P3 causal branch/authority and explicit refusal coverage; [P3 report](implementation/reports/P03-attempt-01.md) | Principal/review/policy evaluation, reconciliation/adoption and full review matrix; see criterion coverage below |
| [G04: Implement deterministic composition and exact integration plans](implementation/goals/G04-composition-plans.md) | G03 | pending | P3 profile/graph/plans, exact public resolution proof and private workspace decisions; [report](implementation/reports/P03-attempt-01.md) | Full G03 policy/review context and prerequisite/phase acceptance remain; P3 scoped composition audit passed |
| [G05: Implement native ignore rules and reliable portable capture](implementation/goals/G05-capture-ignore.md) | G04 | pending | Partial P2 coverage; [report](implementation/reports/P02-attempt-01.md) | Native ignores/stable streaming capture/preflight delivered on Linux; full portability qualification and formal phase acceptance outstanding |
| [G06: Persist history and indexes incrementally with atomic roots](implementation/goals/G06-incremental-history.md) | G05 | pending | Partial P2 coverage; [report](implementation/reports/P02-attempt-01.md) | Pages/index/rebuild/publication correspondence and depth measurements; whole-history encoding retained |
| [G07: Implement lossless compression, indexed packs, and safe collection](implementation/goals/G07-compression-packs.md) | G06 | pending | — | All criteria in prompt |
| [G08: Synchronize immutable shared history with verified offline coverage](implementation/goals/G08-shared-sync.md) | G07 | pending | P3 verified Core export/receipt, frozen outbound/ack, native HTTPS exchange/clone, requested-version priority, all advertised branches/history and availability inspection; [report](implementation/reports/P03-attempt-01.md) | Policy/review record families, configured narrower scopes, repair of an already incomplete store and full-phase qualification remain |
| [G09: Implement private account identity, device enrollment, and recovery custody](implementation/goals/G09-private-identity.md) | G08 | pending | — | All criteria in prompt |
| [G10: Implement complete encrypted backup and exact private-history restoration](implementation/goals/G10-private-archive.md) | G09 | pending | — | All criteria in prompt |
| [G11: Implement automatic private retention and inherited settings](implementation/goals/G11-retention-settings.md) | G10 | pending | — | All criteria in prompt |
| [G12: Implement native optional and required review workflows](implementation/goals/G12-review-workflow.md) | G11 | pending | — | All criteria in prompt |
| [G13: Implement exact recoverable integration and remove delivery friction](implementation/goals/G13-recoverable-integration.md) | G12 | pending | P3 exact local application/recovery, two-person shared/private resolutions, offline acceptance and exact outbound acknowledgement; [report](implementation/reports/P03-attempt-01.md) | Full G12 policy/review-backed acceptance, wider platform/fault qualification and original-phase acceptance remain |
| [G14: Complete native workspace and ordinary CLI journeys](implementation/goals/G14-workspace-cli.md) | G13 | pending | P2 local work plus P3 native shared clone/share/update/exchange/integrate/conflicts/recovery/branch and unavailable inspection; [report](implementation/reports/P03-attempt-01.md) | Archive/preferences/full-review vocabulary, native custody/human qualification and original-phase prerequisites/acceptance remain |
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
| P2 local work | complete | [Scoped task](implementation/goals/P02-local-workflow.md), [report](implementation/reports/P02-attempt-01.md), [receipt](implementation/results/P02-acceptance.json); all seven scoped criteria passed; original phases remain partial |
| P3 shared loop | complete | [Report](implementation/reports/P03-attempt-01.md), [receipt](implementation/results/P03-acceptance.json); implementation `2fe8b32e2014ee8f29d36ee2baafbc93d7176553`, all seven scoped criteria passed |
| P4 harden/handoff | pending | Representative/native/human and fault evidence; unstarted |

## Current-phase checkpoints

- P3 final checkpoint: native shared workflow is complete at
  `2fe8b32e2014ee8f29d36ee2baafbc93d7176553`, including requested-version transfer
  priority, exact text/opaque decisions, private catch-up, lost-plan-alias retry
  from a stored decision, and update after accepted revision reconciliation.
  Build/lint/CI, focused checks and independent vectors pass. The final report
  and receipt audit every scoped criterion and original-phase remainder below.
  P4 is eligible and unstarted; no original full phase beyond G01 is closed.

- Earlier P3 checkpoint: native `conflicts`/`resolve`, streamed explicit replacements,
  canonical private workspace decisions and recovered application are committed as
  `51a63028250fa987ff870d959294347e0e3ee593`. Build/lint/CI pass on its exact stable
  source, including 85 local-state, 14 graph, independent control vectors, 11 local
  integration CLI cases and the existing 27 transport cases. The dedicated Alice/Bob
  TLS resolution extension, remaining authority/error/fault audit and full P03
  report/receipt are still required. P3 is active and incomplete; details below.

- Earlier P3 checkpoint: received-branch selection, saved-private restoration across
  newer shared heads, working-basis forks and unlocked/revalidated branch signing
  are committed as `bc75d492af15bb8e83bd863d7aceaef370a54c35`. Full build/lint/CI,
  real TLS named-branch/nondefault-clone journey and recovery/GC tests pass.
  Saved-metadata inspection and native local conflict preparation were subsequently
  added. Remaining error/authority/fault coverage and final criterion audit stay
  open. P3 is active and incomplete; details below.

- Earlier P3 verified native `clone URL [DIRECTORY]` checkpoint: preview/request
  binding and local resume are committed as
  `1105c60c8e724b9e49abf9f021b890207f4844e5`. Controlled TLS clone/update and
  interruption journeys pass; build/lint/default CI pass on stable source.
  Received-branch selection and nondefault clone are subsequently verified above.

- Earlier P3 native `exchange NAME` checkpoint passes a real controlled TLS
  Alice/Bob CLI journey, exact lost-acknowledgement retry and a private-cache
  provenance regression. Implementation is `10210f528ea424dd0393f3b1d6755df4817de979`.
  Build/lint/default CI passed; details below. Clone was subsequently added above.

- Earlier P3 checkpoint: public Core export and atomic metadata receipt are
  committed. `9f79f9dd6d0043eea3b696f429998117fe9444e4` preserves exact private
  history, allocation, positions, files and pending operations while admitting
  incoming public records. Durable outbound and real relay/clone/exchange were
  subsequently added; native resolution and the full audit remain required.

- P3 recovery continuation `p3-recovery-resume-2026-11-15` resumes on main
  `480ff7adc5e1518f76456927639355de11d53f18` with the existing thirteen modified
  source/test files and two untracked recovery CLI fixtures preserved. P2/P1
  prerequisite ancestry was rechecked. The latest build failed on the unused
  copy-out loader argument; recovery CLI cases then errored because their test
  executable had not been built. Earlier recovery-service results apply only to
  their recorded worktree. Stabilizing this checkpoint before native conflict
  resolution and Core clone/exchange; all seven P3 criteria remain binding.

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
| Capture/history/storage integrity and maintenance recovery | G05-G07 | partial | P2 Linux exact-byte/stable capture, journal/root/mutation faults and branch retention passed; incremental pages/index/rebuild, packs, depth and portable qualification remain |
| Shared offline coverage and concurrent-history preservation | G08/G13 | pending | Missing closure, offline unvisited state, receipt permutation and journal evidence |
| Private recovery and complete archive before eviction | G09-G11 | pending | Fresh-device recovery, rejected unauthorized access, interrupted manifests, protected-root tests |
| Review/confirmation boundaries and public/private separation | G12-G14 | pending | Both toggles, direct/required/offline paths, no private publication or false approval |
| Background lifecycle and resource behavior | G15-G17 | pending | Restart/wake/pause/credential/disk-pressure cases and measured scheduling behavior |
| Native macOS validation | G16/G20 | pending | Real macOS candidate-revision build/tests and service/fidelity journeys |
| Native Linux validation | G16/G20 | pending | Real Linux candidate-revision build/tests and systemd/fidelity journeys |
| Native Windows validation | G17/G20 | pending | Real Windows candidate-revision build/tests and login-service/fidelity journeys |
| Complete automated CLI journeys | G18/G20 | partial | P2 local text/JSON/confirmation/plan/branch/copy-out and process recovery passed; shared/remote/archive and whole-product journeys remain |
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


## P2 completed local-workflow handoff — November 15, 2026

Scoped task: [P02-local-workflow](implementation/goals/P02-local-workflow.md).
Implementation through `e181ff9ec863740ceb511fb888b23472056ebd15`, documented
invocations `6826af74810bb4087bb4795781d0176276df2b9e`. The separate closeout
commit contains this ledger, [report](implementation/reports/P02-attempt-01.md)
and [receipt](implementation/results/P02-acceptance.json). Its hash is obtained
from `git log -1 --format=%H -- docs/implementation/reports/P02-attempt-01.md`.
Earlier checkpoint remainders above are historical; this audit supersedes them.

All seven P2 criteria passed: actual inspection/domain output; TC07 ignore and
bounded stable capture; durable identity/allocation; signed native branch
list/create/switch; verified selection/copy-out/recovery; coherent confirmed CLI
journeys and tests; current APIs/guides and exact remaining-phase accounting.
Final focused verification executed 16 OCaml suites/197 cases and 46 Python
cases at the tested commit, including 16 selection and 17 branch CLI journeys.
`make build`, `make lint`, `make ci` exited 0. Final CI reused matching successful
Dune test results. Exact commands/exits/log digests are in the receipt; logs live
under `/home/gongahkia/.cache/yeokcham-p2-20261114/`. Native local suite now has
23 cases including signed concurrent-name refusal. Initial CLI expectation and
formatter-promotion failures were corrected; final checks report no skip.

| Original criteria | P2 coverage | Remaining owner/scope |
| --- | --- | --- |
| G03 C1 | Existing device trust reused | G03 principal/device proof binding, independent reviewer identity |
| G03 C2 | Signed causal branch/name/accepted head sets, receipt permutations, conservative selection/refusal | G03 full policy heads/fork evaluation, authority reconciliation/adoption |
| G03 C3–C5 | No fabricated approval/policy success; branch permutation/current trust tests | G03 independent approvers, exact review context/preferences/invalidation, event supersession/withdrawal/block/dismissal and full review matrix |
| G05 C1–C3 | Native ignore/explain, bounded descriptor-based capture and streamed exact bytes/exec/dirs/symlinks on Linux | G05/G20 full portable qualification and formal phase acceptance |
| G05 C4–C5 | Destination preflight, ignored/untracked/case/normalization conflicts, actual Linux and boundary/generated tests | G20 remaining native OS/filesystem matrix; no macOS/Windows pass claimed |
| G06 C1 | No paging/index replacement | G06 bounded pages/rebuildable index/append-cost work; profile before replacement |
| G06 C2–C3 | Durable namespace/counter/ancestry/cursor/private branch positions; atomic root/retry/collision/exhaustion | G06 publication correspondence and full independent-received-record/incremental-page scenarios |
| G06 C4–C5 | Current/pinned/branch/pending/proof roots, process restart/root/mutation faults and GC regressions | G06 index rebuild/page faults/depth measurements; accepted G01 not rerun |
| G14 C1–C3 | Private init/genesis, local inspection/history, named branches and exact local recovery | P3/G14 ordinary verified clone, selected share/update, shared composition/integration/archive and remaining vocabulary |
| G14 C4–C5 | Scoped preview/yes/plan/cancel/JSON/pagination/exits and mixed local journeys | G14 full command/preferences consistency and multi-person shared/remote journeys |
| G14 C6 | Honest watcher/service/backup state; existing regressions retained | G15–G17 actual managed service delivery |

G02 remains partial per P1; no additional full phase is closed. Completed full
design remains 1/20 (G01); pilot P0/P1/P2 complete. P3 is next eligible only upon
separate invocation; P3/P4 remain unstarted. No next prompt was generated.
Native onboarding, representative project responsiveness and human evaluation
remain P4/G18/G20. Docker integration is unavailable: `docker info` exited 1,
permission denied on `/var/run/docker.sock`; affected shell scripts passed syntax
checks. No native macOS/Windows or power-loss portability claim. README, accepted
G01 measurement/report/result files and P1 core golden bytes remain unchanged.
No benchmark artifact directories were recreated. Whole-history encoding remains;
no storage performance improvement is claimed. Preserve current metadata/live
files/journals/proofs and displaced native nodes when changing executable versions;
a source rollback does not undo materialization. See the report's exact rollback
order and data implications. No push/release/deployment or additional agent.


## P3 shared-workflow start — November 15, 2026

Verified clean `main`, one worktree, HEAD `2c7329d3ee930a38d5e8654346fab5d28853c707` and all five
requested prerequisite ancestors before editing. No newer commits or unrelated
changes observed. Session `p3-shared-2026-11-15`; full task saved at
[P03-shared-workflow](implementation/goals/P03-shared-workflow.md). P2 reports
and accepted G01 result digests are recorded in external
`/home/gongahkia/.cache/yeokcham-p3-20261115/start.json`; no measurements rerun.
Inspecting actual composition, selected-publication, accepted-result verification,
local root, transfer and safe-application boundaries before implementation.
P3 remains incomplete; P4 and independent full phases are not started.

P3 composition/scope foundation checkpoint: added one TC06 line-hunk implementation
shared with the existing display renderer; exact tree composition, selected
subtree construction and actual base/result/scope validation. Registry code 44
owns bounded paged edit scopes, with an independent envelope/store-ID golden.
The scope collection uses existing immutable objects, not another history store.
The initial nine semantic/property cases passed; independent-vector testing then
found a test-only fixture-path assumption under direct `dune exec`, now corrected.
Core model/record/trust, GC and existing text-diff cases passed. `make build` and
`make lint` passed with formatter promotion on the initial format invocation.
Final expanded bounded-reader/error tests and their check outcomes follow in
external composition logs. No accepted G01 measurement rerun or README edit.
This is a prerequisite only: P3 still needs actual accepted-result validation,
correspondence/outbox, publication, native exchange/clone, journaled integration,
conflict actions, end-to-end/fault verification and final acceptance evidence.

Final composition checkpoint checks passed: 11 composition cases (including 400
randomized byte reconstructions), existing text-diff5, independent scope vectors,
`make build`, `make lint`, `make docs-check` and `git diff --check` all exited 0.
Earlier focused core model/record/trust and GC checks also exited 0. Exact command
records are `composition-checks.json` and `composition-final-checks.json` in the
P3 external log directory. Formatter promotion initially exited 2 from make;
subsequent lint passed. No full P3 acceptance or shared CLI claim yet.


P3 signed accepted-result checkpoint: `Composition.Graph` now verifies actual
revision scopes, public/dependency bases, dependency-layer composition, exact
updates, common bases and inherited branch heads. The signed local store runs
this verifier after trust/reference checks rather than accepting arbitrary
nonempty snapshot claims. Metadata-only preparation APIs stage real signed
revision/accepted/event records; they do not apply files, publish a root/outbox
or claim a complete integration. Nonempty forks inherit their source result.
Derived public snapshots now have explicit shared-history GC roots independent
of private captures; actual collection/reload is tested. Six graph cases and
25 signed-local cases passed, plus existing GC/store/service45/undo16 checks,
`make build` and `make lint` (all exits 0, `accepted-graph-checks.json`). Initial
strict-warning compilation failures were corrected; formatter promotion is
recorded in its external log. Full checkpoint CI follows the final reader/GC
changes before consumers proceed. P3 remains incomplete: correspondence/outbox,
actual selected publication, plans/private-work preservation, journaled execution,
native clone/exchange, resolution commands and full end-to-end/fault evidence
remain required. No README/G01 measurement changes or later pilot work.

Accepted-graph checkpoint CI initially exited 2: watch/runtime status polling
hit the workspace writer lock and returned an inspection error. Status now
reads the atomic saved metadata without scanning live files when another writer
owns that lock; capture is explicitly incomplete/unknown. A real fork holding the
lock verifies no partial-tree observation. With the current binary rebuilt,
inspection7, watch3, runtime4, `make build`, `make lint`, and full `make ci` exited
0 (`accepted-graph-final-checks.json`; matching unchanged Dune results may be
cached). Tiny benchmark harness regressions ran; accepted G01 measurements did
not. During this checkpoint an external commit appeared:
`869a328ef9c8bd3020c56cd84892814ad6294bab` (`reworked`). Its 16 paths contain
only the owned graph/store/GC/status/test/documentation changes; inspected and
preserved without reset/amend. Worktree was clean afterward. P3 remains
incomplete; next implement durable publication correspondence and operation/outbox
bookkeeping in the existing root before the actual share/integrate consumers.

P3 continuation starts at clean main
`5435659187e840adb04f1cf73d3430030350492c`, session
`p3-shared-continuation-2026-11-15`. The existing full P3 task and all seven
criteria remain binding. Implementing scoped publication correspondence and
durable retry/outbound facts under the existing root, then their actual CLI
consumers. No later pilot slice or independent original phase started.

P3 publication-receipt checkpoint: immutable namespace-bound metadata pages use
registry code 45, with independent envelope/identity fixtures, bounded readers
and chunked control values. Local schema 2 roots private publication receipts
alongside existing signed records/positions. Receipts bind an operation, retry
intent, source history observation, exact newly contributed scope and source
Merkle witnesses. Existing receipts are immutable; identical retries reuse their
operation identity and conflicting reuse/collisions refuse. Carried-forward
remote fields are not asserted as newly observed local edits.

The first GC test failed: existing snapshot/tree loaders recursively required
unselected private blobs. Commit `6c58589` adds explicit canonical metadata-only
loaders for witness traversal; ordinary loaders retain their full-closure checks.
Actual collection of an old unselected blob now leaves source correspondence
verifiable without pinning the whole private capture. Native signed-local29,
metadata-pages6, core-model, composition11, GC11, content-verification and
snapshot-materialization3 passed. `make build`, `make lint`, `make ci` exited 0;
matching unchanged Dune results may be cached. Evidence is
`publication-final-checks.json`, `publication-broad-checks.json` and
`publication-snapshot-materialize.log` under the P3 external log directory.
One attempted focused target `test/test_snapshot.exe` did not exist; the actual
`test/test_snapshot_materialize.exe` passed. Initial strict-warning/docstring
compile failures and formatter promotion were corrected before broad checks.

After the user resumed the goal, clean main was
`39db20671da7ea3ae3417d49b07568f7539f6552`: external commits `b4080389` and
`39db2067` had committed the owned receipt/pages checkpoint and diagnostic test
edits. Inspected/preserved both; no reset/amend or push. P3 remains incomplete.
Next connect actual selected share to atomic capture/history/receipt publication,
then exact private-preserving integration, native exchange/clone, conflicts and
the complete fault/CLI audit. Receipt staging is not an implemented transfer
acknowledgement or a complete service operation. README/G01 measurements remain
unchanged; no later pilot slice started.

P3 native selected-share checkpoint: ordinary `share [PATH...]`, `--title`,
`--preview` and `--update CHANGE` now use generated Core identities and the
existing writer/root system. Current disk capture/history, signed public revision
and scoped receipt/outbound obligation commit atomically; sharing does not accept
or replace working files. Preview requires no signing provider. Captured native
ignore decisions are reused rather than rereading changing live rules. Updates
retain unselected public fields; changed explicit requests can create distinct
same-content versions, while identical recorded requests reuse their operation.
Status exposes native shared revisions, private working basis and publication
receipts separately from accepted heads. Ordinary full-tree verification now
uses bounded content verification instead of allocating whole large files.

Native signed-local34 passed, including five actual service scenarios and
process exits before/after root publication; fresh-process native-share CLI8,
existing branch CLI17, capture7, ignore5, service45, inspection7, CLI28,
content-verification and snapshot-materialization3 passed. Preview and recorded
retry do not reexecute an explicitly configured share hook. Plain/JSON checks
include generated IDs/titles, pending transfer, literal paths, same-content
updates, ignored/malformed captures, unavailable signing provider and mixed large
binary/executable/directory/symlink work. Existing legacy `--change/--revision`
sharing and its package/transport regressions remain available.

Implementation was externally committed as
`9b119996ccb5f6445c324ecfc8b65dd664d38fca` (`snapshotted`) during verification;
its sixteen paths are exactly the owned source/tests/current guides. Inspected
and preserved. First native-share full CI exited 2 because the existing GC
corruption fixture unconditionally created an object shard already present from
random workspace metadata. The test now checks/reuses real existing directories;
its corruption refusal assertion is unchanged. A following lint invocation
required formatting that fixture hunk. Final focused GC11, `make build`,
`make lint`, `make ci` exited 0 (`native-share-verified-checks.json`); the exact
earlier focused/broad outcomes are in `native-share-*-checks.json` in the P3
external log directory. Matching unchanged Dune results may be cached. One
initial CLI expectation omitted the renderer's correct quoting and was corrected;
no runtime behavior was weakened. Tiny harness regressions ran, not G01 accepted
measurements. README remains unchanged.

P3 is still incomplete: new Core public export/native clone/exchange, exact
private-preserving integration plans, recoverable execution/accepted outbox,
resolution and the full two-person/fault audit remain required. Current selected
shares are recorded locally with pending transfer; legacy packages do not carry
those Core records yet. No P03 completion report/receipt, later pilot slice,
independent phase completion, push/release/deployment or next prompt.


P3 exact-plan checkpoint: `57e0c2abd9d2f7058336ca0b4688db410c3826eb`
adds shared causal-change heads and bounded metadata reconstruction.
`41538b820676653f81b5e0faa3670d21c2d6ab18` adds `Yeokcham_v1_integration`, private scoped preservation and the
canonical bounded registry-46 plan. Preparation binds exact selections, every
causal event/accepted head, authority, private cursor/basis, captured filesystem
facts and separate accepted/private outputs. Unrelated receipts preserve plans;
changed relevant inputs require fresh confirmation. Decoding a declared Ready
output is insufficient: revalidation recomputes composition before execution.
Explicit reconciliation includes equal-content histories. Required policy and
unsupported resolution still refuse rather than supplying placeholder success.

Retained proposal aliases use create-only/fsynced files under the existing
retention lock. They pin complete source/output closures for GC without advancing
history or accepted refs. Fresh-process load, actual GC, explicit release, missing
contents, corrupt-alias refusal and proposal-specific health diagnostics passed.
Private preservation covers shared D/later private E, nonancestor refusal and
already represented revisions without backdating their accepted basis. The latest
signed local-core suite passed 47 cases. The bounded-pages suite passed 7; focused
model/composition/graph/GC/health checks passed in the recorded planner states.

For the complete pending planner tree on parent `57e0c2a`, focused local-core,
`make build`, `make lint` and `make ci` exited 0; the tree was then committed as
`41538b8`. Logs and exact commands are in `plan-checkpoint-checks.json` under
`/home/gongahkia/.cache/yeokcham-p3-20261115/`; earlier focused evidence is
`plan-retention-focused-checks.json`. Build, lint and CI also exited 0 on the
committed planner with only current documentation changes pending
(`plan-committed-checks.json`). Matching Dune results may be cached. The
initial formatter invocation exited 2 while promoting the expected source/test
formatting; subsequent lint passed. No G01 measurement was rerun.

P3 remains in progress. Confirmed CLI integration, durable plan/operation facts,
actual safe application with atomic accepted/history/outbound publication,
conflict resolution and Core native export/clone/exchange still require delivery
and end-to-end/fault evidence. P4 remains unstarted; no P03 completion report or
acceptance receipt is claimed. Preserve all current recovery roots and verify
this checkpoint before continuing. The planner's alias alone is not an operation
journal, outbound acknowledgement or completed integration.


P3 durable-execution checkpoint: `5f6039a8c4d85a86d8b5214910e67dd5579a6a36`
adds caller-bounded native object reads before input allocation, with the existing
global limit retained. `c9da48551a0fa7e30b5b55adf6add7998e703502` connects the exact planner to actual
`Local_service.Integrate` prepare/apply/resume, P2 safe file application and the
same authoritative state root. Local-core schema 3 carries private paged operation
facts; old schema 1/2 remains canonical without operations. Plan-to-token identity,
staged signed acceptance/event references, safety/target roots, physical digest,
provisional sequence and Prepared/Applying/Materialized/Committed/Completed/Paused
facts persist across fresh processes. Staged records are not authoritative heads
before commit. Accepted records, exact private history/basis and pending outbound
obligation publish atomically. No native transfer acknowledgement is claimed.

A dirty safety capture is retained before mutation; the target history sequence is
consumed only at actual commit, even for equal contents. Relevant shared inputs
are rechecked without scanning a partially applied tree. Materialized/Committed
retries never replay files. Provider callbacks execute outside writer locks, then
the service reloads/revalidates before preparation. External edits during Applying
pause without rollback; edits after Materialized survive completion. Unrelated
received metadata is preserved. Ordinary save/undo/switch refuse while integration
is incomplete; status reports unavailable observation rather than a complete
partial tree. GC independently protects operation roots through the Committed
cleanup gap; verified restore proofs precede Completed where safety differs.

The signed local-core suite passed 56 cases, including nine new native execution
scenarios, eight phase/file-boundary interruptions and ten before/after root-CAS
interruptions. Tests cover one acceptance/navigation on retry without signer,
D/E separation, actual GC during Materialized, independent receipts, pending-root
erasure/capture refusal, provider lock probes and provider-time edits, bounded
cross-kind token collisions and entropy failure. Store-safety8, history identity,
safe apply, existing local-service45/store/GC11/health suites passed. `make build`,
`make lint`, `make ci` exited 0 for the exact pending tree on parent `5f6039a8`,
then committed unchanged as `c9da48551a0fa7e30b5b55adf6add7998e703502`. Commands/exits/logs are
`native-integration-checkpoint-checks.json` under the P3 external log directory;
matching Dune results may be cached. Early compile/strict-warning errors, a raw
versus hex physical-digest mismatch and expected formatter promotions were fixed
before these final checks. The tiny harness regressions do not rerun G01 accepted
measurements. README remains unchanged.

Rollback of this checkpoint requires preserving current schema-3 repositories,
operation staging and recovery proofs: older binaries cannot read operation-bearing
local state, and reverting source never restores user files or removes an accepted
record. Do not erase pending operations, reuse their sequence/token or drop roots
to make a revert appear successful. No migration or recovery-data deletion ran.

P3 remains incomplete. Next consume the actual integration service through normal
CLI selection, preview/confirmation, JSON/plain results and operation inspection/
resume/recovery; implement explicit conflict resolution and Core public native
export/clone/exchange. Full two-person relay, privacy, concurrent-head/policy,
transfer/outbox and complete recovery/fault acceptance evidence remains required.
These service tests are not ordinary CLI, native custody onboarding or human pilot
evidence. No P03 completion report/receipt or P4 start is claimed.


P3 ordinary-integration CLI checkpoint:
`7d32acd8a548e3c7d53dd69b39a7dc44a0e489d5` adds `integrate CHANGE...`,
contextual/explicit-all selection, exact revision IDs, retained `--plan` previews,
default cancellation/noninteractive confirmation, explicit all-head reconciliation
and actual apply through the durable service. Preview displays separate accepted
and private path/text/opaque differences. `operation show/resume` inspects/resumes
an existing operation, including provider-free completed retries; status exposes
integration facts separately from publications and accepted/private basis.
Already completed retries and fresh represented selections report Unchanged.
`compare_immutable_snapshots` reuses verified bounded diff display for staged
proposals; working-tree comparisons also refuse during incomplete application.
Current collaboration/undo guides and actual interfaces were reconciled.

Fresh-process native-integration CLI6, selected-share CLI8, local-branch CLI17 and
signed local-core56 passed. `make build`, `make lint`, `make ci` exited 0 on parent
`f3cbf8925991e10c81874c24b638f4227bcb4ac8` with the exact pending tree later
committed unchanged as `7d32acd8`. Evidence is
`integration-cli-checkpoint-checks.json` in the P3 external log directory;
unchanged Dune results can be cached. Initial declaration-order compile failures
and expected formatter promotions were corrected before the verified checks.
CLI cases include actual PTY cancellation, provider-free preview/repeat/no-op,
stale confirmation without reservation, D/E separation, JSON/plain differences,
contextual/all selection, operation inspection/resume and malformed/missing-root
failures without recursive error handling. Disposable signer/native-local evidence
is not custody onboarding or native Core relay delivery evidence.

P3 is still incomplete: ordinary conflict listing/resolution, user-facing recovery
choices/cancellation after writes, Core public export/clone/exchange and the full
two-person/concurrency/policy/outbox/fault audit remain required. Existing V1
transport regression success does not establish the new Core exchange loop.
No P03 completion report/receipt, original-phase completion, P4, push/release or
deployment is claimed. Preserve schema-3 operation data and all recovery roots;
source rollback cannot undo acceptance or restore user files.


P3 integration-outcome correction: `e7b87673b218a3a39d486596959a3d8169e65070`
preserves typed capture errors through the native adapter, maps missing repositories
to the existing unavailable exit category, and reports conflicted previews as
Incomplete. Native integration CLI8 passed, including independent same-path shared
conflicts, refusal with --yes, malformed native rules, no reservation/history/file
changes and bounded missing-root error handling. Build/lint passed. The first CI
run exited 2: the unchanged existing 2.56 MB mixed-file share journey exceeded its
20-second subprocess timeout. The fixture timeout/assertions were not changed.
The same focused case passed in 11.2 seconds; a repeat `make ci` on committed
`e7b8767` exited 0, with selected-share CLI8 taking 19.1 seconds and matching
successful Dune actions cached. Host load and memory/swap pressure were observed;
contention is an inference, not a proven performance root cause or fix. Retain the
failure as flaky verification evidence. Exact outcomes are
`integration-cli-outcomes-checks.json`, `share-timeout-repro-focused.log` and
`integration-cli-ci-timeout-repeat.json` under the P3 external log directory.
No accepted G01 measurements were rerun or modified. All outstanding P3 criteria
listed above remain open; this correction is not a completion claim.

P3 private-recovery checkpoint:
`8b37259e1089aaad48830fcb6feec461dfe22f48` adds private recovery attempts to the
same paged operation root, explicit restore-safety/keep-current choices, immutable
prior attempts, retryable phase/metadata execution and verified proof/GC ownership.
Recovery closes only uncommitted integration; its single private child consumes
the reserved sequence without admitting staged acceptance. External edits pause;
Materialized retries do not replay files. Replanning retains earlier observations.
The safe application engine now checks all expected target paths before claiming
Materialized, including paths the operation did not write, while preserving
noncolliding ignored extras.

`2a0cc3650319c62ed0730447ffbd6ccd050a4989` adds ordinary
`operation recover/forget`, exact preview/confirmation, default cancellation,
provider-free resume and schema-2 facts/actions. Retained observations support
ordinary diff and recovery copy-out. Completed historical retries report their
recorded state without claiming a current-file inspection. Explicit root release
leaves history/files/acceptance intact and reports potentially unavailable
historical comparisons. Current interfaces and collaboration/undo guides describe
the ordered private schemas, domain digests, ownership and consumers.

Two actual GC regressions were reproduced and corrected: collecting a released
unaccepted merged proposal previously made its cancelled operation unreadable;
a pending recovery-observation copy-out was previously rejected as outside the
ordinary checkpoint set. Released cancelled staging still verifies signed
identity/references/inputs but does not require discarded composition contents;
it cannot admit those records. The authoritative public pool retains full result
validation. Journal/proof contents now have independent verified GC roots even
when never captured as ordinary checkpoints. Collection/reload/resume and a
copy-out interrupted before files, followed by original-root release and actual
GC, are covered.

Focused signed local-core67, safe-apply22, store-safety8, restore-proof3, GC11,
local-service45 and inspection7 passed. Fresh-process recovery CLI4, integration
CLI8, selected-share CLI8 and branch CLI17 passed. `make build`, `make lint` and
`make ci` exited 0 on parent `480ff7a` with the exact pending source tree then
committed in the two hashes above. CI took 24.057 seconds; successful unchanged
Dune actions can be cached. Exact commands/exits are
`native-recovery-checkpoint-checks.json`; CI includes the worktree file hashes in
`native-recovery-ci-check.json`, both under the P3 external log directory.
Initial build/strict-warning errors, formatter promotion (make exit 2), a focused
filter that selected no tests, and both intentionally failing GC reproductions
are preserved in the external logs. The final full focused run did not filter
out cases. No assertion or timeout was relaxed. README, P2 handoff and accepted
G01 file hashes still match the starting receipt. Tiny CI harness regressions
ran; accepted G01 measurements did not.

This checkpoint adds partial G02 private-operation schema, G04 exact-plan
consumption, G13 execution/recovery and G14 ordinary recovery-CLI coverage. It
does not complete any original phase. G03 still lacks complete required-policy/
review/adoption evaluation; unsupported required semantics refuse. G04 still
needs native resolutions and its full phase audit. G08 Core public export/native
clone/exchange/coverage and real outbound acknowledgement remain open. G13 still
needs those acknowledgement semantics, conflict/policy integration and the full
two-person/fault audit. G14 still needs ordinary Core clone/exchange/resolution,
with archive/preferences outside this scoped pilot. Preserve operation schema-2
rows, linked attempt pages, proofs and staging when changing binaries; source
rollback cannot undo accepted history or restore user files. No migration,
current-data deletion, P4 work or P03 completion claim is made.

P3 signing/identity checkpoint:
`fa6a89f90526def2ec7a2ed8be6f8db70b42e0a5` moves selected-share provider callbacks
outside the workspace writer lock. After immutable signing, the service reloads
and checks both the state head and captured filesystem-fact digest before the
atomic capture/history/receipt root. Provider-time edits or saved state changes
refuse with a fresh-preview choice while preserving those changes. Concurrent GC
can collect unrooted staging while signing; semantic verification then refuses
without publishing, and a fresh attempt recaptures the live files. Forked lock
probes and actual provider-time save/GC scenarios verify these boundaries.

Publication entropy retries now reserve integration tokens and every current or
superseded recovery-attempt token alongside publication tokens. A reproduced
cross-kind collision previously failed after one draw rather than using the
bounded retry contract; it now retries at most three times and can succeed after
skipping a reserved recovery identity. Identical receipt retries are unchanged.

Signed local-core69, native share CLI8, integration CLI8 and recovery CLI4 passed;
`make build`/`make lint` passed. Default `make ci` exited 2 when the same existing
2.56 MB share case exceeded its unchanged 20-second subprocess limit. Focused
share CLI8 had passed in 13.017 seconds. Load/memory pressure was observed, but
contention remains an inference. On the unchanged pending tree, `DUNE_JOBS=2
make ci` exited 0 in 13.182 seconds; the failed share suite ran in 12.361 seconds,
with matching successful Dune actions cached. No assertions/timeouts were
relaxed. Exact commands, worktree hashes and outcomes are
`share-provider-checkpoint-checks.json` and
`share-provider-ci-bounded-check.json` under the P3 external log directory.
Keep the default-run failure as flaky evidence, not a passing check.

This corrects a required P3 writer/signing boundary; it does not establish native
Core export/clone/exchange or conflict resolution. Those consumers, durable
native outbound acknowledgement, the Alice/Bob relay loop and the complete
criterion audit remain open. P3 stays in progress and P4 remains unstarted.

P3 native-transfer metadata prerequisite:
`b0fe7049f8104789676b23f41f24af36c97733b9` adds
`Pages.page_references ~namespace ~expected bytes` without changing registry
codes or stored bytes. It verifies each at-most-1-MiB envelope's identity,
type/version/features, namespace and local structure before returning bounded
direct references. Complete collection canonicality and cross-page value/maximum
checks still require the existing full verifier; discovery alone is not admission.
Tests walk the actual 17001-row/8-MiB-value closure, including shared repeated
chunks, and reject malformed scoped inputs before following references. A false
child maximum explicitly demonstrates the distinction from full validation.

Metadata-pages9, `make build`, `make lint` and `DUNE_JOBS=2 make ci` exited 0
on the exact pending tree on parent `8ecfee3`, then committed unchanged. CI took
46.572 seconds, with matching successful Dune actions cached where applicable.
Exact commands, environments, exits and file hashes are in
`public-page-discovery-checkpoint-checks.json` under the P3 external log directory.
Expected formatter promotion exited 2 before successful lint. No new transfer
success, native custody, shared coverage or P3 completion is claimed.

Next connect a verified public-only Core inventory/manifest to native transport,
durable outbound acknowledgements, receipt and clone. Existing local decoding
still requires complete public composition contents; metadata/availability receipt
needs an explicit boundary without weakening validation of newly admitted signed
results. Unknown remote branches must remain distinct from private working
positions. Native conflict resolutions and the full Alice/Bob privacy/fault audit
also remain required. Preserve all current operation schemas/roots and the P2
journeys while implementing those consumers.

P3 native public-package continuation `p3-core-exchange-2026-11-15` starts on
clean main `30e01afcddc411ef2d7f4fc0aaaf1d09d4602744`. Extending the existing
package boundary with a paged public Core manifest/verified closure, then its
actual store/relay/clone consumers. The original full P3 scope remains binding;
public-only packages are necessary evidence, not completion of native exchange.

P3 public Core export checkpoint: external commit
`1c5e66e9e6fc5a2fbc6e9fdfb54eca7402465094` (`newthings`) appeared during verification.
Its six paths contain only this continuation's owned package boundary, tests and
starting ledger entry. Inspected and preserved without reset/amend. It introduces
`Package.Core` and canonical package-manifest version 2, with repository-scoped
registry-45 inventories for public record references, authority, courier titles
and exact object sizes. No new envelope code or competing mutable state exists.

Creation follows only typed public Core records and their verified dependency
closure. Preparation verifies in an isolated store: historical signatures,
canonical references/pages, complete scope/result composition, causal root
continuity and exact public inventory. A canonical extra private blob is rejected
after structural verification; a valid signature over a false accepted result is
also rejected. Immutable import moves neither ordinary files nor a project head.
Known authority pins its root; initial clone still needs independent root checking
and existing enrollment. Current new-record admission remains a separate service
obligation; historical package verification does not silently adopt late records.

`a65db94492923b5e6eaa2300e1d40a7e4c3a8222` records formatter/API/schema documentation,
independent public-manifest/courier/hash fixtures and native SHA-256 selection.
The existing pinned Digestif 1.3.1 C implementation replaces explicit OCaml
implementation linkage; algorithm, signatures, canonical bytes and identities
remain unchanged. Actual independent vectors and offset/persistent-context tests
passed. Common artifact iteration/lookups bound file reads before allocation;
large files continue through existing manifests/chunks, not whole-file buffering.

The new mixed-file package journey first passed in 206.810 seconds with the
OCaml backend. Attaching a debugger was unavailable (ptrace denied); a controlled
child debugger sample showed OCaml SHA-256 during repeated snapshot verification.
Diagnostic child runs were deliberately ended after sampling and are not counted
as passing tests. The C-backed four-case run passed in 57.937 seconds; later
six-case focused run passed in 32.498 seconds and CI's six-case run in 39.002.
These are individual functional diagnostics under changing load, not a benchmark
comparison or a claim that all verification costs are resolved. G01 measurements
were neither rerun nor changed.

Focused Core-package6, Core-record6, Core-trust3, metadata-pages9, legacy-package10
and signed local-core69 passed. All three independent generators passed, including
new exact manifest, courier ID and streamed SHA-256 vectors. `make build`,
`make lint` and default `make ci` exited 0 on parent `1c5e66e` with the exact
pending tree then committed as `a65db94`; CI took 40.823 seconds and may reuse
matching unchanged Dune results. Commands, exits, file hashes and logs are in
`core-public-package-checkpoint-checks.json` under the P3 external log directory.
Initial strict-warning/declaration failures and expected formatter promotions
(make exit 2) were corrected before these checks. README, P2 handoff and accepted
G01 hashes still match the starting receipt. Legacy package/relay support remains
distinct from the new manifest format; those older clients do not gain Core
exchange by aliasing a command.

This adds P3 public-only closure evidence and partial G02/G08 coverage, not full
phase acceptance. Next implement actual atomic Core receipt/outbound state and
native relay/clone consumers, including known-only remote branches without
inventing private working observations. Metadata/availability receipt still needs
an explicit boundary; do not weaken new accepted-result validation to make missing
contents appear verified. Native conflict resolution, real acknowledgements,
Alice/Bob relay/fault journeys and the complete criterion audit remain open.
Preserve existing recovery roots and format-bearing data when changing binaries;
source rollback cannot undo accepted history or restore files. P3 remains active,
P4 unstarted, and no P03 completion report or acceptance receipt is claimed.

P3 atomic Core receipt checkpoint:
`9f79f9dd6d0043eea3b696f429998117fe9444e4` adds
`Local_service.Core_receive` and `Local.receive_records`. Complete public packages
are historically verified in isolation and immutable bytes imported outside the
writer boundary. Under the existing writer lock, current authority and records
are reloaded, newly arriving records cross current trust admission and actual
composition validation, then one existing state-root CAS publishes the union.
No files are scanned/replaced, no private history/identifiers are allocated, and
no transfer acknowledgement is fabricated. An independent receipt during a
Prepared integration survives that operation's later commit without staling its
exact relevant inputs or losing its pending operation.

Local wrapper schema 4 represents known public branches without inventing private
working positions. Existing positions cannot be dropped by an update; schema
1/2/3 complete-position states retain their exact encoding. Branch listing now
exposes selected/private-saved/known-shared state; selection of a newly known
branch refuses before replacement until first materialization is implemented.
Required unsupported policy and Core record/trust/composition failures remain
typed errors. This checkpoint only admits complete packages: metadata-only
availability, missing-content inspection and foreground coverage remain open.

Core-package10, signed local-core69, legacy-package10, Core-trust3,
Core-record6, store8, GC11 and branch CLI17/share CLI8/integration CLI8/recovery
CLI4 passed. `make build`, `make lint` and default `make ci` exited 0 on parent
`c437195305ed63f92de97504ce5063f19129b215` with the exact pending files then
committed as `9f79f9d`; CI took 40.367 seconds and reused matching unchanged Dune
results where applicable. Commands, exits, durations and file hashes are in
`core-receipt-checkpoint-checks.json` under the P3 external log directory.
Formatter promotion exited 2 before successful lint. Earlier focused failures
included strict warnings, incomplete CLI error classification, a stale test
binary and a fixture that combined JSON stdout with human stderr; these were
corrected before the passing complete runs, without relaxing assertions. The
four-case focused run intentionally filtered the other six cases; the subsequent
whole ten-case run and CI executed all ten. README, P2 handoff and accepted G01
hashes still match the starting receipt; no accepted measurement was rerun.

This adds partial G02 local-wrapper and G08 receipt evidence, plus G13 unrelated
receipt/recovery and G14 branch-inspection regression coverage. No whole original
phase is complete. Next connect durable frozen outbound/courier acknowledgement,
real native relay clone/exchange and supported first materialization, then native
conflict resolution and the complete two-person/fault audit. Courier titles are
not yet persisted on receipt. Existing legacy transport remains a separate
consumer and does not establish the new Core loop. Preserve schema-4 roots and
all current recovery data when changing binaries; older binaries cannot decode
known-only branch state, and source rollback cannot restore files or undo
accepted history. P3 remains active; P4 is unstarted.

P3 frozen Core outbound checkpoint: external commit
`639553a236ab5c862a29a98bc9a63a430728b911` (`newthings`) appeared during
verification. Its 15 paths contain exactly this continuation's owned outbound
service, transport state, package reconstruction, tests/vectors and interfaces.
All recorded checked-file hashes match the committed files. Inspected/preserved
without reset or amend; main is clean before this ledger update.

`Local_service.Core_outbound` now freezes exact public manifest and signed
courier bytes under the existing state root before network requests. The signer
runs outside the writer lock; current authority/local certificate and retained
records are checked before publication. Pending retries reconstruct that exact
verified package without a signer, including after actual GC. Later public work
and private observations remain current and do not retarget the batch. A changed
endpoint requires a distinct remote name rather than repurposing pending work.

`Transport.Core_outbox` extends the existing collaboration transport value with
canonical private schema 2 only when Core rows exist. Legacy-only schema 1 bytes
are unchanged; no envelope kind or competing mutable ref was added. Root saves
refuse dropped pending batches, endpoint changes, acknowledgement regression and
lost courier/manifest evidence. Acknowledgement requires the exact frozen courier
and marks an integration transferred only when all its staged records occur in
that frozen inventory; later acceptances remain pending. Operation boolean means
at least one exact transfer, with per-remote facts retained separately. Local
acceptance, frozen work and actual relay acknowledgement remain distinct; the
service acknowledgement API is not itself evidence of a network response.

Core-package14, HTTPS/legacy transport21, signed local-core69, store8, transfer8
and GC11 passed. The independent generator verifies four public/hash/outbound
vectors, including unchanged historical courier bytes. `make build`, `make lint`
and default `make ci` exited 0 on parent `306ca3b3c994d81fb348eb8e279b3a8544390e6f`
with the exact pending files captured as `639553a`; CI took 58.617 seconds and
reused matching unchanged Dune results where applicable. Commands, exits,
durations and file hashes are in `core-outbox-checkpoint-checks.json` under the
P3 external log directory. Initial strict-warning/test syntax/module-name build
failures and formatter promotions (exit 2) preceded the complete passing runs.
The early four-case and publication-only filters intentionally skipped other
cases; the subsequent whole Core-package14 and transport21 runs executed them.
README, P2 report/receipt and accepted G01 preservation hashes still match.

This adds partial G02 private-schema, G08 outbound/retry and G13 exact-operation
acknowledgement coverage. It does not establish Core native HTTP transfer, verified
clone, foreground coverage or the Alice/Bob loop. Those consumers, supported first
selection of known-only branches, incoming courier-title persistence, native
conflict resolutions, missing-content inspection and the full criterion audit
remain required. Legacy HTTPS tests exercise the existing older family; they are
regression evidence, not the new Core loop. Do not use the relay's lexical
publication cursor as an arrival high-water mark: a later courier can sort before
it. The native consumer must rescan the bounded inventory and filter verified
known IDs, or supply an actual append-order protocol before claiming coverage.

Preserve schema-2 transport and schema-4 local roots, public inventory pages and
current recovery data when changing binaries. Source rollback cannot remove a
relay acknowledgement, restore files or undo accepted history; older transport
readers refuse Core-bearing state. Native transfer/resolution remains the next
P3 work, not P4 or a new original full phase. P3 stays active and incomplete.

P3 native Core HTTPS exchange checkpoint:
`f6dd1e4a882fb4f9c38688e28ccf92870f7e360c` and
`b78afa53278eef9b206c5b5133450c61039ea62c` appeared as external `newthings`
snapshots during implementation. Their paths contain this continuation's owned
inbox/metadata/HTTP and exchange/CLI/test work. Inspected/preserved without reset
or amend, including the then-unverified code. Final verified source is
`10210f528ea424dd0393f3b1d6755df4817de979`; it includes formatting, completed
courier retention/status, independent vectors and the public-provenance guard.

`exchange NAME` now runs actual native Core receipt and outgoing transfer through
the HTTPS relay. It rescans a bounded hash-ordered inventory, validates feed
causality and metadata, prioritizes declared selected contents, fetches remaining
closure, then performs isolated full package proof/current admission. Receipt
preserves files/private history. Native uploads consume the frozen batch and
persist actual courier acknowledgement. Legacy manifest-1 receipt stays explicit;
`sync` remains the older family command. Structured schema-2 JSON reports domain
IDs, received records/branches, local verified closure and outgoing facts; it
separates checked relay inventory from unknown remote disclosure and foreground
execution. A post-receive outgoing failure is incomplete/exit 5 with retry action.

Private transport schema 3 retains a verified courier/manifest catalogue with
remote/endpoint provenance under the same root. It includes incoming couriers and
locally issued couriers once acknowledged. Earlier coverage survives preparing a
new batch. Inbox/outbox guards refuse dropped evidence, endpoint changes and
pending-batch replacement. Current schema 1/2 data retains supported decoding;
older acknowledged schema-2 manifests are retained when preparing newer work.
Canonical catalogue/acknowledgement bytes have an independent Python vector.
Courier labels retain provenance and forward only when unambiguous. Status now
derives exact acknowledging remotes instead of always printing pending; known
acceptance reuse with no new staged records reports transfer not_required.

Code inspection found that unrestricted raw-cache reuse could satisfy a newly
advertised missing public hash with private local contents. The native consumer
now derives reusable contents only from the already admitted public record map.
New data must be supplied by the relay; private raw presence is insufficient.
A controlled TLS regression advertises an omitted blob that exists in Bob's
private capture and verifies unavailable receipt, unchanged root/history/files and
continued relay absence of those bytes. No pre-fix exploit run was performed;
the regression directly exercises the identified cache-match condition. Metadata
pages retain separate scoped verification. Unadmitted data may be fetched again
after interruption rather than claiming durable public provenance from raw cache.

The main TLS case uses separately enrolled Alice/Bob devices, fresh CLI JSON/plain
share/exchange/integrate processes, CRLF text, 300731-byte binary data, executable,
symlink and empty directory. Actual relay object bytes exclude both Alice's
unselected sentinel and Bob's later private E. Receipt changes neither files nor
private history/counter; Bob accepts D while retaining E and exchanges accepted
history back. A fork stops after the real HTTPS courier PUT before local ack;
a fresh CLI without its signer retries the same courier ID. `Local.initialize_received`
provides Bob's verified empty private basis without signing another genesis.
This fixture is library bootstrap, not ordinary clone evidence. Signers remain
disposable explicit test capabilities, not native custody onboarding.

Core-package15, full transport23 (including the two native TLS cases), signed
local-core69, store8, snapshot-materialization3, transfer8, GC11 and branch CLI17/
share CLI8/integration CLI8 passed. The independent generator verifies five
manifest/hash/courier vectors. `make build`, `make lint` and default `make ci`
exited 0 on parent `b78afa5` with the exact pending files committed as `10210f5`;
CI took 54.376 seconds and reused matching unchanged Dune actions where applicable.
Exact commands, exits, durations and file hashes are in
`core-native-exchange-checkpoint-checks.json` under the P3 external log directory.
Earlier focused filters intentionally skipped other cases; full 15/23-case runs
and CI executed all those cases. Initial strict-warning/fixture-scope failures,
an independent-generator assertion and formatter promotions (exit 2) were
corrected before complete passing verification. README, P2 report/receipt and
accepted G01 hashes match the start receipt; original P3 prerequisite ancestry
was rechecked. No accepted measurements were rerun.

This adds partial G02 private-schema, G03 enrolled-member boundary, G08 real native
exchange/provenance, G13 real acknowledgement and G14 ordinary exchange coverage.
No whole original phase is complete. Native clone with pinned identity and
recoverable first materialization, switching known-only branches, native conflict
resolution, read-only missing-content inspection, broader native failure/authority/
coverage checks and the full P3 criterion audit remain required. Error-category
mapping also needs its final malformed/signature/authority matrix. Local decoding
still requires complete public composition contents; do not turn an unverified
metadata declaration or local flag into an accepted-result proof. Preserve all
current operation/recovery roots while implementing those consumers.

Rollback must preserve schema-3 transport/schema-4 local data and public catalogue
pages; old binaries cannot decode new catalogue-bearing state. Source rollback
cannot retract relay bytes/acknowledgements, restore working files or undo accepted
history. No push/release/deployment, P4 work, native human/performance qualification
or P03 completion report/receipt is claimed. P3 remains active and incomplete.

P3 native clone checkpoint:
`94e08c0d3ad990dd52a642ca55390bcdb397d9d0`,
`766bc88a32bf703553746964b7abf5057d30d640`,
`01a54f728fa4484fede320dca7cdb914cfda7ec3` and
`37311de153d7e9fb91321c99f44ec3f5c300ec73` appeared as external `newthings`
snapshots of this continuation's owned clone-intent, scoped-credential, fetch and
target-check prerequisites and then-unverified service. Inspected/preserved without
reset/amend. Final verified implementation is
`1105c60c8e724b9e49abf9f021b890207f4844e5`.

`clone https://RELAY/v1/repositories/REPOSITORY [DIRECTORY]` now verifies repository,
root phrase, current enrolled device, unique branch/accepted/event selection and
complete advertised public closure before initialization. Generated directory/
private member/draft/workspace identities avoid manual internal record creation.
Preview creates no destination/history/operation or saved credential; its source
request ID can bind the actual command. Tokens use exact endpoint/repository custody,
an interactive text prompt or explicit bounded standard input. Native exchange no
longer falls back to equal remote aliases from another workspace; existing users
with alias-only credentials must log in again. A bearer cannot enroll a device.

Actual clone copies only verified public artifact IDs into fresh private empty
history, attaches fully initialized metadata by exclusive native rename, binds an
immutable local plan, and uses actual safe integration to select known accepted
contents without signing another genesis/acceptance. Schema-4 private transport
intent freezes source/root/device/branch/accepted/event selection; root update
guards refuse erasure, retargeting of a started operation and completion reversal.
Ordinary capture is blocked until completion or explicit recovery. Resume after
attachment is local and uses no signing provider. Recovered operations stay closed.
Plan cleanup now follows durable clone completion: the first TLS test exposed an
early-release refusal after successful application, corrected without weakening
the pending-plan guard. Late disk edits survive Materialized resume and remain
reported as uncaptured work. CLI JSON/plain help/actions and actual APIs/schemas
are documented in COLLABORATION.md and INTERFACES.md.

Review also found that per-packet bounds alone allowed excessive accumulated
courier metadata. Native fetch now caps total canonical courier bytes by the
shared 16 MiB control bound and stops fetching after overflow. Clone checks the
growing catalogue's full encoded bound before fetching package contents, before
destination creation. Focused tests exercise exact aggregate fit, early refusal
and skipping known IDs. Independent Python vectors cover clone schema 4 and its
domain-separated request digest; all seven package/hash/courier/clone vectors pass.

The TLS clone test runs fresh JSON/plain CLI processes on separately enrolled
Alice/Bob test devices: accepted mixed CRLF/binary/executable/symlink/empty-directory
contents, excluded private sentinel, wrong root, unenrolled signer, read-only
preview, stale request, clone, exact repeat and configured-origin exchange. Forks
stop at actual metadata attachment, before/after plan binding, Prepared, Applying,
file mutation, Materialized, Committed, Completed and before/after clone-completion
publication. Fresh CLI resumes without Bob's signer; checks preserve operation
identity, one navigation, public records and a post-materialization external edit.
The cloned workspace subsequently receives Alice's explicit immutable update
without files/history movement, previews, accepts D while retaining Bob's private
E, and exchanges accepted history back. This is automated main-branch evidence
with disposable explicit capabilities, not native custody/human qualification.
Nondefault clone selection and additional refusal/recovery combinations still
belong in the remaining P3 audit.

Focused local-core69, safe-application22, V1-store6, Core-package15, GC11 and
service45 passed, followed by seven focused transport control cases (other cases
intentionally skipped). Full transport25 passed before the aggregate-bound
addition; final CI ran all26 transport cases with no reported skips. Final
`make build`, `make lint`, `make ci` exited 0 against the exact stable source later
committed as `1105c60`; CI took 239.855 seconds and reused matching unchanged Dune
actions. `core-clone-stable-checks.json` in the external P3 log directory records
commands/exits/durations/file SHA-256 and `source_stable: true`. Earlier passing
checks were superseded by later hardening (`core-clone-final-checks.json` correctly
records unstable source); they are not final revision evidence. Initial CLI type/
test syntax errors, the cleanup failure and formatter promotions were corrected.
One concurrent Dune build request refused because the active server was not in
watch mode; serialized rebuilding passed. Documentation links and independent
generation passed. README/P2 evidence/accepted G01 hashes still match start.json;
no accepted measurement or external benchmark artifact was recreated.

Partial original-phase coverage: G02 adds a bounded private control schema and
documented APIs; G03 adds the clone root/enrolled-member refusal boundary; G04/G13
reuse exact plan/application facts for first selection and real acknowledgement;
G08/G14 add native verified clone and a cloned-peer update loop. No whole original
phase is complete. Required P3 continuation: support first switching of known-only
branches and stale saved branch bases, implement real conflicts/resolve with exact
text/opaque choices/replacements/deferral, provide truthful read-only inspection
when admitted contents are unavailable, finish malformed/signature/authority/exit
classification and refusal/fault/GC coverage, then audit every criterion and write
P03 report/acceptance evidence separately. Do not start P4 or full G02-G20.

Rollback must preserve schema-4 transport clone intent, plans, operation/safety
roots, working files and scoped credentials. Old transport readers refuse the new
intent. Reverting binaries cannot undo files/history/remote acknowledgements.
Pre-attachment interruption can leave an empty destination and sibling staging;
rerun the original command because no workspace was activated. Cross-filesystem
metadata attachment refuses without a replacement/copy fallback. Preserve
unexpected staging contents. No native macOS/Windows, Docker, custody onboarding,
human usability, managed service/backup, push/release/deployment or P3 completion
is claimed. P3 remains active and incomplete.

P3 received-branch checkpoint:
`bc75d492af15bb8e83bd863d7aceaef370a54c35`, parent ledger
`a27ded4e47ea438c5bf54a419bc129c23818d839`, completes supported first selection
of a received branch through the existing private history/state root and
schema-5 local selection journal. `Local.selection_target` distinguishes a saved
private position from a verified accepted target. `register_position` validates
the exact accepted result against its staged history node. Source safety capture,
target retention, history allocation and new position publish together before
ordinary-file mutation; selection moves only after materialization. Preview marks
unallocated identities provisional and changes no history/position. No schema,
envelope code, parallel mutable store or second shared genesis is added.

Saved positions retain their historical working basis when newer shared heads
arrive; switch restores the private alternative before explicit integration.
JSON/plain output distinguishes that basis, known heads, new private registration
and provisional history. Frozen journal resume keeps the original basis even when
equal-content accepted history arrives later. Fresh ambiguous names/divergent heads
still refuse. Branch creation now forks the working basis, not a newer received
head that has not been selected into this private lineage. Signing providers run
outside the writer lock; publication rechecks the state head and complete source
contents. A new regression first reproduced the old held-lock behavior, then
verified lock availability and refusal/preservation for provider-time edits/saves.

Tests exercise actual first-selection safety publication, Prepared/Applying/file/
Materialized/metadata/Published boundaries, exact retry, stale preview, ignored
obstructions, pure/idempotent position staging, equal-content different-node refusal,
GC, late external edits and restoration of both private alternatives. Newer shared
contents catch up through ordinary verified integration without another signature
or duplicate acceptance. The controlled TLS CLI journey uses separately enrolled
Alice/Bob fixtures, sends a real named branch, receives without private history movement, previews
and selects it without Bob's signer, restores main's private work, explicitly catches
up and exchanges. A third workspace clones the nondefault branch with a different
workspace namespace and no Alice/Bob private sentinel. The earlier clone test's
namespace assertion now compares actual workspace IDs, not unequal history sequences.

Final focused local-core77, Core-package15, safe-application22, GC11, Python
branch-CLI17, real TLS branch case and all seven independent vectors passed.
The targeted TLS/provider runs intentionally skipped other cases; final CI ran all
27 transport cases with no reported skips. `make build`, `make lint`, `make ci`
exited 0 on the exact stable source committed as `bc75d49`; CI took 230.871 seconds
and reused matching unchanged Dune actions. Exact commands, exits, timings and
owned-file hashes are in `shared-switch-checkpoint-checks.json` in the external P3
log directory, with `source_stable: true`. Initial strict docstring/fragile-match,
test syntax/shadowing failures and formatter promotions were corrected before
complete verification. Documentation links pass (247 local references). README,
P2 evidence and accepted G01 hashes remain unchanged; no measurements were rerun.

The local tracking reflog advanced origin/main from `37311de` to `a27ded4` with
`update by push` while this continuation worked. This writer issued no push and
preserved the refs; no source edits from another writer were observed in this
checkpoint. The implementation commit followed on main with explicitly staged
owned files. No agents/worktrees/branches, release or deployment were used.

This adds partial G03/G08/G14 branch/workspace coverage and G04/G13 exact private
selection/recovery coverage; all original full-phase remainders remain. P3 still
requires real text/opaque conflicts/resolve with exact choices/replacements and
deferral, truthful read-only metadata inspection when admitted contents are missing,
the remaining signature/authority/exit/refusal/fault matrix, and full criterion audit
with P03 report/compact acceptance receipt. Keep unsupported required policy and
adoption explicit. Do not start P4 or generate a new goal prompt.

Rollback must preserve registered private positions, source/target history nodes,
journals, proofs, physical staging and working files. A safety-root interruption
before Prepared can leave an unselected saved target with no file replacement;
fresh retry reuses it. Old binaries may refuse saved branches behind their known
head; rolling back code is not recovery of files/history or remote state. Native
custody/human/cross-OS qualification and broad performance evaluation remain
unclaimed. P3 remains active and incomplete.

P3 saved-metadata inspection checkpoint:
`07ead3a737996ee726d160590adf02766538b3c2`, parent handoff
`0c50f95f959d1e7ac260a75472a9df5578949f96`. This continuation resumed the same
writer's uncommitted metadata work on main; no unrelated edits were observed.
HEAD, branch and the original P3 prerequisite ancestry were checked before
continuing. Origin/main remained at `a27ded4` during this checkpoint; this writer
issued no push, created no agents/branches/worktrees and performed no deployment.

`Local.Metadata.t` is a separate abstract type for canonical control, historical
signature/repository/reference checks and private-position ancestry. It cannot
be converted to a writable `Local.t`. `Store.inspection` returns either fully
verified state or separately typed metadata plus the actual failed proof.
`inspect_repository ~root` opens raw layout/format for inspection without returning
a writable V1 repository. All existing writable open/load/previous-root/save paths
still require public composition, private correspondence and operation validation.
TC06's 8 MiB local control bound is enforced before decoding/after encoding; no
ordered schema, envelope code, immutable identity or mutable root is replaced.

CLI `status`/`history` now retain actual identities, signed head declarations,
private history topology and per-snapshot availability when public contents are
missing/corrupt. Schema-2 domain JSON/plain output reports missing public contents
as exit 5, corrupt/false accepted-result proof as exit 6, with unverified state.
Status does not capture working files; live differences, private receipt/operation,
transfer and recovery state stay unknown. No write/recovery action is suggested
from an unverified state, and no repair from working bytes or public-cache admission
is inferred from metadata. Plain failures escape terminal controls in native paths.

Tests remove a real chunk from a multi-chunk accepted binary, inspect from fresh
CLI processes, exercise missing and corrupt cases, restore exact immutable data,
and verify strict writer refusal, root/history preservation, ordinary bytes and
refusal of implicit corrupt-object replacement. A separate test installs a validly
signed false accepted claim in a temporary state root: declarations remain readable,
composition stays invalid and CLI save refuses. Bad signatures, missing controls,
swapped logical/stored mappings, duplicate references, unsupported control versions
and oversized inputs do not become authenticated metadata. The fresh-process test
first found that the V1 opener rejected state before the inspection path; the new
read-only opener corrects that boundary without weakening the writable opener.

Final focused local-core78, V1-store6, service45, Core-package15, Python inspection9
and branch17 passed. `make build`, `make lint`, `make ci` exited 0 on the exact
stable source committed as `07ead3a`; CI took 189.535 seconds and ran all27 transport
cases with no reported skips. Matching unchanged Dune actions were reused. Exact
commands, exits, timings and owned-file SHA-256 are in
`metadata-view-stable-checks.json` under
`/home/gongahkia/.cache/yeokcham-p3-20261115/`, with `source_stable: true`.
Earlier `metadata-view-checkpoint-checks.json` records all passing commands but
`source_stable: false` because terminal escaping/tests were hardened during that
run; it is superseded, not final revision evidence. Initial build/strict-warning
and fresh-CLI failures were corrected; formatter promotions were followed by a
clean format check and full verification. Documentation links passed (247 local
references). README/P2 evidence/all accepted G01 hashes match all12 preservation
entries in start.json; no measurements or missing benchmark artifacts were recreated.

This adds partial G02 bounded control/API documentation, G08 truthful unavailable
public-state inspection and G14 domain CLI coverage. No whole original phase or
P3 criterion is closed solely by this checkpoint. Private-control loaders still
expose string errors, conservatively classified unverified/integrity; native
exchange still requires complete existing state and does not repair an already
incomplete root. These limits remain explicit for the P3 availability/error audit.
Native Docker/macOS/Windows, custody onboarding, human usability and broad
performance qualification were not run or claimed here.

Required P3 continuation: implement actual native `conflicts`/`resolve` with named
exact versions, text/opaque replacement/selection and safe deferral, binding every
superseded variant and preparing a fresh exact plan without silent acceptance or
private publication. Reuse the canonical registry/model/Graph/plan/operation/public
closure boundaries; do not disable the unsupported-resolution gate before real
semantics and proof exist. Complete the authority/policy/adoption/exit and remaining
availability/refusal/fault/GC audit; extend the real Alice/Bob TLS journey through
explicit resolutions and all-head reconciliation. Then audit every original scoped
P3 criterion, verify final build/lint/CI and write P03 report/compact acceptance
evidence separately. P4 and independent full phases remain unauthorized.

Rollback preserves current roots/history, private recovery material and working
files. This checkpoint adds no data migration or schema; reverting loses the new
inspection path and control bound, not an acceptance or file operation. Existing
overlarge local controls now refuse explicitly without erasing data; incremental
index/history replacement remains outside this change. Metadata inspection is not
permission to replace corrupt objects or bypass failed full proofs. P3 remains
active and incomplete.

P3 public resolution proof/application checkpoint:
`36759aa6150abb2d4b84c75a997a3c9a323e3609`, parent handoff
`e8343cb2f15e3754a3cb5e738f9257c5ccc06da5`. Work started from clean main and
rechecked the original P3 prerequisite ancestry/toolchain. No unrelated edits,
agents, branches/worktrees, push, release or deployment were introduced. The
full P3 task remains active; this is an implementation prerequisite, not scoped
completion or an ordinary conflict-resolution CLI journey.

TC06 previously named resolution IDs but omitted their native payload. The
schema-owner amendment adds `Core.resolution_revision`, envelope code47 in the
existing registry, seven ordered fields, its own signing domain, bounded canonical
decoding and complete-envelope identity. Exact branch/accepted heads/chosen roots
and complete superseded dependency/previous variants bind the decision; body
parents equal that variant set. A single scope path and exact comparison/replacement
snapshots prevent unrelated private differences. Python CBOR/OpenSSL body,
signing-input/envelope/identity vectors are committed before downstream CLI work;
codes/bytes 1–46 and the existing three core vector families remain unchanged.

`Graph.compose ?resolutions` proves the unique recorded common accepted base,
exact context and replacement confinement, derives actual conflicts, masks only
explicitly decided paths through ordinary composition, then installs exact
replacement subtrees. Automatic changes elsewhere survive; partial choices retain
remaining conflicts. Stale, unused, overlapping, missing-variant and out-of-scope
choices refuse. Dependencies hidden below chosen roots are explicitly named in
the variant set. Ambiguous common bases remain decisions; concurrent unchanged
change variants require exact revision selection. Standalone proposals prove
declaration/base/scope only; accepted records must pass the complete actual-result
proof. Resolution IDs are distinct from represented shared-revision ancestry.

`Integration.prepare_resolved` and `Service.Integrate.prepare_resolved` consume
authenticated proposals in the existing Local pool. Plan46 already binds resolution
IDs, so no new plan schema or parallel mutable store is added. Revalidation retains
the exact list. `Local.prepare_acceptance ?resolutions` and native execution prove
and sign those choices through the existing application engine. Operation control
parsing now bounds the list and requires exact agreement with its staged accepted
record. The first native test exposed the old empty-list journal guard; replacing
that guard with typed parsing plus actual candidate-graph proof enabled real
application without a placeholder success path. Public packages include both
resolution snapshots/scope and verify actual accepted results in isolation.
Shared GC roots include both snapshots; other new control-type consumers handle
the kind explicitly without treating it as a local undo node or shared change.

Tests cover exact context/reference kinds, missing/duplicate/superseded variants,
wrong scope/version/envelope/signatures, canonical mutations across all four
families, false accepted results, unrelated private leakage, stale/unused/overlap
refusal, partial decisions, dependency conflicts, receipt/input permutations,
concurrent accepted heads, text/CRLF, absence, large opaque data, directories,
executable files and symlinks. The native adapter applies signed resolutions,
preserves private E and retries without another signer/root/history allocation.
Actual Prepared/file/Materialized/Committed interruptions resume the same decision.
The mixed-file public-package D/E journey now includes a signed resolution and
keeps all existing private-sentinel/witness/plan exclusions. A new actual GC case
retains an unaccepted multi-chunk replacement before any integration plan protects
it, verifies its complete bytes after quarantine collection, then materializes it.

Focused model10, record6 (four independent vector families plus expanded mutation
property), trust3, graph13, local-core80, Core-package15 and GC11 passed before the
final GC case. Initial compiler/exhaustive/strict-warning errors and one incorrect
test setup were corrected; formatter promotions were followed by clean lint.
The first aggregate verification process exited143 during CI; make/Dune were
absent and its orphaned relay child was identified by sandbox/output and stopped.
The termination cause is unverified. A separate `make ci` passed all27 transport
cases (suite247.796s), with no reported skips. After adding the GC case, final
focused build, that case, `make build`, `make lint`, `make ci` all exited0 on the
exact stable source committed as `36759aa`. Final CI took65.782s, ran all81 local
cases and reused matching other Dune actions, including transport. The targeted
GC run intentionally skipped the other80 cases; final CI reported no skips.
Documentation links passed (247 local references). Exact commands/exits/timings
and all34 owned-file SHA-256 values, including new golden files, are in
`resolution-proof-stable-checks.json` under
`/home/gongahkia/.cache/yeokcham-p3-20261115/`, with `source_stable: true`.
Earlier per-check evidence and the interrupted attempt are retained separately.
All12 README/P2/accepted-G01 preservation hashes still match start.json; no
accepted measurements or absent benchmark artifacts were recreated. No native
Docker/macOS/Windows, custody onboarding, human or broad performance qualification
was run or claimed.

This adds partial G02 resolution records/interfaces, G04 exact public composition
proof, G08 verified public closure and G13 native resolved application/GC evidence.
All original full-phase remainders remain. Required next implementation is the
actual native `conflicts`/`resolve` service/CLI: named exact versions, replacement
file capture, safe deferral, fresh retained plans and private workspace choices.
Do not substitute the earlier V1 `resolve --decision` commands or these library
fixtures for that user journey. Preserve signing outside writer locks, current
trust admission, exact context, unchanged files/history during resolution and
explicit publication scope. Extend real Alice/Bob TLS exchanges through those
commands, then finish the authority/policy/availability/exit/fault audit and the
full P03 report/compact acceptance evidence. P4 remains unstarted/unauthorized.

Rollback must preserve code47 records, their snapshots/scopes, plans, operation
facts, history/recovery roots and working files. Older binaries cannot decode
the new kind and may refuse the state; source reversion cannot undo acceptance,
materialization or exchange. No obsolete-format migration or destructive repair
is introduced. A standalone resolution proposal is not an accepted result or
permission to replace private work. P3 remains active and incomplete.

### P3 native conflict choices and private result checkpoint — November 15

Continuation on main at `548df679a9579fc1d513c9d3826ee14d90a6a8d3` preserved the
eleven modified files inherited from the private-decision implementation. P1/P2
prerequisite ancestry remained verified. Implementation is now committed as
`51a63028250fa987ff870d959294347e0e3ee593`, with 28 explicitly staged owned files.
No branch/worktree, agent, push, release or deployment was used.

`Service.Conflicts` now backs actual native `conflicts` and `resolve CONFLICT`
commands, preserving the explicit earlier `resolve --decision` path. Inspection
exposes exact plan/conflict IDs, shared/private scope, named versions, entry/type/
mode/content identities and bounded escaped previews. Deferral changes no state.
Shared choices record only a scoped signed resolution proposal and prepare a
fresh plan; private choices remain private plan data with no signer/public record.
Neither action accepts work, advances the private cursor or rewrites files.
Signing releases the existing writer, then revalidates source, file identity,
authority and exact context before publication. Identical recorded choices reuse
their signed identity. A post-publication alias-retention failure reports its
actual resolution/plan/source identities and incomplete outcome with retry action.
Incomparable decision alternatives stay explicit rather than using arrival order.

Private plan schema 2 appends a canonical nonempty sorted path/replacement set to
the existing fields; schema 1 bytes are unchanged. No envelope code was added.
The plan and incomplete operation protect replacement roots and verify the actual
private merge, keeping accepted D separate from selected private E. Canonical
decoding rejects malformed/duplicate/unsorted/overlapping decisions and unsupported
versions. Native application refuses a syntactically Ready false output before
files/root movement. Nested choices now admit only necessary directory ancestors,
while refusing unrelated changes and undecided ancestor-file replacement.
Explicit replacement capture reuses native streaming/chunking, executable mode,
file fingerprints and three bounded instability attempts; final symlinks and
special files refuse. Provider-time external/source changes preserve existing
state. Actual private-choice Prepared/file/Materialized/Committed interruptions
resume without another acceptance/navigation; discarded private E stays in safety.

Focused checks passed: all85 local-state cases, all14 graph cases, one owner-vector
case covering both schemas, four independently emitted encoding/identity fixtures,
and all11 fresh-process integration CLI cases (JSON/plain). CLI journeys cover
deferral, exact named choices, signer-free identity reuse, accepted D/private E,
large executable replacements, stale inputs and unknown versions. The new large
replacement case exceeded the old20s per-command test bound; its bounded120s
invocation passed, and the final11-case CLI run took26.848s. This is correctness
evidence, not a responsiveness budget or representative performance qualification.

The first full local run caught an unintended schema-1 recovery regression: the
new pending workspace proof also required older plans' safety contents during
root loading. Limiting the added proof to nonempty explicit private decisions
preserved schema-1 recovery behavior; its missing-safety case and the four new
cases then passed together. Earlier compile/strict-warning errors, a wrong JSON
test-field assertion, the native error-schema defect and timeout are retained in
external logs. No existing recovery test was weakened. The initial formatter
promotion exited2; the final formatter, build and lint exited0.

Final `make build`, `make lint`, `make ci` all exited0 on the exact committed
source. Full CI took195.512s, ran all27 existing native transport cases through
the real controlled TLS relay (suite193.222s), all85 local cases and the new CLI/
vector checks, and reused matching unchanged Dune actions. No skips were reported
by final CI; earlier targeted invocations deliberately skipped unrelated cases.
Documentation links passed (247 local references). Exact commands/exits/timings,
all28 SHA-256 values and a committed-source comparison are in
`native-conflicts-stable-checks.json` under
`/home/gongahkia/.cache/yeokcham-p3-20261115/`; `source_stable` and
`committed_source_matches` are true. The failed local attempt remains in
`native-conflicts-check-attempt-01.json` and its logs. All12 README/P2/accepted-G01
preservation hashes still match start.json. Accepted measurements were not rerun
or missing benchmark directories recreated. Default CI's synthetic harness tests
are distinct from accepted G01 measurements. No Docker/macOS/Windows, native custody,
human or broad performance qualification was performed or claimed.

This adds partial G02 private plan/consumer contracts, G04 actual private decisions,
G05 bounded replacement capture, G13 resolved native application and G14 supported
conflict CLI journeys. It does not complete any original full phase. P3 remains
active and incomplete. Next extend the actual Alice/Bob TLS journey through native
conflicts/resolve, receipt without file movement, private E, accepted-history
exchange, privacy and exact retry. Complete the authority/policy/availability/exit
and fault audit, including shared-resolution root-to-alias failure/retry, remaining
decision cases and private replacement GC/closed-metadata behavior. Then audit all
seven P3 criteria and write the full P03 report/acceptance receipt. Those files are
not yet created. P4 remains unstarted and unauthorized. The external
`native-conflicts-next-notes.md` records the concrete continuation and test helpers.

Rollback must retain schema-2 plans, their private replacements, operation facts,
history/safety/recovery roots and all working bytes, as well as existing public
code47 records. Earlier readers may refuse these new private plan controls;
reverting source cannot undo accepted history, materialization or exchange.
Do not delete metadata or roots to make an older reader succeed. D10 introduces
no destructive current-data migration or recovery exception.


## P3 completion — November 16, 2026

P3 is complete under its scoped task. Final implementation is
`2fe8b32e2014ee8f29d36ee2baafbc93d7176553`; the
[report](implementation/reports/P03-attempt-01.md) and
[compact receipt](implementation/results/P03-acceptance.json) audit all seven
criteria, 37 implementation commits, external snapshots, exact source/commands,
rollback/data implications and the complete changed-path inventory. Earlier P3
checkpoint continuation notes above are historical and superseded by this closeout.

The final TLS journey covers native enrolled clone, independent updates of the
same change, exact text/opaque decisions, private E, accepted exchange and
provider-free private catch-up. It now continues through another explicit update
after acceptance of all competing revisions. A shared accepted-base predicate
proves all old heads are represented; neither an unresolved fork nor one accepted
side can stand in for reconciliation. The successor names all old heads and its
recorded retry adds no revision/history. The other member's receipt changes no
ordinary files or private cursor.

`c1f8032523069d4007f940e96e2cbe4bd90d68aa` externally snapshotted the requested-branch
priority, precise HTTP/integrity/pending outcomes, actual TLS resolution journey
and private replacement GC tests. It was inspected and preserved; this agent did
not push it. `971bc2dd531549094811adcac8f3b4dbb0aca369` adds retry using a stored
`resolution:ID` after plan-alias failure, even when the original replacement file
is gone. Partial failure is `ok=false`/interrupted/exit 8. Final `2fe8b32` connects
accepted reconciliation to share/graph/private-receipt proof and its regression
journey. No source rollback, new branch/worktree or additional agent was used.

Final `make build`, `make lint` and `make ci` pass on an immutable source snapshot
whose every tracked hash matches `2fe8b32` before documentation-only closeout.
CI freshly reports 25 OCaml suites/353 cases and 81 Python cases without reported
skips; unaffected matching Dune actions are cached. It includes 86 local-state,
15 Core package and all 30 transport cases. Focused final graph15/share8/
integration14/recovery5 checks and five independent Python vector generators pass;
those counts overlap CI and are not additive unique totals. All 12 README/P2/G01
preservation hashes match. G01 measurements were not rerun or recreated; CI's
existing small synthetic harness fixture is distinct from the accepted baseline.
The new regression initially reproduced the graph refusal, then its TLS extension
found the independent receipt guard; both now pass without weakened validation.
Formatter promotion/strict-warning failures were corrected before final checks.

| Original criteria | P3 coverage | Remaining owner/scope |
| --- | --- | --- |
| G02 C1-C5 | Core revision/accepted/branch/resolution records, scope/page/plan contracts and vectors; durable pilot identities/consumers. | Request/principal/member/policy/review/account/settings/archive families, principal proof and remaining consumer contracts/vectors; original phase stays partial. |
| G03 C1 | Existing enrolled-device trust and current authority reused. | Principal-key proof and stable independent-reviewer binding. |
| G03 C2 | Causal branch/accepted heads, explicit all-head reconciliation, equal-content histories and current admission. | Full policy-fork evaluation, authority reconciliation/adoption workflows. |
| G03 C3-C5 | Unsupported required policy/evidence/adoption refuses; unknown/revoked authority and receipt permutations tested. | Independent approval defaults, exact coverage/preferences, reviewer supersession/withdrawals/blocks/dismissals and full matrix. |
| G04 C1-C5 | TC06 profile, actual graph/base/scope/dependency proof, exact plans, separate D/E, ambiguity decisions, golden/property/side-effect/stale tests. | Full G03 policy/review evidence evaluator and original predecessor/phase acceptance. |
| G08 C1 | Core revisions/branches/accepted/resolutions and verified closure through real bounded HTTPS ranges. | Full policy/review record families and original-phase dependencies. |
| G08 C2-C3 | Durable frozen outgoing/ack and exact retries; requested version prioritized before all other advertised shared branches/history. | Configured narrower scopes and full-scale qualification. |
| G08 C4-C5 | Current trust, preserved incomparable heads/private cursor/files, actual received-branch offline selection and availability/fault/receipt tests. | Full adoption/policy behavior, repair of already incomplete local state and wider qualification. |
| G13 C1-C6 | Native no-review pilot acceptance/private preservation, actual safe journal phases and root publication, offline/idempotent recovery and native conflict/operation CLI; no mandatory deliver. | Full G12 required/advisory review integration, broader platform/fault qualification and original prerequisite/phase acceptance. |
| G14 C1-C6 | P2 local journeys plus native shared clone/share/update/exchange/integrate/conflicts/recovery; domain JSON/plain/confirmation/actions/exits; honest service/backup state. | Archive/preferences/full-review vocabulary, managed services and native custody/human qualification; original phase remains pending. |

No required P3 verification remains missing. Optional container targets were not
executed because this user cannot read the Docker socket. Actual native local
TLS tests passed using explicit disposable signing capabilities. Native custody
onboarding, representative projects/human feedback, broader responsiveness and
other-OS/power-loss qualification remain P4/original-phase gates; no such pass is
claimed. Automatic repair of an already incomplete admitted local store is
unsupported; saved metadata inspection diagnoses it and strict writers refuse.
Private-control loaders without typed unavailable distinctions conservatively
report unverified/integrity. No private backup or managed service success claim.

Original full-design completion stays 1/20 (G01). Pilot P0/P1/P2/P3 are complete;
P4 is next eligible and unstarted, requiring a separate invocation. No next goal
prompt, P4 work, independent full phase, release or deployment was generated.
Preserve current roots/history, journals/proofs, replacement/safety/displaced
contents and an appropriate reader: source reversion does not undo accepted
history, remote publication or ordinary-file writes. Report/ledger/evidence are
committed separately from implementation. Full rollback review order and exact
format/data implications are in the report and receipt.


## Compact local CLI dogfooding follow-up — November 16, 2026

The user completed the initial local init/edit/save/history/undo/redo journey and
reported that the text output exposed too many IDs, hashes and implementation
fields. This bounded follow-up implements progressive detail for those local
views and supplied an interactive HTML prototype (subsequently removed in
`fba3daa945eb2c670595ab660576be30b8b3d380`).
The implementation is `8693ff36dc7d27230df3d1b6cdaa745442719115`; the external
`8ae801e52f8b73dfa97d833414138b136d32153c` snapshot captured earlier partial work
and was inspected/preserved. No amend/reset/push or additional agent was used.

Ordinary output now leads with the outcome, branch/local version and affected
paths; save is one confirmation line. History keeps short selectable numbers,
current position, parent/alternative links and availability. Navigation hides
proof/snapshot internals unless `--details` is requested. Exact recovery actions
still identify a blocked operation. JSON data and domain/storage/trust semantics
remain unchanged. Native initialization still shows recovery words once; the
public verification phrase is available later through `device show`. ANSI/TTY/
NO_COLOR behavior and ASCII fallbacks are tested, including real pseudo-terminals.

All final build/lint/CI/doc checks pass on a stable hashed source snapshot.
Focused checks passed presentation9, specification4, CLI28, inspection9 and
selection16 cases; branch17 passed after replacing obsolete init-copy assertions.
The preceding CI run passed all 30 real TLS transport and 86 local-state cases;
its only failed target was that old branch wording. Final CI reused successful
matching Dune results and passed after the test-copy correction. Earlier compile,
formatter-promotion, symlink wording and missing-fish-PATH failures are retained
in external logs and were resolved without weaker safety/data assertions.

The prototype's six scenes, three controls and 320/375/1100-pixel layouts passed
headless Chromium checks without console errors or horizontal overflow. The
three updated container/artifact shell scripts passed syntax checks; actual
container execution remains unavailable because this user cannot read the Docker
socket. All 14 README/P1/P2/P3/G01 preservation hashes match. No accepted G01
measurement or artifact directory was recreated. Evidence lives under
`/home/gongahkia/.cache/yeokcham-cli-ui-20261116/`; the compact committed
[receipt](implementation/results/cli-presentation-20261116.json) records commands,
exits, log/source hashes, cached results and rollback order.

This is actual first-use presentation feedback and a scoped fix. It does not
close P4's native onboarding, representative participant/project, responsiveness
or broader qualification gates, and closes no original full-design phase.
README and all current recovery roots/user files remain outside this change.
Whole-slice source rollback requires reviewing `8693ff3` and the earlier external
`8ae801e`; no durable data formats changed. No live user-demo navigation, push,
release, deployment or full P4 execution was performed by this agent.
