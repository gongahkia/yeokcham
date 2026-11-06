# Existing-runtime measurement harness (G01)

The fixture generator and CLI runner use Python 3.11+ and the documented OCaml
build environment. They do not change product code. Large artifacts belong outside
the checkout. No benchmark is a passing correctness test until restored contents
match its full manifest, including directories, executable bits and symlink targets.

## Fixtures

```sh
python3 tools/benchmark_fixture.py /absolute/external/fixture \
  --manifest /absolute/external/fixture.json --suite source \
  --bytes 10485760 --files 1000 --seed 1 --depth 3 --fanout 8
python3 tools/benchmark_fixture.py /absolute/external/fixture \
  --manifest /absolute/external/fixture.json --verify
python3 -B -m unittest discover -s test -p 'test_benchmark_fixture.py' -v
```

Existing roots are refused. The manifest must stay outside the generated tree.
Version 1 uses SHAKE-256 keyed by seed, file index and block index; sorted manifest
entries contain SHA-256 content identities and a canonical JSON tree digest.
Total regular-file bytes and file count are independent and exact. No timestamps
or absolute paths enter the digest. Files are streamed in bounded blocks.

`source` mixes source-like text, documentation/config/test names and reusable text;
it is synthetic and deliberately quite compressible, not a licensed real project
or general product performance claim. `monorepo` adds package layout and mixes text,
opaque bytes and gzip streams. `asset` uses the same mixed content without package
layout. Gzip members contain deterministic high-entropy payloads and zero padding;
very tiny custom files below a member's minimum size contain only padding.
`--large-file-bytes 1073741824` dedicates the first file to at least 1 GiB for an
explicit large-file case. `--attributes` adds executable state, an empty directory,
and a relative symlink; these do not change regular-file bytes/count.

The runner's source tiers are 10 MiB/1,000, 100 MiB/10,000 and 1 GiB/100,000;
monorepo tiers are 1/10/50 GiB with 100,000/500,000/1,000,000 files; asset tiers
are 1/10/50 GiB with 1,000/10,000/50,000 files. Custom bytes/count and layout
parameters allow independent variations. The full extended suites are G19 gates.

## Runs and pinned comparison

Build with `make setup && make build`. The default runner selects all ordinary
source tiers; G01 deliberately selects only indexes 0 and 1. On Linux, with a
fresh output directory:

```sh
python3 tools/benchmark_runner.py --output /absolute/external/source-local \
  --suite source --tiers 0,1 --history-nodes 10
```

The runner checks tracked source against the given Git revision (default HEAD),
records executable/generator/runner hashes, and refuses an output inside the
implementation checkout. Commit owned source changes before measuring HEAD.
A caller must build the recorded source before invoking the runner; a binary
hash identifies the executable but cannot by itself prove its build provenance.

To compare against the unmodified pinned source later, without switching `main`:

```sh
python3 tools/benchmark_runner.py \
  --export-baseline /absolute/external/pinned-source --switch "$PWD"
python3 tools/benchmark_runner.py --output /absolute/external/pinned-results \
  --source-tree /absolute/external/pinned-source \
  --revision d03ac1e095af7c896eede2334c5a1f5fc50c4e74 \
  --suite source --tiers 0,1 --history-nodes 10
```

The export command uses `git archive`, builds with the existing switch, and checks
every tracked file against that revision both before and after build. Its small
provenance JSON sits alongside the export. This is a disposable baseline source
export, never another implementation checkout or branch. Generated build products
are permitted; tracked source edits are rejected. The same runner and fixtures
serve both binaries. Keep sample counts/settings identical for a comparison.

Explicit extended commands (G19, potentially hours and tens/hundreds of GiB):

```sh
python3 tools/benchmark_runner.py --output /absolute/external/monorepo --suite monorepo
python3 tools/benchmark_runner.py --output /absolute/external/assets --suite asset \
  --large-file-bytes 1073741824 --tiers 1,2
python3 tools/benchmark_runner.py --output /absolute/external/deep \
  --tiers 0 --history-nodes 1000 --history-shape branching
```

