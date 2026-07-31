# Benchmark results

Benchmark results use [`benchmark-result-v1.schema.json`](schema/benchmark-result-v1.schema.json), a JSON Schema Draft 2020-12 contract. Every recorded number has an explicit unit in its field name and is accompanied by tool versions, hardware, storage, cache, backend, network, fixture, configuration, and run metadata.

`result_kind` distinguishes measured results from synthetic schema-validation data. The committed example is synthetic and is not performance evidence. Real results must set `result_kind` to `measured`, use an immutable fixture checksum and Yeokcham commit, and set `worktree_dirty` accurately.

Results must not contain credentials, keys, source content, private paths, remote URLs, or other sensitive data. `contains_sensitive_data` is fixed to `false`; producers must redact configuration parameters before writing a result.

`io_bytes_read` and `io_bytes_written` may be `null` only when the platform collector cannot report byte counts; `null` is not zero I/O. The initial macOS whole-vs-chunked harness records CPU, peak RSS, wall time, and final storage size, and uses `null` for unavailable byte-level I/O counters.

Run `scripts/benchmark-whole-vs-chunked.sh [output-directory] [repetitions]` on macOS after `make fixtures`. It compares a pinned two-revision SHA-1 history under whole-record and CDC policies, writes two schema-validated measured result files, and makes no performance claim by itself.

Run `scripts/benchmark-sparse-workspace.sh [output-directory] [repetitions]` on macOS for W5. It generates a deterministic sparse fixture, imports it once, then times the documented `blob:none` + cone sparse `app/` checkout after clearing the snapshot-pack cache for each cold repetition, after one helper warm-up, and after a configured daemon prebuilds that cache. The daemon-prebuilt result times only the later helper checkout, not daemon startup or prewarm. `network_bytes_received` is the received Git-client `.pack` payload size across the local remote-helper transport; it is not a physical-network measurement. OS filesystem caches are not cleared.

Run `scripts/benchmark-parallel-import.sh [output-directory] [repetitions]` on macOS to compare serial and two-worker source-object reads during local import. It creates a deterministic eight-object, 32 MiB packed fixture under a private temporary directory and records end-to-end import metrics. It does not clear OS filesystem caches or establish a general import-performance claim.

[`2026-07-31-sparse-workspace`](results/2026-07-31-sparse-workspace/) records five clean macOS Apple M3 samples at commit `4d31ebe`: 0.83 s median cold and 0.30 s median warm time to the selected workspace, with 772 B median received pack payload in both states. This local fixture result is not a general remote-backend performance claim.

Version 1 is immutable after measured results exist. Backward-compatible descriptions may be clarified, but removing fields, changing meaning or units, or tightening accepted values requires a new schema version and migration note.
