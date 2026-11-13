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

An interrupted run can continue with the same command plus `--resume`, after
checking that its previous process has stopped. A missing process/session is
evidence of interruption; a stale `running` JSON or an observation timeout alone
is insufficient. A per-output process lock prevents concurrent new runners.
Resume refuses failed runs, changed workload/counts, source/binary/generator
identities, or machine/toolchain/filesystem identities. Free-memory and free-disk
readings may vary and are retained for each continuation. A runner code change
is allowed only when its recorded committed source matches its hash and the
parsed measurement functions, verification functions and complete timed sample
body are unchanged.

Before continuing, byte-for-byte summary/case snapshots and their hashes are
preserved under an external `resumption-*` directory. Every pristine path and
retained checkpoint is checked again, along with history position/storage and
the exact accepted sample prefix. Accepted records remain untouched; a leftover
in-flight sample is renamed `interrupted-sample-*` for inspection and measured
again from a fresh copy. An interrupted case preparation with no accepted result
is preserved as `interrupted-preparation-*` and rebuilt. Continuation metadata
records the timestamp, machine, invocation, runner provenance and accepted count
per case before the continuation.
Those counts delimit the segments in sample order, including a later tier that
had not started (zero accepted). Disclose interruptions and the time gap when
reporting pooled statistics; they are not an uninterrupted session or paired
comparison. A failed or changed input must be investigated, never overwritten
with a resumed passing record.

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

Each case builds a retained history and restores every node into a separate empty
directory before samples. This leaves the fixture at its latest node without adding
untimed navigation proofs to its metadata.
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
On this Linux host, the peak RSS counter also includes inherited launcher memory
before `exec`. A `/bin/true` probe rose from 22,278,144 to 89,223,168 bytes after
allocating 64 MiB in its Python parent. Thus `peak_rss_bytes` is a process/launcher
upper bound, not isolated executable RSS; continuation launcher footprints can
differ. Retain the raw counter and this limitation when interpreting its 15%
investigation budget. Isolated executable memory comparisons remain a G19 task.
Stored file bytes and allocated bytes are measured separately after each operation.
Allocation includes both regular-file and directory blocks (with separate counters),
including the metadata root directory. It is checked against `du -sk` in the focused
tests. Verification writes only to a separate disposable directory. Logical
captured bytes are live bytes times retained nodes, including repeated contents. No network,
watcher, remote server, packing or codec setting is introduced by this harness.

After timing, the runner verifies files and history node count/current position,
then changes a tracked file and runs the existing
`restore --checkpoint ID --destination EMPTY_DIRECTORY` command. The destination
must match the captured manifest even though the live file now differs, proving
that verification reads stored objects. The timed undo operation itself also has
its restored worktree checked before this extra verification. Only an exact
manifest match accepts a sample. It checks opaque bytes, executable
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

## Harness revision and preliminary run

Run/summary schema v2 uses destination restoration for untimed verification and
includes directory allocation. Version 1 performed a redundant in-place undo after
every sample and navigated through all nodes during setup, creating extra proof
metadata. On this WSL2 host, a destination restore of the 10-MiB fixture matched its
full manifest in 4.963 seconds while the extra in-place verifier took minutes.

The original `source-local` run was deliberately terminated (exit 143) after 13
accepted sample/warmup records to correct this harness work and allocation metric.
The complete preliminary records, interruption context and probe are preserved
outside Git in `preliminary-cancellation.json`. They are not merged into v2 results.
The full profile uses a fresh `source-local-v2` output with unchanged fixture bytes,
file counts, history depth, timed CLI commands and 5/3/30 sampling. This is a harness
revision, not a runtime optimization or an omitted correctness gate. Earlier
reports document their then-live process; its old status file is no longer a
liveness signal. Use the new run's verified process/session handle.

## Preserving accepted measurements between sessions

Read the [progress ledger](../IMPLEMENTATION_PROGRESS.md), its latest report and
[committed measurement checkpoint](results/G01-measurement-checkpoint.json) before
starting work. The runner saves each accepted record atomically. Its checked
`--resume` path skips the accepted prefix; a new session must monitor an existing
live runner rather than start another run. Old report handles are historical;
verify the current process before deciding whether resumption is needed.

The committed checkpoint backs up every accepted sample metric and command,
fixture hashes, source/binary/generator/runner provenance, machine settings and
continuation boundaries. Its schema is `yeokcham-benchmark-checkpoint-v1` and its
status is explicitly `in_progress`. Statistics are labelled `statistics_so_far`;
this file never passes the full-baseline completion gate. The normal summarizer
continues to require a complete passing run.

