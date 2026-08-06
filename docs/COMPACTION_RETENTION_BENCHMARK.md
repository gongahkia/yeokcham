# Scratch retention benchmark

## M3-D03 scope

`scratch-retention-policies-v1` measures the implemented M3 policy knobs on one
deterministic 25-checkpoint, single-file trace. The fixture pins checkpoint 8
and restores it after each compaction; it does not claim to model user intent,
test boundaries, capsule boundaries, or a general workload.

The four compared policies are:

- `keep-all`: the full fixture is inside the recent window.
- `recent-window`: six seconds of recent checkpoints plus the pin and head.
- `periodic`: six-second buckets plus the pin and head.
- `storage-budget`: an explicit 1,200-byte checkpoint/event budget plus the pin
  and head.

Each isolated temporary repository is compacted, quarantined records are
pruned, and the pinned target is restored with the ordinary guarded restore.
The record contains the bytes of active `.yeokcham/objects` after that prune, the
maximum generated physical event-chain depth, and one guarded-restore timing
per repetition. Quarantine bytes are intentionally excluded from the storage
metric. Timings include safety-checkpoint handling and are host-specific
evidence, not correctness gates or performance claims.

The experiment records no unsupported policy as if it existed. Exponential
thinning, validation/test-boundary retention, and capsule-boundary retention
remain separate work; this benchmark only observes the planner implemented in
M3.

## Reproduce

```text
make compaction-retention-benchmark
make compaction-retention-benchmark-verify
opam exec -- dune runtest test/test_compaction_retention_benchmark.exe
make property-test PROPERTY_TEST_SEED=17
```

The checked-in [result](experiments/results/scratch-retention-benchmark-v1.json)
uses five repetitions on its recorded host. Its
[schema](experiments/schema/scratch-retention-benchmark-v1.schema.json) is
documentation evidence, not a Yeokcham persistent format. The published
[measurement report](COMPACTION_RETENTION_RESULTS.md) preserves the same
host-specific and unsupported-case limits.
