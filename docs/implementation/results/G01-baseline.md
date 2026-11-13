# G01 local ordinary-source baseline

Measurement status: **passed**. Both selected tiers completed 280 measured records
and 24 excluded warmups, with no failures. This is the bounded G01 profile,
not completion of the extended benchmark or native-platform coverage gates.

[All sample metrics, provenance and exact budgets](G01-baseline.json) are retained
in an 80,522-byte lossless summary. [Harness instructions](../BENCHMARK_HARNESS.md)
define generation, cache preparation, verification, export and checked resumption.
[Completion checks and audit receipt](G01-acceptance.json) records the exact tested
commit, command exits, log hashes and independent acceptance evidence.

## Machine and workload

- Fedora 44 under WSL2; kernel 6.18.33.2-microsoft-standard-WSL2; ext4 virtual
  disk `/dev/sdd`. This is not native Linux acceptance evidence.
- Reported CPU: Intel Core i7-1355U, 12 logical CPUs; RAM: 5,155,467,264 bytes.
- OCaml 5.5.0, Dune 3.24.2, ocamlformat 0.29.0, Python 3.14.8.
- Synthetic ordinary-source fixtures: seed 1, depth 3, fanout 8, no large-file
  override or attribute variants. All generated paths included; no ignore files.
- Ten retained linear history nodes; first capture creates one node, no-op keeps
  ten, small edit replaces 64 bytes in one file and creates node eleven, and undo
  restores node zero while retaining all ten nodes.
- Explicit disposable test-file signer outside the worktree; watcher off, network
  and server absent; existing storage defaults. Native key custody is not timed.

| Live size / regular files | Logical captured bytes (10 nodes) | Retained history file bytes | Retained history allocated bytes |
| --- | --- | --- | --- |
| 10 MiB / 1,000 | 104,857,600 | 10,792,700 | 22,761,472 |
| 100 MiB / 10,000 | 1,048,576,000 | 106,222,796 | 167,014,400 |

Allocated history includes regular-file and directory blocks, including its
metadata root; it excludes the live worktree. Final retained allocations matched
`du -s -B1`. Per-operation storage, CPU, RSS, block counters and separate
verification durations remain available for every sample in the JSON.

## Latency

Every size/operation has 5 cold samples and 30 warm samples after 3 excluded
warmups. Seconds below include CLI startup and exit; fixture copies, cache
preparation and correctness verification are outside the clock. Every process is
fresh, including warm samples. p95 uses nearest rank; all measured samples enter
the statistics. The JSON also retains ranges and sample standard deviations.

| Live MiB | Operation | Cold median / range (s) | Warm median (s) | Warm p95 (s) |
| --- | --- | --- | --- | --- |
| 10 | initial_capture | 33.724 / 33.035–48.142 | 31.691 | 45.510 |
| 10 | no_op | 15.204 / 12.750–27.543 | 10.571 | 22.829 |
| 10 | small_edit | 29.944 / 27.945–33.250 | 19.982 | 24.096 |
| 10 | undo_restore | 103.119 / 80.705–117.242 | 58.915 | 118.355 |
| 100 | initial_capture | 200.467 / 144.711–209.263 | 108.292 | 163.765 |
| 100 | no_op | 91.372 / 79.456–109.536 | 83.037 | 137.040 |
| 100 | small_edit | 117.061 / 107.465–146.031 | 71.043 | 108.231 |
| 100 | undo_restore | 480.815 / 423.613–724.747 | 407.328 | 421.932 |

## Investigation budgets

Investigate a reproducible increase above 10% in warm median/p95 or 15% in
measured maximum allocated storage or launcher-inclusive RSS. Absolute thresholds
below are baseline statistics multiplied by 1.10 or 1.15, respectively. Repeat an
affected case with the same machine, filesystem, fixture, retained states, harness
and cache treatment before classifying a regression. These are review thresholds,
not product latency guarantees. Exact values are in the JSON; tables are rounded.

