# Experiment 101 — EVIDENCE-001 explicit workspace benchmark method

This is the reproducible WS-001 measurement procedure. It measures a complete
local source-to-projection journey, without representing a benchmark result as
a release or compatibility claim.

The deterministic fixture has exactly the requested number of directory and
regular-file paths and requested logical bytes. Each regular file begins with
its deterministic eight-byte file identifier, so the fixture cannot collapse
into repeated content-addressed objects; its remaining bytes come from a
deterministic high-bit LCG stream. The profile therefore requires at least
eight logical bytes per generated regular file. One run then:

1. creates a signed source repository from that fixture;
2. creates a bootstrap package and verified basis;
3. bootstraps an empty target and refuses if bootstrap materialised ordinary
   source; and
4. explicitly activates the projection, then compares every ordinary target
   entry against the source fixture.

The source fixture, package, target, and per-run resource files are temporary
children of the supplied output directory. Only `profile.txt`,
`environment.txt`, and `workspace-runs.tsv` remain after a successful run.
`environment.txt` records the kernel, online CPU count, `lscpu`, byte-based
memory report, and filesystem capacity/free-space report captured before the
first iteration. No output path may be inside the source repository.

Run the required target profile on a Linux host with sufficient free disk for
the source, package, and target copies:

```sh
opam exec -- dune build @all
tools/run-evidence-workspace-benchmark.sh \
  --output /absolute/external/yeokcham-ws-5g-100k \
  --paths 100000 \
  --bytes 5368709120 \
  --iterations 5
```

The TSV retains one independently measured run per row: fixture profile,
source init, bootstrap preparation, package materialisation, bootstrap,
explicit activation, process wall/user/system CPU time, maximum RSS, and the
allocated byte count of the source V4 metadata, bootstrap package, and target
V4 metadata. The size fields use GNU [du] with a one-byte block size; they
therefore include filesystem allocation for regular files and directories, not
only apparent file lengths. Report the median and p95 only after preserving all
five rows. Record host CPU, memory, filesystem, kernel, free space, and any
thermal/power conditions beside the raw result. This method has no network leg;
Experiment 102 must measure TRANSPORT-002 separately under the stated link
conditions.

Summarize the retained five rows without changing them:

```sh
tools/summarize-evidence-workspace-benchmark.sh \
  --input /absolute/external/yeokcham-ws-5g-100k/workspace-runs.tsv \
  --iterations 5
```

The summary refuses missing, malformed, inconsistent, or count-mismatched
input. It uses the observed middle row as the median and the nearest-rank p95;
for five runs that p95 is the highest observed value. Its plain-text output is
a derived report, never a V4 record or a replacement for the raw TSV.

If a fixture, scenario, projection check, or measurement fails, the current
external `run-N/benchmark-status.txt` retains the schema version, nonzero exit
status, and named stage. Successful runs retain no child run directory, so a
status file never represents a successful measurement. This is operational
diagnostic data, not a V4 record or a benchmark result.
