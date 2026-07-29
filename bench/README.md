# Benchmark Results

`schema/benchmark-result.schema.json` is the versioned JSON Schema for benchmark artifacts. `examples/benchmark-result-v1.json` is illustrative and is not an empirical result.

## Semantic invariants

- `schema_version` selects the complete interpretation of a record.
- `metrics.timing.samples_ns` contains one sample per completed measured repetition; warmups are excluded.
- Sample count equals `execution.completed_repetitions`. A successful run also has `completed_repetitions` equal to `repetitions`.
- `min_ns`, `median_ns`, `p95_ns`, `p99_ns`, and `max_ns` are derived from `samples_ns`; percentiles use nearest-rank selection.
- Timing values use integer nanoseconds. Sizes use integer bytes.
- A nullable metric is `null` only when it was not measured; `notes` states why.
- Commands are argument arrays, not shell-escaped strings.
- Environment contains only variables intentionally affecting the experiment and no secrets.
- Failed and timed-out runs remain valid records, retain measurements gathered before failure, and use `null` summaries when no sample completed.

Validate a result with a Draft 2020-12 implementation:

```bash
python3 -m jsonschema \
  --instance bench/examples/benchmark-result-v1.json \
  bench/schema/benchmark-result.schema.json
```
