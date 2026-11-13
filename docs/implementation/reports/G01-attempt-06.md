# Yeokcham implementation report: G01 — capture and no-op complete

- Attempt: 06
- Status: in_progress; live small-edit measurements, no current blocker.
- Branch: main; starting commit `65245d5d6c7ae1696208ca281b1e4f7e90162638`.
- Design baseline: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`.
- Predecessor: `docs/implementation/reports/G01-attempt-05.md`; its handoff and
  listed implementation/evidence commits remain ancestors.
- Platform: Fedora 44/WSL2, ext4 virtual disk, i7-1355U, 12 logical CPUs,
  5,155,467,264 bytes RAM; OCaml 5.5.0, Dune 3.24.2,
  ocamlformat 0.29.0, Python 3.14.8.
- Report: `docs/implementation/reports/G01-attempt-06.md`.

## Delivered behavior

The existing session `79434` / PID `154851` completed all 100-MiB no-op samples:
5 cold / 3 excluded warmups / 30 warm, each accepted after restoration checks.
The 10-MiB tier and 100-MiB capture group remain complete. At November 14,
00:34:13 SGT, 210/280 measured records and 18/24 excluded warmups were accepted;
no failures were recorded. Small-edit and undo/restore remain for 100 MiB.

At the user's request, all accepted metrics are now backed up in the versioned
`docs/implementation/results/G01-measurement-checkpoint.json`. It preserves every
sample metric/command, hashes, machine/settings and continuation boundaries in
64,212 bytes, tagged `in_progress`. The guide documents read-before-resume,
retention and exact checkpoint export. This turn made evidence/documentation
progress and verified waits; no runtime or harness Python code changed.

## Acceptance evidence

| G01 criterion | Evidence | Result |
| --- | --- | --- |
| 1. Environment/build/lint/CI | Prior environment/resumption evidence; tested code unchanged | passed |
| 2. Deterministic configurable fixtures/runner | Existing generator/runner, twelve focused checks and checked resumption | passed |
| 3. Both tiers and all selected samples | 10 MiB complete; 100-MiB capture/no-op complete, small-edit/undo outstanding | not met yet |
| 4. Small full baseline summary, commands and hashes | Versioned partial checkpoint preserves progress; full summary/budgets still pending | not met yet |
| 5. Unmodified pinned export and later coverage gates | Same pinned executable/generator and verified retained checkpoints; later gates open | passed |

## Verification

- Repeated polls of session `79434` and `ps`: live; elapsed 4h21m03s at checkpoint.
- Independent no-op audit: exact 5/3/30 groups and unique indices; finite metrics;
  allocation sums; every restored tree matches independently reconstructed node 9,
  SHA-256 `84b296bba811fa01b5b4a1c6a10e41d2ee4e86076dd1c2d917c8f6fcc68aa827`.
- Checkpoint audit reconstructed every raw sample field and command exactly,
  verified external input hashes, and proved the earlier 207 committed records
  remain unchanged within the new 228-record prefix.
- Committed checkpoint SHA-256:
  `a67a6ec0fd3ca5aafefee01f6240e6d7273ffdf2245123d22bc885c8fffca242`.
  Inputs: external `checkpoints/documentation-1794587653220760875`.
- External audit: `/home/gongahkia/.cache/yeokcham-g01/checkpoints/attempt-06.json`,
  SHA-256 `b242e37b44c1cdb6cef1b75704689cc03caa07eab59c1c72778370c9424dc854`.
- `make docs-check` and `git diff --check`: passed. Prior build/lint/CI/focused
  checks remain valid; this turn changed only documentation/evidence.

Completed 100-MiB operations, seconds; warmups excluded:

| Operation | Cold median / range | Warm median / p95 |
| --- | --- | --- |
| Initial capture | 200.467 / 144.711–209.263 | 108.292 / 163.765 |
| No-op | 91.372 / 79.456–109.536 | 83.037 / 137.040 |

These are partial-profile statistics, not full G01 acceptance. Earlier environment
failures, the archive docs-check failure and cancelled preliminary v1 run remain
disclosed. No native OS, extended/deep, idle/interference, isolated executable
memory, comparison or Docker/OCI gate passed here; later owners retain those gates.

## Commits and rollback

| Implementation/evidence commit | Purpose |
| --- | --- |
| `5761fd69ff6856324a3ae265a58c8e3e8c785247` | Fixtures/fidelity checks |
| `b1e78a92c6d095e30d78d1355af6b5fbcc215c42` | Runner/export/summaries |
| `48fd99a7a765dd12cb0ddcf54c80501b8fff2f28` | Environment/export evidence |
| `547bef4cd33c44d1068159a305b230d5ffd22b41` | Corrected verifier/allocation |
| `c14443cca934b3666c439d4448925ed8b06addc8` | Preliminary/corrected evidence |
| `b0fa2492957a1e1c801833b12fe6aac7f95dd0a9` | Checked resumption/tests |
| `e5beeefcff25590cb4cf50ab02c7e2d4428a25d6` | Resumption/RSS evidence |
| `950a450f080f8f5a62e7e460910099dd157e8841` | Versioned partial metrics and continuation procedure |
| `e3ccae824c1aa03f4b6f984006e69033cefd95d1` | Complete capture/no-op checkpoint |

Rollback with `git revert` in reverse table order using the exact hashes;
reconcile handoff documents separately. Do not revert under the live runner.
Reverts do not remove external results, snapshots, test keys or dependencies.
No product format changed; fixture v1/run-summary v2 remain, with a separate
explicitly partial checkpoint schema v1. Locate this handoff commit with
`git log -1 --format=%H -- docs/implementation/reports/G01-attempt-06.md`.

## Design and interface notes

Advisory cache resets, synthetic compressibility, explicit test signers, WSL2,
changing free resources and the measurement interval across dates remain
limitations. RSS includes inherited launcher memory and is an upper bound.
No native-platform, isolated executable-memory or future-operation claim is made.
The partial checkpoint cannot replace complete-run evidence; use the normal
summarizer after the full run passes.

## Scope and worktree audit

- Changed: harness guide, versioned partial checkpoint, progress and this report.
- Runtime, harness Python, tests, README, Makefile and CI changes: none this turn.
- No unrelated changes observed; final worktree status checked after handoff commit.
- Keep external `/home/gongahkia/.cache/yeokcham-g01/`, including fixture/history,
  pinned export, signers, raw results and snapshots. Exact resumption needs these
  artifacts; committed metrics preserve measurement evidence without private keys.

## Remaining work and next handoff

- Completed phases: **0 / 20**. G01 active; G02 pending.
- Revalidate and monitor session `79434` / PID `154851`; never start a competing
  run. If actually stopped, investigate state before using checked `--resume`.
- Finish 100-MiB small-edit and undo/restore: 70 measured samples and six excluded
  warmups remain at checkpoint, with all exact-restore gates and 5/3/30 counts.
- Output: external `source-local-v2/summary.json` and per-tier `result.json`;
  log: external `source-local-v2-resume.log`, under the artifact root above.
- Refresh the versioned checkpoint at operation boundaries/handoffs. Read the
  ledger, latest report and checkpoint first; preserve accepted samples unchanged.
- Once both tiers pass, audit all 280 measured records/24 warmups, compact full
  evidence with `tools/benchmark_summary.py`, save readable investigation budgets
  and limitations, and run phase completion checks. Commit full results separately.
- Save attempt 07 and its separate report/tracker commit. Advance only when all
  G01 criteria pass; all later coverage gates remain open.
- Next prompt: `docs/implementation/goals/G01-baseline.md`, with this report,
  its actual handoff hash and all nine implementation/evidence hashes above.
- Future agent/worktree orchestration remains recorded for subsequent work;
  no later phase or additional implementation agent started here.
