# Benchmark results

Benchmark results use [`benchmark-result-v1.schema.json`](schema/benchmark-result-v1.schema.json), a JSON Schema Draft 2020-12 contract. Every recorded number has an explicit unit in its field name and is accompanied by tool versions, hardware, storage, cache, backend, network, fixture, configuration, and run metadata.

`result_kind` distinguishes measured results from synthetic schema-validation data. The committed example is synthetic and is not performance evidence. Real results must set `result_kind` to `measured`, use an immutable fixture checksum and Yeokcham commit, and set `worktree_dirty` accurately.

Results must not contain credentials, keys, source content, private paths, remote URLs, or other sensitive data. `contains_sensitive_data` is fixed to `false`; producers must redact configuration parameters before writing a result.

Version 1 is immutable after measured results exist. Backward-compatible descriptions may be clarified, but removing fields, changing meaning or units, or tightening accepted values requires a new schema version and migration note.