Allow at least four times live size plus history, temporary restore/store growth,
and filesystem inode overhead. These are lower-bound planning estimates, not disk
capacity guarantees. Only one sample copy lives at a time. The 10,000-node tier is
selected by `--history-nodes 10000`; history size is not a fixed runtime limit.
Full manifests and results remain under each output directory. Never commit the
`signers` directory: it contains disposable test-only private keys. CLI stdout,
including the initialization recovery mnemonic, is discarded after use and never
included in result manifests. Existing test signer support is used explicitly;
this does not validate native Secret Service/Keychain custody performance.

## Measurement and correctness semantics

Each case builds and restores every node of a retained history before samples.
Linear history replaces 64 bytes (or the entire file if smaller) in one file per
node. Branching history returns to node 0 on alternating edits and repeats earlier
contents every third nonfinal node. An initial capture starts with no repository
and measures `init`, including its recovery/identity ceremony: it ends with **one**
node. Other operations start from an identical **N-node** repository each time;
small edit adds one node, no-op adds none, and undo returns to node 0. Thus a
10-node workload does not pretend initial capture already has 10 nodes.

Defaults are 5 cold samples and 30 warm samples after 3 excluded warmups for each
operation. Warmups are retained in raw data, excluded from summaries. Every command
starts a fresh process. Each sample uses an independently copied repository outside
the clock; cache preparation and full-tree verification are also outside the clock.
Cold means `fsync` then `POSIX_FADV_DONTNEED` on worktree/store/executable files.
This is advisory file-page eviction, **not** a cold machine: directory metadata,
shared libraries, hypervisor/device caches and eviction success are uncontrolled.
Warm means pre-reading these files. Hosts without `posix_fadvise` must explicitly
use `--cold 0` and report missing cold coverage; that is not a full G01 profile.

Wall time includes CLI startup and exit. `wait4` supplies per-process user/system
CPU, peak RSS and input/output block counts (not exact application or device bytes).
Stored file bytes and allocated bytes are measured separately after each operation,
before the extra fidelity restore changes recovery metadata. Logical captured bytes
are live bytes times retained nodes, including repeated contents. No network,
watcher, remote server, packing or codec setting is introduced by this harness.

After timing, the runner verifies files and history node count/current position,
then changes a tracked file and forces a restore to the measured checkpoint. Only
an exact manifest match accepts the sample. It checks opaque bytes, executable
state, directories and links when present. A command failure or mismatch writes a
failed result and exits nonzero; it never becomes a faster passing sample. Full
manifests identify every path and SHA-256. Small summaries retain all sample metrics
and command templates. Median, nearest-rank p95, sample standard deviation and
range are derived from all accepted measured samples, never the best sample alone.

The pinned baseline lacks the target private archive/eviction, native review-policy
workflow, exact integration-plan workflow, full shared offline synchronization and
managed cross-platform background scheduler. Their absence is **not** a benchmark
pass. Existing low-level relay/proposal/watch features do not establish those target
operations. Ten-minute idle CPU, thirty-minute interference, real-project fixtures,
Git comparisons, deep/full/extended tiers and native-platform comparisons remain
explicit G19/G20 coverage gates.

## Small evidence and review thresholds

```sh
python3 tools/benchmark_summary.py /absolute/external/source-local/summary.json \
  /absolute/external/source-local-summary.json
python3 -B -m unittest discover -s test -p 'test_benchmark_*.py' -v
```

The summarizer refuses failed or incomplete sample sets. Its column-keyed arrays
retain every sample (including excluded warmups), CPU/RSS/block metrics, storage
sizes and verified tree hashes. It prints readable latency statistics and records
concrete per-operation investigation budgets: baseline warm median/p95 times 1.10,
and maximum measured peak RSS/allocated storage times 1.15. They apply only to the
same machine, filesystem, fixture, retained states, cache treatment and settings;
repeat a breached case before deciding it is a regression. These are review
thresholds, not latency guarantees or a substitute for the G19 evidence gate.