| Live MiB | Operation | Warm median / p95 limit (s) | RSS upper bound max / limit (MiB) | Allocated max / limit (MiB) |
| --- | --- | --- | --- | --- |
| 10 | initial_capture | 34.860 / 50.061 | 27.855 / 32.034 | 21.152 / 24.325 |
| 10 | no_op | 11.628 / 25.112 | 27.855 / 32.034 | 21.707 / 24.963 |
| 10 | small_edit | 21.981 / 26.506 | 27.855 / 32.034 | 21.770 / 25.035 |
| 10 | undo_restore | 64.807 / 130.190 | 33.207 / 38.188 | 21.738 / 24.999 |
| 100 | initial_capture | 119.121 / 180.142 | 62.812 / 72.234 | 158.773 / 182.589 |
| 100 | no_op | 91.341 / 150.744 | 77.812 / 89.484 | 159.277 / 183.169 |
| 100 | small_edit | 78.147 / 119.054 | 77.812 / 89.484 | 159.336 / 183.236 |
| 100 | undo_restore | 448.061 / 464.125 | 77.812 / 89.484 | 159.309 / 183.205 |

On this host, `wait4` peak RSS includes inherited launcher memory before exec.
A `/bin/true` probe increased from 22,278,144 to 89,223,168 bytes after a 64-MiB
parent allocation. These RSS thresholds apply to that upper-bound counter;
isolated executable-memory comparisons remain a G19 gate. Input/output block
counts are not exact device or application byte measurements. No transfer budget
is inferred from this local-only workload.

## Identity and reproducibility

