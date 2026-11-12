# Yeokcham implementation report: G01 — resumed baseline, first tier complete

- Attempt: 04
- Status: in_progress; verified live measurements, no current blocker.
- Branch: main; starting commit `55eccfb69a86ee9ef4fac52c40a26f25bfd2df3b`.
- Design baseline: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`.
- Predecessor: `docs/implementation/reports/G01-attempt-03.md`; its listed commits
  and handoff are verified ancestors. Earlier attempts remain historical evidence.
- Platform: Fedora 44/WSL2, ext4 virtual disk, i7-1355U, 12 logical CPUs,
  5,155,467,264 bytes guest RAM; OCaml 5.5.0, Dune 3.24.2,
  ocamlformat 0.29.0, Python 3.14.8.
- Report: `docs/implementation/reports/G01-attempt-04.md`.

## Delivered behavior

The November 12 audit found old PID `118787` absent and session `20722` unknown.
The interrupted corrected run retained 132 verified records and no failures;
its cause and exit status were unavailable. It was not restarted while live.

Checked `--resume` now preserves original result snapshots, rejects incompatible
settings/binary/source/generator/machine inputs, verifies the pristine fixture
and every retained checkpoint, checks the accepted sample prefix, preserves any
in-flight sample, and measures only missing records. A per-output lock rejects
concurrent runners. Interrupted preparation without accepted samples is preserved
and rebuilt. Measurement and verification functions and the complete sample body
match the original v2 code; product runtime and timed commands are unchanged.

The 10-MiB/1,000-file tier completed all 140 measured samples plus 12 excluded
warmups. Independent audit checked exact bytes/count, manifest/tree hashes,
unique expected sample indices, finite metrics, the unchanged original prefix,
and recomputed median/p95 summaries. All ten 100-MiB retained checkpoints also
restored correctly. At November 13, 00:22:38 SGT, its first cold capture passed.
The full run therefore has 141/280 measured samples and 12/24 warmups accepted.
This turn made implementation/verification progress followed by a verified wait.

## Acceptance evidence

| G01 criterion | Evidence | Result |
| --- | --- | --- |
| 1. Establish environment; build/lint/CI | Original environment evidence and new resumption build/lint/CI logs | passed |
| 2. Deterministic configurable fixtures and runner | Existing generator plus checked resumption; twelve focused checks, including real linear/branching interruption recovery | passed |
| 3. Both selected local tiers and all samples | 10 MiB complete; 100 MiB has one accepted cold capture at checkpoint | not met yet |
| 4. Small full baseline summary, commands and hashes | Harness/environment/smoke/resumption evidence committed; full baseline summary awaits completion | not met yet |
| 5. Unmodified pinned export and later coverage gates | Same pinned binary/generator; source equality, retained restores and compatible measurement-code checks passed | passed |

## Verification

- `make build && make lint`: exit 0 on the resumption implementation tree.
- `python3 -B -W error::ResourceWarning -m unittest discover -s test -p 'test_benchmark_*.py' -v`:
  twelve passed before the final shallow-CI test-source fixture adjustment.
- Final `make ci` on the tree committed as `b0fa249`: exit 0; eight runner tests
  executed, unchanged four fixture tests and product targets reused by Dune.
  Exact command:
  `SOFTHSM2_CONF=/home/gongahkia/.cache/yeokcham-g01/softhsm2.conf YEOKCHAM_V1_TEST_PKCS11_MODULE=/usr/lib64/libsofthsm2.so YEOKCHAM_V1_TEST_OPENSSL=/home/linuxbrew/.linuxbrew/bin/openssl make ci`.
- Log paths/hashes and exact continuation command are committed in
  `docs/implementation/results/G01-resumption.json`.
- Resumption revalidated all ten original checkpoints and preserved all original
  132 records unchanged; subsequent 20 warm undo samples completed the first tier.
- Repeated polls of session `79434` and `ps` for PID `154851` confirmed liveness.
  At the checkpoint the process had elapsed 53m55s, with no recorded failures.
- `make docs-check` and `git diff --check`: passed for this report/tracker handoff.
  Changes after `b0fa249` are documentation/evidence only.

Immutable external checkpoint:
`/home/gongahkia/.cache/yeokcham-g01/checkpoints/attempt-04.json`, SHA-256
`c27c2b428bcf28855a1d7b7c3c342ecea76a9c97caa7a49ced4608f8b13ddc56`.
Completed 10-MiB raw case SHA-256:
`c437e7ed3233ed696e66c5bac2ebc67d7ef15df130941b9bb5b3d85daca7b874`.

Earlier formatter/OpenSSL setup failures, the pinned archive's Git-dependent
docs-check failure, and the deliberately cancelled preliminary v1 run remain
disclosed in earlier reports. No preliminary v1 timing was reused. Native OS,
extended/deep tiers, idle/interference, comparisons and Docker/OCI evidence remain
with the later owners in the coverage ledger; no unavailable check passed here.

## Commits and rollback

| Implementation/evidence commit | Purpose | Data effect |
| --- | --- | --- |
| `5761fd69ff6856324a3ae265a58c8e3e8c785247` | Fixtures and fidelity checks | Fixture schema v1 |
| `b1e78a92c6d095e30d78d1355af6b5fbcc215c42` | Runner, export and summaries | Original run/summary v1 |
| `48fd99a7a765dd12cb0ddcf54c80501b8fff2f28` | Original environment/export smoke | Evidence only |
| `547bef4cd33c44d1068159a305b230d5ffd22b41` | Exact efficient verifier and full allocation accounting | Run/summary v2 |
| `c14443cca934b3666c439d4448925ed8b06addc8` | Preliminary/corrected evidence | Evidence only |
| `b0fa2492957a1e1c801833b12fe6aac7f95dd0a9` | Checked resumption and regression tests | Optional v2 continuation/measurement-limit metadata |
| `e5beeefcff25590cb4cf50ab02c7e2d4428a25d6` | Resumption and RSS evidence | Evidence only |

Rollback with `git revert`, newest first: `e5beeefcff25590cb4cf50ab02c7e2d4428a25d6`,
`b0fa2492957a1e1c801833b12fe6aac7f95dd0a9`,
`c14443cca934b3666c439d4448925ed8b06addc8`,
`547bef4cd33c44d1068159a305b230d5ffd22b41`,
`48fd99a7a765dd12cb0ddcf54c80501b8fff2f28`,
`b1e78a92c6d095e30d78d1355af6b5fbcc215c42`,
`5761fd69ff6856324a3ae265a58c8e3e8c785247`. Reconcile handoff documents separately.
Do not revert under the live process. Source reverts do not undo external
measurements, snapshots, test keys or installed dependencies. No product format
changed. Obtain this handoff hash with
`git log -1 --format=%H -- docs/implementation/reports/G01-attempt-04.md`.

## Design and interface notes

Sampling, advisory cache resets, synthetic compressibility and test-signer
limitations remain as documented. The measurements span November 6–7 and
November 12–13; continuation metadata identifies their boundaries. Hardware,
kernel, toolchain and filesystem identities match; free resources vary. Pooled
statistics do not establish an uninterrupted session or paired comparison.

A local probe confirmed `wait4` peak RSS includes inherited launcher memory
before execution: `/bin/true` rose from 22,278,144 to 89,223,168 bytes after a
64-MiB allocation in its Python parent. Raw RSS is a launcher-inclusive upper
bound; isolated executable-memory comparison remains a G19 gate. The counter
and limitation are retained rather than silently changing measurement semantics.

## Scope and worktree audit

- This attempt changed the runner, runner tests, harness guide, resumption JSON,
  progress and this report. Existing runtime, README, Makefile and CI are unchanged.
- No unrelated worktree changes were observed. Only this report/progress remained
  for the handoff commit; final status is verified after committing.
- Full fixtures, histories, logs, snapshots and disposable test keys stay outside
  Git under `/home/gongahkia/.cache/yeokcham-g01/`.

## Remaining work and next handoff

- Completed phases: **0 / 20**. G01 active; G02 pending.
- Monitor session `79434` / PID `154851`, after revalidating liveness. Old handles
  in attempts 01–03 are historical. Do not launch a competing run.
- Output: `/home/gongahkia/.cache/yeokcham-g01/source-local-v2/summary.json` and
  per-tier `result.json`. Log: external `source-local-v2-resume.log`.
- Finish the 100-MiB tier: 139 measured samples and 12 warmups remain at checkpoint.
  Keep 5 cold / 3 excluded warmups / 30 warm per operation, ten nodes, and all
  exact-restore gates. If the process actually stops, use the checked `--resume`
  command in the committed evidence after investigating its state.
- Audit both complete tiers; compact with `tools/benchmark_summary.py`, save small
  machine-readable evidence and readable latency/storage/RSS-bound budgets with
  limitations, and run the phase completion checks. Commit results separately.
- Save attempt 05 and its separate report/tracker commit. Only then make G02 ready
  if every G01 criterion passes. All later coverage gates remain open.
- Next prompt source: `docs/implementation/goals/G01-baseline.md`, with this report,
  its actual handoff hash and the seven listed implementation/evidence hashes.
- Future agent/worktree orchestration preference remains recorded for subsequent
  work after this run and the user's pasted handoff. No later phase started here.
