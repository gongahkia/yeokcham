# Benchmark design

Status: implementation planning, November 6, 2026. No benchmark results are
claimed here. Product decisions are in [Product design](PRODUCT_DESIGN.md),
especially D04, D15, D19, and D20.

## Priority and purpose

Benchmark ordinary source-code projects first, larger monorepos second, and
large binary/asset repositories third. This is the order of optimization work,
not permission to omit later categories from correctness or performance
validation. Supporting many nontraditional code files is a product requirement.

Measure responsiveness and background resource use as well as storage and
transfer efficiency. A smaller archive is not an improvement if frequent capture
or ordinary restoration becomes impractical. Initial targets must come from
reproducible baselines; no universal speedup over Git is assumed.

## Workload matrix

These are proposed initial fixture sizes, not approved maximum repository sizes
or measured limits. Adjust fixture construction to represent real projects and
record any changes. Keep file count and total bytes independently configurable.

| Priority | Workload | Initial fixture targets | Required variations |
| --- | --- | --- | --- |
| 1 | Ordinary source-code projects | Approximately 10 MiB, 100 MiB, and 1 GiB of tracked contents; representative 1,000 / 10,000 / 100,000-file cases | Many small files versus fewer larger files; directory depth/fanout; source plus config, documentation, and test fixtures. |
| 2 | Larger monorepos | Approximately 1 GiB, 10 GiB, and 50 GiB; 100,000 through 1,000,000 files | Tiny changes within a large tree; bulk renames; generated-file churn; mixed-language and mixed-asset trees. |
| 3 | Binary and asset repositories | Approximately 1 GiB, 10 GiB, and 50 GiB; both many small assets and a few files of 1 GiB or larger | Documents, images, audio/video, archives, datasets, and other opaque bytes; mixed source/asset repositories. |

Also vary captured history depth, initially 10, 1,000, and 10,000 checkpoints,
including branches and repeated returns to identical contents. Every run states
the live tree size, file count, history length, logical captured bytes, and
physical stored bytes. Source-code size alone is not a sufficient description
of the workload.

Represent highly compressible, partially reusable, and poorly compressible
contents. Include already-compressed file formats and modifications that replace
most bytes, not only append-only text and repeated zero-filled files. Validate
that synthetic compressibility and edit patterns resemble the intended case;
do not present synthetic best cases as general product results.

Use deterministic generators and fixed seeds. Supplement them with appropriately
licensed real project snapshots pinned to exact revisions and content manifests.
Generate large fixtures outside the repository; do not commit multi-gigabyte test
data. Dataset preparation and downloads are separate from measured operation time.

## Operations and editing sessions

Measure each applicable operation separately and as part of a sustained session:

1. Initial capture and initial download, including files never previously read.
2. No-op inspection/capture, idle watching, and service startup/reconciliation.
3. A small edit in one file, multiple independent edits, append, insertion,
   deletion, rename, and complete replacement. Include analogous binary changes.
4. Bursts of editor/tool writes and large generated-file changes under explicit
   `.yeokchamignore` rules. State which files the benchmark actually includes;
   do not depend on runtime `.gitignore` inheritance to reduce the dataset.
5. Local history inspection, branching undo/redo, and exact restoration.
6. Shared change publication, integration-plan computation, and integration.
   Time preview computation and application separately; exclude human reading
   and confirmation delay from algorithm latency. Measure optional-review and
   required-approval paths separately from direct integration.
7. Warm incremental sync, a large missing-object backlog, disconnect/reconnect,
   and resumption after process restart without retransferring completed work
   unnecessarily.
8. Offline inspection and activation of an unvisited but downloaded version.
9. Private backup, archive verification, local eviction, and cold restoration
   from the remote archive, including its required dependency closure.
10. Compression, packing, history/index maintenance, and collection during an
    editing session. Report their total work as well as foreground interference.

Run cold and warm cache cases where applicable and define what was reset.
Exercise the agreed 30-day / 5-GiB / 20-GiB policy using controllable time and
capacity in the harness; also test protected-data overages, remote quota failures,
and offline pending uploads. Size changes for test practicality must be explicit.

## Measurements and comparison

Record wall-clock latency distributions, CPU time, idle and active background
CPU, peak resident memory, bytes read and written, allocated disk space, metadata
size, network bytes, and time to reach verified backup/offline availability.
Report sample counts, median and tail latency, variability, and failures rather
than only the best run. Bound memory for large files; a workload exceeding RAM
must not be hidden by excluding failed captures from the results.

For Git comparisons, use the same file set, recorded states, retained history,
and availability requirements. Publish exact commands and configuration. Compare
native operations independently from any scripted continuous-capture workflow;
include the automation cost when comparing full workflows. Account for packing,
maintenance, and later restore costs rather than stopping measurement before
deferred work. Do not compare a partial/shallow dataset with a full retained one
without clearly identifying the changed contract.

Record CPU, RAM, storage device/filesystem, OS, toolchain, tool versions, revision,
codec/packing settings, watcher policy, ignore rules, network conditions, and
server configuration. Use local or controlled self-hosted servers to separate
client/storage performance from uncontrolled network variability. Repeat initial
workloads on macOS and Linux; add Windows as its implementation becomes available.
Do not combine results from different machines into an unexplained ranking.

## Correctness gates and reporting

Before treating a timing result as valid, verify recovered bytes and supported
filesystem attributes against the expected snapshot. Opaque or invalid-text
contents must survive capture, backup, archival, and restoration exactly. Include
mixed-file repositories and concurrent incompatible opaque-file edits; a fast
result that discards one version or corrupts content is a failure.

Check that incomplete uploads do not permit eviction of a sole local copy,
protected roots remain retained, archived restoration fails without worktree
mutation when offline, and stale integration previews cannot authorize a changed
plan. Measure these paths where useful, but retain them as correctness gates even
when a performance comparison is unavailable.

The default benchmark entry point runs ordinary source-project size tiers.
Provide separate explicit suites for monorepos and binary/assets, with their
disk/runtime requirements stated up front. The extended suites remain required
evidence for storage-design decisions and claims about large/non-source-code
repositories; they need not run on every small documentation or code change.

Output machine-readable run data and a readable report grouped by workload,
size, history depth, and platform. Baseline measurements should lead to concrete
regression budgets for responsiveness, background cost, growth, and recovery.
Record those budgets and the hardware assumptions before treating a performance
handoff as complete. The current design deliberately makes no invented numeric
latency guarantee in advance of measurement.