- Pinned unmodified source: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`.
- Executable SHA-256: `8a7f77267e4d68907ffbf7a4999403f3906dc73ed4248f068776717a857dfec6`.
- Generator SHA-256: `9f60efce36e6515a82b444620bf8fb334438c916de05c3e82af75021e038e433`.
- Original v2 runner: `547bef4cd33c44d1068159a305b230d5ffd22b41`, SHA-256 `9f2ddbe98d617d1ee722dd05b93bd34b19822902e88d71b57515f53d717ab21e`.
- Checked-resume runner: `b0fa2492957a1e1c801833b12fe6aac7f95dd0a9`, SHA-256 `56d6f10f92b2b08eb7cea4ab9fc6ac2cbcd055655e1ea24d2b97e8e0b3b4702f`.
- Raw summary SHA-256: `91952fc8cb14e77f97a46f181b56755e92365c5271931878a408e358c106caea`.
- Compact summary SHA-256: `03e105c1c9ad56178f20b67bc1132c1a5795015d4346dce6d3c9b5f4115ed88b`.

| Live MiB | Manifest SHA-256 | Pristine/restored-base tree SHA-256 |
| --- | --- | --- |
| 10 | `4e509827536d558ebe5a7acaf2888eeaf48651aec376b5d122788f03c2675fa0` | `b6625b95d9d0e47d090658e1ac01f1660112dfa65aaa03f4ca4b3ee77b3f8160` |
| 100 | `a8c193fc4d052f78bab787cce737351f5343abaf1a677d32a98005255d99c2eb` | `a2482d6706de2a8e10389130db702506eba3e03a77ba5b21633b0ec2fb2537c4` |

Recorded commands, executed from the implementation checkout:

```sh
python3 tools/benchmark_runner.py --output /home/gongahkia/.cache/yeokcham-g01/source-local-v2 --source-tree /home/gongahkia/.cache/yeokcham-g01/pinned-source --revision d03ac1e095af7c896eede2334c5a1f5fc50c4e74 --suite source --tiers 0,1 --history-nodes 10
python3 tools/benchmark_runner.py --output /home/gongahkia/.cache/yeokcham-g01/source-local-v2 --source-tree /home/gongahkia/.cache/yeokcham-g01/pinned-source --revision d03ac1e095af7c896eede2334c5a1f5fc50c4e74 --suite source --tiers 0,1 --history-nodes 10 --resume
```

These describe the saved run. Preserve its existing output; choose a new external
output directory for a fresh comparison. Use checked `--resume` only for a genuine
interruption after confirming the previous process stopped. The runner skips
accepted records and refuses incompatible or failed inputs.

For a new unmodified source export without switching `main`:

```sh
python3 tools/benchmark_runner.py --export-baseline /absolute/new/pinned-source --switch "$PWD"
python3 tools/benchmark_runner.py --output /absolute/new/results --source-tree /absolute/new/pinned-source --revision d03ac1e095af7c896eede2334c5a1f5fc50c4e74 --suite source --tiers 0,1 --history-nodes 10
python3 tools/benchmark_summary.py /absolute/new/results/summary.json /absolute/new/summary.json
```

The export uses `git archive`, builds with the recorded switch, and verifies all
tracked file contents/symlink targets before and after building. Its provenance
JSON records the build command and executable hash. Final audit again matched the
pinned source and executable, generator and runner hashes, and verified that the
original and resumed measurement/verification code has identical parsed bodies.

## Acceptance audit and retained evidence

Each retained node restored to a separate empty directory before sampling. Each
accepted sample passed full manifest and history-position/count checks, then a
file was deliberately changed and the captured checkpoint restored into another
empty directory. That destination matched the full expected manifest. A failure
would terminate the profile rather than become a faster accepted sample.

The independent final audit reconstructed every compact sample and command from
its columns, matched the raw records, checked all unique scheduled indices,
finite metrics, allocation sums, exact counts/bytes and full pristine contents,
independently derived edited/restored tree hashes, and recomputed statistics and
budgets. The previous 294-record checkpoint and original 132 pre-interruption
records remain unchanged. No accepted v2 measurement was repeated or replaced.

- External artifact root: `/home/gongahkia/.cache/yeokcham-g01`; keep fixtures, histories, test signers, pinned export, logs and snapshots outside Git.
- Full raw snapshot: `checkpoints/final-1794610728850154352`; its five input hashes
  and terminal exit 0 are recorded in external `completion-raw-snapshot.json`.
- Independent data audit: external `completion-measurement-audit.json`, SHA-256
  `f40ccffb4aa00ea953eca8ac41646c0a74f1382ab98a46ce80e5abd537d0d441`.
- Reproducible diagnostic: external `audit_measurements.py`, SHA-256
  `0ed254515e0f06d3aa9b15db1a4b472ae2d5a4b079eb99286719dd926de56524`.
  Invoke it with the complete summary and historical partial-checkpoint paths.
  Exact command: `python3 -B /home/gongahkia/.cache/yeokcham-g01/audit_measurements.py docs/implementation/results/G01-baseline.json docs/implementation/results/G01-measurement-checkpoint.json`.
- Source/machine/storage/prefix audit: external `completion-provenance-audit.json`.
- The versioned partial checkpoint remains a historical 294-record snapshot;
  the complete summary linked above is authoritative for these measurements.

## Interval, limitations and remaining coverage

Run interval: `2026-11-06T16:17:08.144094+00:00` through `2026-11-13T22:58:12.883816+00:00` (UTC).
Checked continuation began `2026-11-12T15:28:43.290784+00:00`.
The original v2 process was absent at the November 12 audit; no exit code or cause
was available. Its 132 verified records were preserved and revalidated. The pooled
10-MiB result contains those 132 records and 20 resumed warm undo records; all
152 100-MiB records belong to the continuation. These are not an uninterrupted
session or paired comparison. Host time and process elapsed observations differ;
no cause is presumed. Changing free resources and other host work were uncontrolled.

Cold treatment is advisory file-page eviction with fsync and POSIX_FADV_DONTNEED
on worktree/store/executable files. Eviction success, directory metadata, signer
files, shared libraries and hypervisor/device caches are uncontrolled. Warm
pre-reading covers those worktree/store/executable files. This is not a cold
machine experiment. Synthetic source contents are deliberately compressible;
no general real-project performance or universal Git advantage is claimed.

The preliminary v1 profile was deliberately cancelled with exit 143 after 13
accepted records to correct untimed verification and directory allocation. Its
records remain separate and are not included here. Earlier formatter/OpenSSL
environment failures and the pinned archive CI docs-check failure due to absent
Git metadata remain disclosed in the earlier G01 evidence and reports. Actual
checkout validation uses the overrides recorded in [environment evidence](G01-environment.json)
and [resumption evidence](G01-resumption.json).

The pinned runtime lacks the target private archive/eviction, native review-policy
and integration-plan workflows, complete shared offline sync, and managed
cross-platform background scheduler. Their absence is not a passing benchmark.
Full 1-GiB source/deep/branching/monorepo/asset sessions, licensed real projects,
Git/codec comparisons, isolated executable memory, ten-minute idle CPU and
thirty-minute interference remain G19 gates. Native OS/service, complete journey,
container/package and human-evaluation gates retain their ledger owners.
