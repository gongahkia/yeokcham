# Yeokcham implementation report: G01 — measurement harness and local baseline

- Attempt: 01
- Status: in_progress; the required full local measurement process is running.
- Branch: main
- Starting commit: `0f162112ecdad0bedf98997f9b2b5b3a58457e5d`
- Design baseline: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`; ancestry verified.
- Predecessor: none; G01 is the first phase.
- Platform/toolchain: Fedora 44 on WSL2, x86_64, i7-1355U, 12 logical CPUs,
  5,155,467,264 bytes guest RAM, ext4 on a virtual disk; OCaml 5.5.0,
  Dune 3.24.2, ocamlformat 0.29.0, Python 3.14.8.
- Report: `docs/implementation/reports/G01-attempt-01.md`

## Delivered behavior

Deterministic source, monorepo and asset fixtures support independent byte/file
counts, layout, seeds, large files and filesystem attributes. Full manifests
verify contents, executable state, directories and links. The runner measures
existing CLI initial capture, no-op, small edit and undo restoration, with
configurable history depth/branching and the selected default sample counts.
Timings require exact restore and history checks. Small summaries retain every
sample and derive investigation thresholds. Product runtime and README are unchanged.

The pinned-source export builds without switching main and passes a real CLI smoke
run. The full G01 profile has started but has not completed; no local performance
result or G01 completion is claimed. This turn made concrete implementation and
verification progress; it is not a blocked turn.

## Acceptance evidence

| G01 criterion | Evidence | Result |
| --- | --- | --- |
| 1. Establish environment; run build/lint/CI | `G01-environment.json`; documented setup completed, build/lint passed, main `make ci` exited 0 | passed |
| 2. Deterministic configurable fixture generator/runner | `tools/benchmark_fixture.py`, `benchmark_runner.py`, `benchmark_summary.py`; eight focused tests, including corruption rejection and real branching restores | passed |
| 3. Two ordinary-source baseline tiers, 10 nodes, selected samples | Live pinned-export run; still preparing/verifying retained history at this checkpoint | not met yet |
| 4. Small baseline summary, commands, hashes, absent operations | Environment and export-smoke summaries committed; full baseline summary awaits the live run | not met yet |
| 5. Unmodified pinned export; later coverage gates | Export/source equality checks and 16-sample smoke passed; G19/G20 gates remain open | passed |

Evidence files are under `docs/implementation/results/`; reproducible commands and
measurement semantics are in `docs/implementation/BENCHMARK_HARNESS.md`.

## Verification

| Command/run | Tested state | Outcome |
| --- | --- | --- |
| `make setup` | Starting tree plus fixture work | Exit 0; local switch and documented dependencies installed |
| `make build && make lint` | Fixture tree, then b1e78a9 implementation tree | Exit 0 after setup/format correction |
| `python3 -B -m unittest discover -s test -p 'test_benchmark_*.py' -v` | b1e78a9 implementation tree | Eight tests passed |
| `make ci` with documented OpenSSL/SoftHSM environment | `b1e78a92c6d095e30d78d1355af6b5fbcc215c42` | Exit 0; lint, runtime/harness, docs and workflow checks passed; Dune reused unchanged successful targets |
| Pinned export build and `make ci` | `d03ac1e095af7c896eede2334c5a1f5fc50c4e74` | Build/lint and 289 cases in 47 runtime suites passed; CI exited 2 at docs-check because archive has no Git metadata |
| Pinned-export runner smoke | Pinned binary plus b1e78a9 runner | Exit 0; 8 KiB/8 files, five-node branching history, attributes, 16 samples/warmups with exact restores |
| `make docs-check` and `git diff --check` | Evidence/handoff changes | Passed |

Earlier failures are retained in the environment evidence: lint ran before formatter
installation, then identified the new Dune stanza's formatting; initial runtime tests
failed ten HTTPS cases because `/usr/bin/openssl` was absent. The installed Homebrew
OpenSSL works through `YEOKCHAM_V1_TEST_OPENSSL`; no test was weakened. SoftHSM was
configured rather than treating its optional skipped path as coverage.

The exact successful CI invocation is:

`SOFTHSM2_CONF=/home/gongahkia/.cache/yeokcham-g01/softhsm2.conf YEOKCHAM_V1_TEST_PKCS11_MODULE=/usr/lib64/libsofthsm2.so YEOKCHAM_V1_TEST_OPENSSL=/home/linuxbrew/.linuxbrew/bin/openssl make ci`

No native macOS/Linux/Windows, Docker/OCI, full extended, deep-history or
cross-platform performance gate passed here. Those remain assigned to G19/G20
and their implementation owners in the progress ledger.

## Commits and rollback

| Implementation/evidence commit | Purpose | Format/data effect |
| --- | --- | --- |
| `5761fd69ff6856324a3ae265a58c8e3e8c785247` | Deterministic generator, fidelity tests, progress claim | Benchmark fixture schema v1 only |
| `b1e78a92c6d095e30d78d1355af6b5fbcc215c42` | Verified CLI runner, export, summaries, tests and guide | Benchmark run/summary schemas v1 only |
| `48fd99a7a765dd12cb0ddcf54c80501b8fff2f28` | Environment outcomes and export-smoke evidence | Small JSON evidence only |

Rollback order: `git revert 48fd99a7a765dd12cb0ddcf54c80501b8fff2f28`, then
`git revert b1e78a92c6d095e30d78d1355af6b5fbcc215c42`, then
`git revert 5761fd69ff6856324a3ae265a58c8e3e8c785247`. Reconcile the tracker/report
separately. Source reverts do not remove external fixtures, test keys, toolchain or
results. No product format changed. Do not revert a harness underneath its live run.

Handoff commit: obtain with `git log -1 --format=%H -- docs/implementation/reports/G01-attempt-01.md`.

## Design and interface notes

No design amendment. Cold means advisory `fsync`/`POSIX_FADV_DONTNEED` file-page
eviction; metadata, libraries and hypervisor/device caches remain uncontrolled.
Warm samples pre-read files and use fresh CLI processes/repository copies. Initial
capture includes `init` and its identity ceremony and creates one node; other
operations start with ten. The explicit test signer avoids native custody setup.
Synthetic text is highly compressible. These WSL2 results cannot establish supported
native-platform performance. Future target archive/eviction, full shared offline
sync, review/integration and managed scheduler operations are explicitly unmeasured.

## Scope and worktree audit

- Changed paths: three `tools/benchmark_*.py` files; two `test/test_benchmark_*.py`
  files and `test/dune`; harness guide; two result JSON files; progress and this report.
- README changes: none. Product `lib/`, `bin/`, Makefile and CI definitions unchanged.
- Pre-existing changes: none; other observed agent processes used another project.
- Remaining changes after this handoff commit: none expected; final status is checked
  before returning. The live process writes only outside Git.
- Large fixtures, full manifests/logs and disposable private test keys:
  `/home/gongahkia/.cache/yeokcham-g01/`. Test signers are in mode-0700 directories.
  Recovery mnemonic stdout is not stored in result artifacts.

## Remaining work and next handoff

- Completed phases: **0 / 20**. G01 remains active; G02 is not ready.
- Finish the live two-tier run: 280 measured samples plus 24 excluded warmups.
  Do not reduce counts, restart a live process, or count smoke results as baseline.
- Runner process PID at checkpoint: `107969`; exec session handle: `29807`.
  Revalidate these with a tool/process observation; a stale JSON status alone does
  not prove that the process is live. If running, poll the same handle.
- Run command:
  `python3 tools/benchmark_runner.py --output /home/gongahkia/.cache/yeokcham-g01/source-local --source-tree /home/gongahkia/.cache/yeokcham-g01/pinned-source --revision d03ac1e095af7c896eede2334c5a1f5fc50c4e74 --suite source --tiers 0,1 --history-nodes 10`
- Log: `/home/gongahkia/.cache/yeokcham-g01/source-local.log`.
  Durable result: `/home/gongahkia/.cache/yeokcham-g01/source-local/summary.json`;
  individual case results appear after retained-history validation.
- After successful completion, compact the full summary with
  `tools/benchmark_summary.py`; commit small baseline evidence and a readable result
  table with actual latency/storage/memory budgets and limitations. Verify hashes,
  counts and failure lists. Resolve any genuine failures without changing runtime
  or hiding results.
- Audit all criteria; save attempt 02, reconcile the tracker/coverage ledger, and
  commit the report separately. Advance only when G01 is proven complete.
- Outstanding coverage gates: G01 full local evidence; all later ledger gates,
  including full 1-GiB/deep/monorepo/asset sessions, native OS validation and G19/G20
  comparisons. The initial profile never closes those later gates.
- Next eligible prompt: continuation of `docs/implementation/goals/G01-baseline.md`.
  Verify this report and all three commits above before continuing. Do not execute G02.
