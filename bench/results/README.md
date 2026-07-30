# Canonical codec baselines

`canonical-codec-v1.json` is a host-specific baseline, not a performance claim. Regenerate it with `make benchmark-encoding`; it executes exactly 10,000 fixed nested-snapshot encode/decode iterations and records the 20,000 total operations, one enveloped object size, elapsed nanoseconds, versions, revision, working-tree state, and timestamp.

Validate the result with:

```bash
python3 -m jsonschema \
  --instance bench/results/canonical-codec-v1.json \
  bench/schema/canonical-codec-benchmark-result.schema.json
```

## Large-content decision result

`large-content-v1.json` records deterministic candidate comparisons used by ADR-022. Regenerate it with `make benchmark-large-content`. It is host-specific evidence, not a performance target.
