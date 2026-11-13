# Yeokcham implementation report: G01 — 100-MiB capture complete

- Attempt: 05
- Status: in_progress; verified wait on the existing live measurement process.
- Branch: main; starting commit `272fe3735a0bac11fe34d82bef86b2512b2493dd`.
- Design baseline: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`.
- Predecessor: `docs/implementation/reports/G01-attempt-04.md`; its handoff and
  seven implementation/evidence commits remain ancestors of unchanged main.
- Platform: Fedora 44/WSL2, ext4 virtual disk, i7-1355U, 12 logical CPUs,
  5,155,467,264 bytes RAM; OCaml 5.5.0, Dune 3.24.2,
  ocamlformat 0.29.0, Python 3.14.8.
- Report: `docs/implementation/reports/G01-attempt-05.md`.

## Delivered behavior

The same session `79434` / PID `154851` remained live after interruption of the
observer. The observer was replaced without restarting the benchmark. Repeated
polls observed the complete 100-MiB initial-capture group: five cold samples,
three excluded warmups and thirty warm samples, all verified. The actual CLI
child then advanced to `save` for no-op measurement.

The 10-MiB tier remains complete. At November 13, 22:57:10 SGT, the full run had
175/280 measured records plus 15/24 excluded warmups, with no recorded failures.
This turn is a verified wait with new completed measurement evidence, not a
blocked condition. No runtime or harness code changed.

## Acceptance evidence

| G01 criterion | Evidence | Result |
| --- | --- | --- |
| 1. Establish environment; build/lint/CI | Prior committed environment/resumption evidence; tested code unchanged | passed |
| 2. Deterministic configurable fixtures and runner | Existing generator, runner, twelve focused checks and checked resumption | passed |
| 3. Both tiers and all selected samples | 10 MiB complete; 100-MiB capture complete; no-op/small-edit/undo remain | not met yet |
| 4. Small full baseline summary, commands and hashes | Committed setup/smoke/resumption evidence; complete measured summary pending | not met yet |
| 5. Unmodified pinned export and later coverage gates | Same pinned binary/generator and verified retained checkpoints; later gates stay open | passed |

## Verification

- Repeated `write_stdin` polls of session `79434`: still running, no terminal exit.
  `ps` confirmed PID `154851` live after 2h44m01s at the checkpoint, with a
  `yeokcham_v1.exe save` child in the disposable 100-MiB sample repository.
- Independent 100-MiB capture audit passed: exactly 104,857,600 bytes / 10,000
  files; manifest file hash and canonical tree digest; all expected unique
  indices in 5/3/30 groups; finite nonnegative timing/CPU/verifier metrics;
  matching restored tree hashes; allocation component sums.
- 100-MiB tree SHA-256:
  `a2482d6706de2a8e10389130db702506eba3e03a77ba5b21633b0ec2fb2537c4`.
  Manifest SHA-256:
  `a8c193fc4d052f78bab787cce737351f5343abaf1a677d32a98005255d99c2eb`.
- Immutable external checkpoint:
  `/home/gongahkia/.cache/yeokcham-g01/checkpoints/attempt-05.json`;
  SHA-256 `8a097192384fd9dcf120277ad822c3c593c463a4d6e224b4ff24dffaa73e7fff`.
  It preserves both case records, run metadata and the independent capture audit.
- `make docs-check` and `git diff --check`: passed for this report/tracker update.
  Earlier build/lint/CI and focused checks remain valid because code is unchanged.

Capture-only 100-MiB latency, independently computed from all measured records:

| Cold median / range (seconds) | Warm median / p95 (seconds) |
| --- | --- |
| 200.467 / 144.711–209.263 | 108.292 / 163.765 |

Warmups are excluded. This is one completed operation, not the full G01 result.
Initial capture measures initialization and ends at one node; the other operations
start from ten retained nodes. No later-operation performance is inferred.

Earlier setup failures, archive docs-check failure and deliberately cancelled v1
timings remain disclosed in earlier reports. Native OS, extended/deep tiers,
idle/interference, comparisons, isolated executable memory and Docker/OCI checks
remain assigned to later coverage owners; none is counted as passed here.

## Commits and rollback

No new implementation commit this turn. Existing implementation/evidence commits:

| Commit | Purpose |
| --- | --- |
| `5761fd69ff6856324a3ae265a58c8e3e8c785247` | Fixtures and fidelity checks |
| `b1e78a92c6d095e30d78d1355af6b5fbcc215c42` | Runner/export/summaries |
| `48fd99a7a765dd12cb0ddcf54c80501b8fff2f28` | Original environment/export evidence |
| `547bef4cd33c44d1068159a305b230d5ffd22b41` | Corrected verifier/allocation accounting |
| `c14443cca934b3666c439d4448925ed8b06addc8` | Preliminary/corrected evidence |
| `b0fa2492957a1e1c801833b12fe6aac7f95dd0a9` | Checked resumption and tests |
| `e5beeefcff25590cb4cf50ab02c7e2d4428a25d6` | Resumption/RSS evidence |

Rollback with `git revert` in reverse table order, using the exact hashes above;
reconcile handoff documents separately. Do not revert under the live runner.
Source reverts do not remove external measurements, snapshots, test keys or
installed dependencies. Benchmark fixture schema v1 and run/summary v2 are
unchanged; no product format changed. Obtain this handoff hash with
`git log -1 --format=%H -- docs/implementation/reports/G01-attempt-05.md`.

## Design and interface notes

Advisory cache resets, synthetic compressibility, test signers, WSL2, differing
free resources and the measurement interval across dates remain limitations.
Continuation metadata identifies the preserved sample boundaries. RSS includes
inherited launcher memory and is an upper bound; no isolated executable-memory
or supported native-platform claim is made. Future target operations remain
explicitly unmeasured in the run metadata and coverage ledger.

## Scope and worktree audit

- Changed paths: this report and `docs/IMPLEMENTATION_PROGRESS.md`.
- README, runtime, harness, Makefile and CI changes: none this turn.
- Pre-existing changes: none observed. Final worktree status is checked after
  the report/tracker commit; the runner writes outside Git.
- Full fixtures, logs, histories, snapshots and disposable test keys remain under
  `/home/gongahkia/.cache/yeokcham-g01/`, outside Git.

## Remaining work and next handoff

- Completed phases: **0 / 20**. G01 active; G02 pending.
- Revalidate and monitor session `79434` / PID `154851`; do not restart while live.
- Finish 100-MiB no-op, small-edit and undo/restore: at checkpoint, 105 measured
  samples plus nine excluded warmups remain. Preserve 5/3/30 counts and all
  exact-restore gates. Investigate actual terminal state before using `--resume`.
- Results: external `source-local-v2/summary.json` and per-tier `result.json`;
  log: external `source-local-v2-resume.log`, under the artifact root above.
- Once all samples pass, audit both complete tiers, compact full evidence with
  `tools/benchmark_summary.py`, and commit small results plus readable
  latency/storage/RSS-bound investigation budgets and limitations.
- Run phase completion checks; save attempt 06 and its separate report/tracker
  commit. Advance only after all G01 criteria pass. All later coverage stays open.
- Next prompt: `docs/implementation/goals/G01-baseline.md`, with this report,
  its actual handoff hash and all seven implementation/evidence hashes above.
- Future multi-agent/worktree preference remains recorded for subsequent work;
  no later phase or additional implementation agent started here.
