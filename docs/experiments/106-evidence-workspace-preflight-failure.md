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

The failed external root is retained for diagnosis until a successful retry has
been independently summarized. It is not a repository fixture and must not be
used to report a median, p95, capacity success, or cross-VCS comparison.
