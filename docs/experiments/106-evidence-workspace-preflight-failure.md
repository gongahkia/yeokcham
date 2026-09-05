# Experiment 106 — EVIDENCE-001 workspace capacity preflight failure

This is a failed preflight measurement, not WS-001 capacity evidence and not a
release-readiness claim. Its retained output root is external to this checkout:

```text
/home/gongahkia/Desktop/coding/projects/yeokcham-evidence-ws-5g-100k-preflight-systemd-20260905
```

On 2026-09-05, source revision
`722e68a6fbe3e9dcc1e9d37a7fd6b6f08bed149a`, the workspace harness was run for
one iteration with 100,000 paths and 5,368,709,120 logical bytes. The retained
`profile.txt`, `environment.txt`, and `run-1/benchmark-status.txt` identify
the requested profile, Fedora kernel `7.1.12-100.fc43.x86_64`, 12 online CPUs,
and the `scenario` failure stage. The process started at 00:16:43 +08 and the
user systemd service recorded an OOM kill at 01:23:59 +08 after 43 minutes
4.126 seconds of CPU time. systemd recorded a 10,239,377,408-byte memory peak
and 3 GiB swap peak. No `workspace-runs.tsv` data row was produced.

The fixture reached 100,003 source objects and 5,380,103,649 logical object
bytes before the scenario process was killed. The target did not complete
bootstrap or activation, so this run supplies neither projection correctness
nor timing evidence.

Code inspection identifies the immediate cause: after streaming the directory
package, `Package.read_artifact` read and retained every object byte string in
one artifact value. Bootstrap preparation invoked that function before it could
return the signed basis. This is an implementation defect in the package
adapter, not a change to package-manifest-v1 semantics. EVIDENCE-001 therefore
requires the streaming-artifact transition described in the active ticklist
before this profile is retried.

After that transition, source revision `12f28da` completed one scaled regression
iteration with 1,000 paths and 52,428,800 logical bytes. The retained row
reported 6.013755 s initialization, 19.527548 s bootstrap preparation,
2.542249 s package materialization, 29.504932 s bootstrap, 78.813731 s explicit
activation, 136.42 s wall time, 129.21 s user CPU, 3.68 s system CPU, and
13,876 KiB maximum RSS. Source V4 metadata, package, and target V4 metadata
used 52,822,016, 52,875,264, and 52,826,112 allocated bytes respectively. This
single reduced-profile iteration verifies the changed journey and provides
[Inference] bounded-resident-memory behavior at that profile only; it supplies
no median, tail, 5 GiB, 100,000-path, or network-performance result.

On 2026-09-05, a separate one-iteration full-profile streaming preflight was
started from source revision `5268d6ad735831ac7ff729e6714d19e8aa54b3a4` and
then intentionally terminated by the operator. Its retained external root is:

```text
/home/gongahkia/Desktop/coding/projects/yeokcham-evidence-ws-5g-100k-preflight-streaming-12f28da
```

The run started at 09:04:45 +08 and was terminated at 12:47:15 +08 after
3h 42m 30s of wall time and 10,217.191705 seconds of CPU time. systemd recorded
a 6,382,080,000-byte memory peak and 3,130,544,128-byte swap peak. The harness
recorded `status=128` and `stage=scenario`; no measurement row was produced.
Because termination was external and the pre-change harness emitted its phase
timings only on successful completion, this run establishes neither successful
activation nor a capacity timing. It is retained as incomplete diagnostic data,
not capacity evidence. The harness now preserves immediate per-phase stderr
progress for any replacement run.

On 2026-09-05, the first observable replacement preflight from source revision
`e47e4e7` was also intentionally terminated, at the retained
`source-init:start` phase, after 31m 17s of wall time and 714.086118 seconds of
CPU time. Its external root is
`/home/gongahkia/Desktop/coding/projects/yeokcham-evidence-ws-5g-100k-preflight-observable-e47e4e7`.
systemd recorded a 1,738,080,256-byte memory peak and 1,531,904-byte swap peak;
the harness retained `status=128` and `stage=scenario`. This confirms the
phase-log retention behavior but establishes no source initialization,
bootstrap, activation, timing, or capacity result.

The failed external root is retained for diagnosis until a successful
full-capacity retry has been independently summarized. It is not a repository
fixture and must not be used to report a median, p95, capacity success, or
cross-VCS comparison.
