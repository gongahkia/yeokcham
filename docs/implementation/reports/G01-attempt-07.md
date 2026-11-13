# Yeokcham implementation report: G01 — local baseline complete

- Attempt: 07
- Status: complete
- Branch: main
- Phase starting commit: `0f162112ecdad0bedf98997f9b2b5b3a58457e5d`.
- This attempt started at `99694da53fdb6e5c6e6f39cbcad922072019f00c`.
- Design/pinned source: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`.
- Predecessor: [attempt 06](G01-attempt-06.md), handoff
  `99694da53fdb6e5c6e6f39cbcad922072019f00c`; all listed implementation commits
  and the design baseline were verified ancestors of current main.
- Platform: Fedora 44/WSL2, ext4 virtual disk, i7-1355U, 12 logical CPUs,
  5,155,467,264 bytes RAM; OCaml 5.5.0, Dune 3.24.2,
  ocamlformat 0.29.0, Python 3.14.8.
- Report: `docs/implementation/reports/G01-attempt-07.md`.

## Delivered behavior

Deterministic configurable source/monorepo/asset and history-depth fixtures,
real CLI measurement, exact stored-object restore verification, pinned-source
export, strict full-run summarization and checked interruption recovery are
implemented. Resume preserves accepted records and verifies retained inputs before
continuing; per-output locking prevents competing runners. Product runtime is
unchanged from the pinned source.

Both selected ordinary-source tiers passed: 10 MiB/1,000 files and
100 MiB/10,000 files, initially ten linear history nodes. Every operation completed
5 cold / 3 excluded warmups / 30 warm samples: **280 measured records plus
24 warmups**, with no failures. The run finished November 14, 06:58:12 SGT;
session `79434` returned exit 0. Initial capture creates one node; no-op keeps ten;
a 64-byte edit creates node eleven; undo restores node zero while retaining all ten.

The [readable baseline](../results/G01-baseline.md),
[80,522-byte complete summary](../results/G01-baseline.json) and
[acceptance receipt](../results/G01-acceptance.json) preserve exact commands,
fixture/binary/source hashes, all sample metrics, statistics and concrete
investigation budgets. The historical 294-record partial checkpoint remains
available. Its prefix and the original 132 pre-interruption records are unchanged.

Warm median / p95, seconds; warmups excluded:

| Operation | 10 MiB | 100 MiB |
| --- | --- | --- |
| Initial capture | 31.691 / 45.510 | 108.292 / 163.765 |
| No-op | 10.571 / 22.829 | 83.037 / 137.040 |
| Small edit | 19.982 / 24.096 | 71.043 / 108.231 |
| Undo/restore | 58.915 / 118.355 | 407.328 / 421.932 |

Review thresholds are baseline warm median/p95 multiplied by 1.10 and maximum
measured allocated storage/launcher-inclusive RSS multiplied by 1.15. Repeat
breached cases under the same conditions before classifying a regression.
These are investigation budgets, not product guarantees.

## Acceptance evidence

| G01 criterion | Evidence | Result |
| --- | --- | --- |
| 1. Establish environment; actual build/lint/CI | Environment/resumption evidence; all three completion commands exited 0 on `7646362d80929e4f9cdccce0b90ac86beaa1a4a8` | passed |
| 2. Configurable deterministic fixtures and runner; verify contents | Three fixture suites and depth/layout controls; four fixture and eight runner checks; real CLI branching/attribute smoke and corruption rejection | passed |
| 3. Both selected tiers, four existing operations and selected counts | Full passing run: 8 groups of 5 cold / 3 warmup / 30 warm; independent 304-record audit | passed |
| 4. Small full summary, commands/hashes, limits and future-operation status | Complete JSON/readable baseline; exact budgets; unsupported target operations explicitly absent, not passed | passed |
| 5. Unmodified pinned export without switching main; deferred gates visible | Export build provenance, final source/binary hash audit, same measurement AST and fixtures; later ledger gates remain pending | passed |

## Verification

| Command/run | Tested state | Actual outcome |
| --- | --- | --- |
| `make build` | Clean `7646362d80929e4f9cdccce0b90ac86beaa1a4a8` | exit 0; external `completion-build.log` |
| `make lint` | Same commit | exit 0; external `completion-lint.log` |
| `make ci` with the environment below | Same commit | exit 0; external `completion-ci.log`; Dune reused cached runtime/focused results; docs/workflow shell checks ran |
| `python3 -B -W error::ResourceWarning -m unittest discover -s test -p 'test_benchmark_*.py' -v` | Resumption working tree before final shallow-CI test-fixture adjustment | Twelve passed; final `b0fa249` CI then executed the adjusted eight runner checks and reused four unchanged fixture checks |
| Full `tools/benchmark_runner.py` invocation and checked `--resume`, saved verbatim in the baseline | Pinned executable; runner `547bef4` then compatible `b0fa249` | exit 0; both tiers passed every content/history gate and count |
| `python3 tools/benchmark_summary.py /home/gongahkia/.cache/yeokcham-g01/source-local-v2/summary.json docs/implementation/results/G01-baseline.json` | Complete passing raw run | exit 0; incomplete/duplicate/failure guard retained |
| `python3 -B /home/gongahkia/.cache/yeokcham-g01/audit_measurements.py docs/implementation/results/G01-baseline.json docs/implementation/results/G01-measurement-checkpoint.json` | Saved full summary against raw data/294-record prefix | exit 0; full pristine paths/bytes, unique indices, all metrics/commands, edited/restored hashes, statistics and budgets verified |
| Pinned-source/binary/generator/runner, machine, original-prefix and retained `du -s -B1` audit | Completed external artifacts | passed; source matches, measurement AST unchanged, original 132 records unchanged, allocations match |
| `make docs-check` and `git diff --check` | Final report/tracker preparation | passed before handoff commit |

Exact CI environment:
`SOFTHSM2_CONF=/home/gongahkia/.cache/yeokcham-g01/softhsm2.conf YEOKCHAM_V1_TEST_PKCS11_MODULE=/usr/lib64/libsofthsm2.so YEOKCHAM_V1_TEST_OPENSSL=/home/linuxbrew/.linuxbrew/bin/openssl make ci`.
All completion log paths, timestamps/exits and SHA-256 values are in the acceptance
receipt. Code has not changed since the recorded final resumption implementation;
subsequent baseline, acceptance and handoff changes are documentation/evidence only.
No cached test target is described as freshly executed.

Actual checked-resume command:
`python3 tools/benchmark_runner.py --output /home/gongahkia/.cache/yeokcham-g01/source-local-v2 --source-tree /home/gongahkia/.cache/yeokcham-g01/pinned-source --revision d03ac1e095af7c896eede2334c5a1f5fc50c4e74 --suite source --tiers 0,1 --history-nodes 10 --resume`.

- Compact summary SHA-256:
  `03e105c1c9ad56178f20b67bc1132c1a5795015d4346dce6d3c9b5f4115ed88b`.
- Raw summary SHA-256:
  `91952fc8cb14e77f97a46f181b56755e92365c5271931878a408e358c106caea`.
- Executable SHA-256:
  `8a7f77267e4d68907ffbf7a4999403f3906dc73ed4248f068776717a857dfec6`.
- Acceptance receipt SHA-256:
  `a83992829ec0900fbf8ee695f49a0ee4f65ce25b71a371590543779a66a55f72`.
- Immutable full raw snapshot: external `checkpoints/final-1794610728850154352`.

The earlier formatter/OpenSSL setup failures, archive CI docs-check failure caused
by missing Git metadata, deliberately cancelled v1 run (exit 143, 13 records), and
v2 interruption with unknown cause remain disclosed. V1 timings were excluded;
checked continuation revalidated v2 inputs and skipped accepted measurements.
The full UTC measurement interval spans November 6–13 (November 7–14 SGT),
including interruption/time gaps. Pooled results are not an uninterrupted session
or paired comparison.

## Commits and rollback

The following exact hashes are ordered **newest first**, which is also the rollback
order. Historical handoff/report commits remain preserved separately.

| Implementation/evidence commit | Atomic purpose | Format/data effect |
| --- | --- | --- |
| `f924e0f480b4b5b7040b2ad3572790f171a8d745` | Final acceptance/CI receipt | Acceptance schema v1; documentation only |
| `7646362d80929e4f9cdccce0b90ac86beaa1a4a8` | Complete local baseline, readable budgets and commands | Lossless summary v2; documentation only |
| `e385b9ce42fc0c708e0af95d52af92a33cb6ef43` | Preserve twenty warm undo samples | Partial checkpoint evidence |
| `1b69a3ac3f20b1e10158d6626703a09ed6a22e17` | Preserve ten warm undo samples | Partial checkpoint evidence |
| `35a95f7f0ce0df5c5400e666eeae02b876e280f6` | Preserve cold undo and warmups | Partial checkpoint evidence |
| `5a69bb5b0a557f85b7f472be6af8fc7e16dc4163` | Preserve complete small-edit group | Partial checkpoint evidence |
| `e3ccae824c1aa03f4b6f984006e69033cefd95d1` | Preserve complete capture/no-op groups | Partial checkpoint evidence |
| `950a450f080f8f5a62e7e460910099dd157e8841` | Versioned metrics backup and continuation procedure | Explicitly partial checkpoint schema v1 |
| `e5beeefcff25590cb4cf50ab02c7e2d4428a25d6` | Resumption and RSS probe evidence | Evidence only |
| `b0fa2492957a1e1c801833b12fe6aac7f95dd0a9` | Checked resumption, locking and failure tests | v2 continuation metadata; measured code unchanged |
| `c14443cca934b3666c439d4448925ed8b06addc8` | Preliminary cancellation/corrected harness evidence | Evidence only |
| `547bef4cd33c44d1068159a305b230d5ffd22b41` | Destination restore verifier and directory allocation | Run/summary schema v2; v1 timings excluded |
| `48fd99a7a765dd12cb0ddcf54c80501b8fff2f28` | Environment and pinned-export evidence | Evidence only |
| `b1e78a92c6d095e30d78d1355af6b5fbcc215c42` | Runner, pinned export, summary and checks | External run data and disposable test signers |
| `5761fd69ff6856324a3ae265a58c8e3e8c785247` | Deterministic configurable fixtures and fidelity checks | Fixture schema v1; no product format change |

- Rollback: `git revert` the table rows from top to bottom, using those full hashes;
  reconcile handoff/tracker documentation and any later dependent phases first.
  No rollback was executed.
- No product format or user-data migration changed. Reverting source does not
  remove external results, fixture/history trees, test signers or installed tools.
  Preserve recovery/artifact roots; do not revert a harness while a future run is live.
- Handoff commit: obtain with `git log -1 --format=%H -- docs/implementation/reports/G01-attempt-07.md`;
  its actual hash is returned in chat after committing this report/tracker separately.

## Design and interface notes

Fixture schema v1 uses deterministic contents and canonical full manifests.
Run/summary schema v2 records destination-based verification and file/directory
allocation; optional continuation metadata preserves provenance. The historical
partial-checkpoint schema v1 is explicitly incomplete; the complete summary is
authoritative. Acceptance receipt schema v1 identifies actual tested code/evidence.

Advisory cache resets, deliberately compressible synthetic source, disposable test
signers, WSL2, uncontrolled host work/free resources and the multi-date interval
limit interpretation. `wait4` peak RSS includes inherited launcher memory; it is
an upper bound, not isolated executable RSS. Block counters are not exact device
bytes. These limits and the measured memory probe remain in the readable baseline.

The pinned runtime lacks target private archive/eviction, native review-policy and
integration-plan workflows, complete shared offline sync and managed cross-platform
scheduling. Their absence is not benchmark success. No design amendment or runtime
optimization was introduced in this phase.

## Scope and worktree audit

- Owned code: `tools/benchmark_fixture.py`, `tools/benchmark_runner.py`,
  `tools/benchmark_summary.py`, `test/test_benchmark_fixture.py`,
  `test/test_benchmark_runner.py` and their registration in `test/dune`.
- Owned documentation/evidence: harness guide, G01 result/receipt manifests,
  append-only attempt reports and `docs/IMPLEMENTATION_PROGRESS.md`.
- Runtime, README, Makefile and CI remain unchanged from the pin. README changes: none.
- Pre-existing unrelated changes: none observed; every commit staged explicit owned paths.
- At report preparation, only this report/tracker closeout is pending; final clean
  `main` status is checked after its separate commit and returned in chat.
- Large fixtures, full logs, pinned export and disposable private test keys remain
  under `/home/gongahkia/.cache/yeokcham-g01/`, outside Git. Keep that root to avoid
  recreating retained inputs. No additional implementation agents, branches,
  worktrees, pushes or deployments were started by this phase.

## Remaining work and next handoff

- Current-phase acceptance criteria: none remaining; all five passed.
- Completed phases: **1 / 20**. G02 is ready and unstarted; G03–G20 remain pending.
- All later ledger gates remain pending: canonical/policy/composition (G02–G04),
  capture/storage integrity (G05–G07), shared preservation/sync (G08/G13), private
  recovery/archive (G09–G11), review/CLI flows (G12–G14), background services and
  resources (G15–G17), native macOS/Linux/Windows (G16/G17/G20), automated journeys
  and human comprehension (G18/G20), full benchmark evidence (G19), and integrated
  packaging/container/server/final validation (G20).
- Full 1-GiB/deep/branching/monorepo/asset sessions, licensed projects, Git/codec
  comparisons, isolated executable memory, idle and interference experiments remain
  G19/G20 work. This report closes only the local G01 profile.
- Next eligible phase: G02. Source: `docs/implementation/goals/G02-canonical-records.md`.
- Next agent verifies this report, its handoff commit, all fifteen implementation/
  evidence hashes above, baseline/acceptance artifacts and the remaining gates.
- Future coordinator-managed agents/worktrees and local/remote-main reconciliation
  remain recorded as the user's preference for subsequent work after this handoff.
  This phase stops here and does not execute G02.
