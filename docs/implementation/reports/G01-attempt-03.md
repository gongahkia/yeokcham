# Yeokcham implementation report: G01 — corrected harness and live baseline

- Attempt: 03
- Status: in_progress; corrected full profile is live, not complete.
- Branch: main; starting commit `6566f3d95749e4ee54553d8b35a3cbc6d172b380`.
- Design baseline: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`.
- Predecessor: `docs/implementation/reports/G01-attempt-02.md`; attempt 01,
  attempt 02 and the implementation/evidence commits below are ancestors.
- Platform/toolchain: Fedora 44/WSL2, ext4 virtual disk, i7-1355U, 12 logical CPUs,
  5,155,467,264 bytes guest RAM; OCaml 5.5.0, Dune 3.24.2,
  ocamlformat 0.29.0, Python 3.14.8.
- Report path: `docs/implementation/reports/G01-attempt-03.md`.

## Delivered behavior

The harness now verifies captured checkpoints by restoring into an empty separate
directory after changing live bytes. This checks stored content without adding
navigation proofs to the prepared history. Timed CLI commands remain unchanged,
including timed undo. Verification duration is recorded separately. Storage
allocation now includes directory blocks; seed sensitivity checks are tightened.
Run and summary schemas are v2. Product runtime and README remain unchanged.

The preliminary v1 process was deliberately stopped, confirmed exit 143. All 13
accepted records and the reason are preserved in external cancellation evidence;
none are reused in v2. A corrected export smoke and ten focused tests passed.

At the November 7, 00:59:43 SGT checkpoint, v2 had accepted 69 measured samples
and six excluded warmups: 10-MiB initial capture has 5 cold / 3 warmup / 30 warm;
no-op has 5 cold / 3 warmup / 29 warm. No failures were recorded. Small edit,
undo/restore and the 100-MiB tier remain. This turn made implementation and
verification progress, followed by a verified wait; it is not blocked.

## Acceptance evidence

| G01 criterion | Evidence | Result |
| --- | --- | --- |
| 1. Environment/build/lint/CI | `results/G01-environment.json`, `results/G01-harness-v2.json`; corrected implementation passed build/lint/CI | passed |
| 2. Deterministic configurable fixtures and runner | Source/monorepo/asset and history controls; ten focused checks; exact stored-checkpoint verification and directory allocation check | passed |
| 3. Both local source tiers with selected counts | Live v2 run: 69/280 measured samples, 6/24 excluded warmups at checkpoint | not met yet |
| 4. Small complete baseline summary, hashes and commands | Reproduction guide and corrected smoke committed; full measured summary still pending | not met yet |
| 5. Unmodified pinned export and visible later gates | Source equality/build checks and v2 export smoke passed; G19/G20 coverage remains open | passed |

Evidence paths above are relative to `docs/implementation/`.

## Verification

| Command/run | Tested state | Outcome |
| --- | --- | --- |
| `make build && make lint` | Implementation tree committed as `547bef4` | Exit 0 |
| `python3 -B -m unittest discover -s test -p 'test_benchmark_*.py' -v` | Same implementation tree | Ten tests passed, including live-file mutation, corrupt restore rejection and independent allocation comparison |
| `make ci` with the environment below | Same implementation tree | Exit 0; unchanged successful Dune targets reused |
| Pinned-export v2 smoke | Pinned runtime and corrected runner | Exit 0; 8 KiB/8 files, five branching nodes, attributes, 16 verified records |
| Ancestry/script checks | `c14443c` | Listed commits are ancestors; runner and generator bytes match `547bef4` |
| Live process and raw case observation | Session `20722`, PID `118787` | Live after 42m35s; unique sample indices, ten history nodes, no recorded failures |
| `make docs-check` and `git diff --check` | This report/tracker handoff | Passed |

Exact successful CI invocation:

`SOFTHSM2_CONF=/home/gongahkia/.cache/yeokcham-g01/softhsm2.conf YEOKCHAM_V1_TEST_PKCS11_MODULE=/usr/lib64/libsofthsm2.so YEOKCHAM_V1_TEST_OPENSSL=/home/linuxbrew/.linuxbrew/bin/openssl make ci`

Logs and hashes are in `results/G01-harness-v2.json`. Smoke provenance records
pre-commit HEAD plus exact script hashes; the full run records runner revision
`547bef4cd33c44d1068159a305b230d5ffd22b41`. Subsequent changes are documentation
only, so they do not invalidate these code checks.

Immutable external checkpoint:
`/home/gongahkia/.cache/yeokcham-g01/checkpoints/attempt-03.json`, SHA-256
`248c2205de0b4e55740a436cfcecce2d1c2255187a1715e1530a476d03d3ce63`.
It preserves the observed metadata and all 75 accepted records. The 10-MiB
fixture manifest is byte-identical between v1 and v2; tree SHA-256 is
`b6625b95d9d0e47d090658e1ac01f1660112dfa65aaa03f4ca4b3ee77b3f8160`.

Earlier formatter/OpenSSL setup failures and the pinned archive's Git-dependent
docs-check failure remain disclosed in attempt 01. No unavailable check is counted
as passed. Native OS, extended/deep tiers, idle/interference and Docker/OCI evidence
remain with their later-phase owners in the coverage ledger.

## Commits and rollback

| Implementation/evidence commit | Purpose | Data effect |
| --- | --- | --- |
| `5761fd69ff6856324a3ae265a58c8e3e8c785247` | Fixtures and fidelity checks | Fixture schema v1 |
| `b1e78a92c6d095e30d78d1355af6b5fbcc215c42` | Runner, export, summary and tests | Original run/summary schema v1 |
| `48fd99a7a765dd12cb0ddcf54c80501b8fff2f28` | Environment and original export smoke | Evidence only |
| `547bef4cd33c44d1068159a305b230d5ffd22b41` | Efficient exact verification and full allocation accounting | Run/summary schema v2 |
| `c14443cca934b3666c439d4448925ed8b06addc8` | Preserve preliminary evidence and corrected validation | Evidence only |

Rollback uses `git revert`, newest first: `c14443cca934b3666c439d4448925ed8b06addc8`,
`547bef4cd33c44d1068159a305b230d5ffd22b41`,
`48fd99a7a765dd12cb0ddcf54c80501b8fff2f28`,
`b1e78a92c6d095e30d78d1355af6b5fbcc215c42`,
`5761fd69ff6856324a3ae265a58c8e3e8c785247`. Reconcile handoff documents separately.
Do not revert under the live run. Source reverts do not remove external fixtures,
results, test keys or installed dependencies. No product format changed.
Obtain this handoff hash with
`git log -1 --format=%H -- docs/implementation/reports/G01-attempt-03.md`.

## Design and interface notes

Cold reset remains advisory file-page eviction; warm runs pre-read files and use
fresh processes/copies. Initial capture includes initialization and ends at one
node; other operations begin at ten. The test signer, synthetic compressibility,
rusage block-counter and WSL2 limitations remain. These results do not establish
native-platform performance. Future target shared-sync/review/integration,
private archive/eviction and managed-scheduler operations remain unmeasured.

## Scope and worktree audit

- Changed this attempt: `tools/benchmark_runner.py`, `tools/benchmark_summary.py`, both
  `test/test_benchmark_*.py` files, `docs/implementation/BENCHMARK_HARNESS.md`,
  `results/G01-harness-v2.json`, `results/G01-export-smoke-v2.json`, progress
  and this report. Paths abbreviated above use their existing repository folders.
- README, product runtime, Makefile and CI changes: none.
- Pre-existing worktree changes: none observed.
- Final handoff status is checked after committing; the live runner writes outside Git.
- Large fixtures, full logs/manifests and disposable test keys remain outside Git
  under `/home/gongahkia/.cache/yeokcham-g01/`.

## Remaining work and next handoff

- Completed phases: **0 / 20**. G01 active; G02 pending.
- Revalidate and monitor session `20722` / PID `118787`. Old session `29807`
  exited 143; earlier reports describing it as live are historical.
- Current result: `/home/gongahkia/.cache/yeokcham-g01/source-local-v2/summary.json`;
  per-tier `result.json` files update during each case. Progress log:
  `/home/gongahkia/.cache/yeokcham-g01/source-local-v2.log`.
- Run command: `python3 tools/benchmark_runner.py --output /home/gongahkia/.cache/yeokcham-g01/source-local-v2 --source-tree /home/gongahkia/.cache/yeokcham-g01/pinned-source --revision d03ac1e095af7c896eede2334c5a1f5fc50c4e74 --suite source --tiers 0,1 --history-nodes 10`.
- Finish both tiers with 280 measured samples and 24 excluded warmups; verify
  restores, counts and failure lists. Never restart a live process or mix v1 data.
- Compact completed evidence with `tools/benchmark_summary.py`; commit the small
  result, commands, hashes and readable latency/storage/memory investigation budgets.
- Audit G01, save attempt 04 and its separate handoff commit. Only mark G02 ready
  when G01 passes. All later coverage gates remain open.
- Next prompt source: `docs/implementation/goals/G01-baseline.md`, with this report
  and the listed implementation/evidence commits as predecessor evidence.
- Future coordination preference: after this run and the user's pasted handoff,
  the user wants coordinator-managed agents, separate worktrees/branches,
  deduplication, conflict resolution, integration checks and synchronized local/
  remote main. Reconcile the workflow for that subsequent work; current G01 keeps
  its phase boundary and single writer. No future phase was started here.