Keep `/home/gongahkia/.cache/yeokcham-g01/`, including the pinned export, fixture
manifests, retained histories, disposable signers, raw results and snapshots.
Exact resumption needs these external artifacts; the committed metrics are a
backup of measurement evidence, not a replacement for retained history or keys.
Large fixtures and secrets stay outside Git. Completed records must remain
unchanged; do not rerun them to replace slow timings or overwrite earlier reports.

Refresh the small committed checkpoint after completed operation groups or before
a handoff while the run is in progress. Once the run passes, use the normal
complete-run summarizer instead of this partial export. The export below reads
atomic per-case records without changing the
runner, preserves byte-for-byte inputs outside Git, checks their accepted prefix,
and records their hashes. Run from the repository root; update the observation
PID if the verified runner changes. Commit the checkpoint and relevant ledger
update after `make docs-check` and `git diff --check`.

```sh
python3 -B - /home/gongahkia/.cache/yeokcham-g01/source-local-v2 \
  docs/implementation/results/G01-measurement-checkpoint.json <<'PY'
"""Run from the implementation checkout; preserve accepted in-progress data."""
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path.cwd() / 'tools'))
import benchmark_runner as runner
from benchmark_summary import COLUMNS

run = runner.assert_external(Path(sys.argv[1]))
destination = Path(sys.argv[2])
archive = run.parent / 'checkpoints' / ('documentation-' + str(time.time_ns()))
archive.mkdir(parents=True)
hashes = {}

def preserve(path):
    data = path.read_bytes()
    relative = path.relative_to(run)
    saved = archive / relative
    saved.parent.mkdir(parents=True, exist_ok=True)
    saved.write_bytes(data)
    hashes[str(relative)] = hashlib.sha256(data).hexdigest()
    return json.loads(data)

raw = preserve(run / 'summary.json')
assert raw['status'] == 'running' and not raw['failures']
result = {k: v for k, v in raw.items() if k not in ('schema', 'status', 'cases')}
result.update(schema='yeokcham-benchmark-checkpoint-v1', status='in_progress',
              purpose='Accepted partial measurements only; not full G01 completion evidence',
              captured_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
              input_snapshot=str(archive), sample_columns=COLUMNS, cases=[])
schedule = [(op, temp, i) for op in runner.OPERATIONS
            for temp, n in [('cold', raw['settings']['cold']), ('warmup', raw['settings']['warmups']),
                            ('warm', raw['settings']['warm'])] for i in range(n)]
for path in sorted(run.glob('source-*/result.json')):
    case = preserve(path)
    samples = case['samples']
    assert case['status'] in ('running', 'passed') and not case['failures']
    assert [(s['operation'], s['temperature'], s['index']) for s in samples] == schedule[:len(samples)]
    assert len(samples) <= len(schedule)
    assert case['status'] != 'passed' or len(samples) == len(schedule)
    reduced = {k: v for k, v in case.items() if k not in ('samples', 'summary')}
    reduced.update(statistics_so_far=runner.summarize(samples), commands={}, samples=[])
    for sample in samples:
        command = reduced['commands'].setdefault(sample['operation'], sample['command'])
        assert command == sample['command']
        storage = sample['storage']
        values = dict(sample, stored_file_bytes=storage['file_bytes'],
                      allocated_file_bytes=storage['allocated_file_bytes'],
                      allocated_directory_bytes=storage['allocated_directory_bytes'],
                      allocated_bytes=storage['allocated_bytes'], stored_files=storage['files'],
                      stored_directories=storage['directories'])
        row = [values[column] for column in COLUMNS]
        assert dict(zip(COLUMNS, row)) == {column: values[column] for column in COLUMNS}
        reduced['samples'].append(row)
    result['cases'].append(reduced)
result['input_sha256'] = hashes
result['process_observation'] = subprocess.run(
    ['ps', '-p', '154851', '-o', 'pid,etime,stat,args'], capture_output=True, text=True).stdout
temporary = destination.with_suffix(destination.suffix + '.tmp')
temporary.write_text(json.dumps(result, separators=(',', ':')) + '\n')
temporary.replace(destination)
total = sum(len(case['samples']) for case in result['cases'])
print(json.dumps({'destination': str(destination), 'accepted_records': total,
                  'snapshot': str(archive), 'status': result['status']}))
PY
```
