# Experiment 101 — EVIDENCE-001 explicit workspace benchmark method

This is the reproducible WS-001 measurement procedure. It measures a complete
local source-to-projection journey, without representing a benchmark result as
a release or compatibility claim.

The deterministic fixture has exactly the requested number of directory and
regular-file paths and requested logical bytes. One run then:

1. creates a signed source repository from that fixture;
2. creates a bootstrap package and verified basis;
3. bootstraps an empty target and refuses if bootstrap materialised ordinary
   source; and
4. explicitly activates the projection, then compares every ordinary target
   entry against the source fixture.

The source fixture, package, target, and per-run resource files are temporary
children of the supplied output directory. Only `profile.txt` and
`workspace-runs.tsv` remain after a successful run. No output path may be
inside the source repository.

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
explicit activation, process wall/user/system CPU time, and maximum RSS. Report
the median and p95 only after preserving all five rows. Record host CPU,
memory, filesystem, kernel, free space, and any thermal/power conditions beside
the raw result. This method has no network leg; Experiment 102 must measure
TRANSPORT-002 separately under the stated link conditions.
