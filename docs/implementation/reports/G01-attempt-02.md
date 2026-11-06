# Yeokcham implementation report: G01 — live baseline continuation

- Attempt: 02
- Status: in_progress; verified wait on the original measurement process.
- Branch: main; starting commit `f127843f3ab04d3967af39321e3ae74c08dc65c1`.
- Design baseline: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`.
- Predecessor: `docs/implementation/reports/G01-attempt-01.md`; all three
  implementation/evidence commits below and its handoff are verified ancestors.
- Platform/toolchain: Fedora 44/WSL2, ext4 virtual disk, i7-1355U, 12 logical CPUs,
  5,155,467,264 bytes guest RAM; OCaml 5.5.0, Dune 3.24.2,
  ocamlformat 0.29.0, Python 3.14.8.
- Report path: `docs/implementation/reports/G01-attempt-02.md`.

## Delivered behavior

The committed generator, CLI runner and pinned export remain unchanged. The
original full-profile process advanced through retained-history validation and
accepted the first five cold initial captures, three excluded warmups and two
warm initial captures for 10 MiB/1,000 files. No failure was recorded at the
checkpoint. This is seven measured samples out of 280, plus three warmups out of
24; it is not a complete baseline. The 100-MiB tier has not started.

The preceding goal turn made implementation progress. This turn is a verified
wait: repeated polls of exec session `29807`, PID `107969`, confirmed the process
live and observed new validated samples. No restart, reduced sampling, runtime
optimization or later-phase work occurred.

## Acceptance evidence

| G01 criterion | Evidence | Result |
| --- | --- | --- |
| 1. Environment/build/lint/CI | Committed `results/G01-environment.json`; main CI exit 0 at b1e78a9, subsequent changes are documentation only | passed |
| 2. Deterministic configurable fixtures and runner | Eight focused checks, exact restore gates, source/monorepo/asset and history controls documented in attempt 01 | passed |
| 3. Both local source tiers with selected counts | Seven measured samples and three warmups accepted at checkpoint; original process live | not met yet |
| 4. Small complete baseline summary, hashes and commands | Environment/smoke evidence exists; full measured summary still pending | not met yet |
| 5. Unmodified pinned export and visible later gates | Pinned build/source checks and real CLI smoke passed; G19/G20 gates remain open | passed |

## Verification

- `git status --short`: empty at turn start; branch `main`.
- `git merge-base --is-ancestor HASH HEAD`: passed for all three implementation/
  evidence hashes below and `f127843f3ab04d3967af39321e3ae74c08dc65c1`.
- Repeated `write_stdin` polls of session `29807`: still running; no terminal exit.
- At `2026-11-07T00:07:11+08:00`, `ps` confirmed runner PID `107969` and its
  active CLI restore child. The runner had elapsed 31 minutes, 47 seconds.
- Immutable external checkpoint:
  `/home/gongahkia/.cache/yeokcham-g01/checkpoints/attempt-02.json`;
  SHA-256 `dcb7fea6cacc0dc21b7b9c76905c59f5dab63525e3d7a1ec908c1d432e54e27f`.
  It contains the ten accepted sample/warmup records and an empty failure list.
- `make docs-check` and `git diff --check`: passed for this documentation handoff.
- Earlier build/lint/main CI and eight focused tests remain valid: no code changed.
  Initial OpenSSL/formatter setup failures and the pinned archive's Git-dependent
  docs-check failure remain disclosed in attempt 01 and environment evidence.
- Native OS, extended/deep tiers, idle/interference and Docker/OCI checks remain
  unperformed here, with ownership retained in the coverage ledger.

## Commits and rollback

| Implementation/evidence commit | Purpose | Data effect |
| --- | --- | --- |
| `5761fd69ff6856324a3ae265a58c8e3e8c785247` | Fixtures and fidelity checks | Benchmark fixture schema v1 |
| `b1e78a92c6d095e30d78d1355af6b5fbcc215c42` | Runner, export, summary and tests | Benchmark run/summary schemas v1 |
| `48fd99a7a765dd12cb0ddcf54c80501b8fff2f28` | Environment/export smoke evidence | JSON evidence only |

No new implementation commit this turn. Rollback remains newest first:
`git revert 48fd99a7a765dd12cb0ddcf54c80501b8fff2f28`, then
`git revert b1e78a92c6d095e30d78d1355af6b5fbcc215c42`, then
`git revert 5761fd69ff6856324a3ae265a58c8e3e8c785247`.
Reconcile handoff documents separately; do not revert under the live run.
Reverting source does not remove external data, test keys or installed dependencies.
Obtain this handoff hash with `git log -1 --format=%H -- docs/implementation/reports/G01-attempt-02.md`.

## Design and interface notes

No changes. Cold is advisory file-page eviction; warm pre-reads files. Each sample
uses a fresh process/copy and is accepted only after exact restoration. Initial
capture includes initialization and ends at one node; other operations start at
ten nodes. Test signer, synthetic compressibility and WSL2 limitations still apply.
No supported native-platform or future archive/review/scheduler performance claim.

## Scope and worktree audit

- Changed paths this turn: this report and `docs/IMPLEMENTATION_PROGRESS.md`.
- README and product runtime changes: none. Pre-existing worktree changes: none.
- Remaining uncommitted changes: checked after the handoff commit; expected empty.
- Fixtures, full logs/manifests and test secrets remain outside Git under
  `/home/gongahkia/.cache/yeokcham-g01/`; the checkpoint contains no signer secrets.

## Remaining work and next handoff

- Completed phases: **0 / 20**. G01 active; G02 pending.
- Continue the original live process: session `29807`, runner PID `107969` at this
  checkpoint. Revalidate liveness; never restart from a stale status or timeout.
- Results: `/home/gongahkia/.cache/yeokcham-g01/source-local/summary.json` and
  per-tier `result.json`; log: `/home/gongahkia/.cache/yeokcham-g01/source-local.log`.
- Finish both tiers with 280 measured samples and 24 excluded warmups; verify all
  restores, counts and failure lists. Then compact and commit baseline results,
  fixture hashes, exact commands and readable latency/storage/memory thresholds.
- Audit every G01 criterion and current-phase check; save attempt 03 and commit
  its tracker/report update separately. Only then make G02 ready if all gates pass.
- All later coverage gates remain open, including full 1-GiB/deep/monorepo/asset,
  native OS, sustained sessions, comparisons and final integrated validation.
- Next prompt source: `docs/implementation/goals/G01-baseline.md`, with this report,
  attempt 01 and the listed implementation hashes as continuation evidence.
