# Compaction retention results

## Scope and provenance

This report publishes the versioned
[M3-D03 input/result](experiments/results/scratch-retention-benchmark-v1.json)
under its
[v1 schema](experiments/schema/scratch-retention-benchmark-v1.schema.json).
The runner and fixture contract are documented in
[the benchmark protocol](COMPACTION_RETENTION_BENCHMARK.md). It is a local,
host-specific measurement report, not a persistent format, policy guarantee, or
performance threshold.

## Recorded environment

The result was recorded with five measured repetitions, no warm-ups, one
concurrent run, and mixed cache state. It records `Unix`, 64-bit OCaml 5.5.0,
the Dune `release` profile, and a temporary local-directory repository. Each
repetition builds an isolated 25-checkpoint single-file trace, pins checkpoint
8, compacts, prunes temporary quarantine records, and invokes guarded restore
to that pin.

`active_object_store_bytes` counts only active `.yeokcham/objects` bytes after
that temporary-repository prune. It excludes quarantined records and does not
claim a full cross-domain repository size. `max_physical_event_depth` is the
largest number of generated physical events from the oldest retained entry;
direct snapshot resolution can avoid replaying that full chain. `median_restore_ns`
is the lower median of the five guarded-restore samples, including
safety-checkpoint handling.

## Recorded measurements

| Implemented policy | Retained checkpoints | Active object-store bytes | Max physical event depth | Median restore ns |
| --- | ---: | ---: | ---: | ---: |
| keep-all | 25 | 20,628 | 24 | 14,883,995 |
| recent-window | 2 | 10,956 | 1 | 7,522,821 |
| periodic | 6 | 13,003 | 5 | 9,823,799 |
| storage-budget | 3 | 12,040 | 2 | 8,667,945 |

[Measurement] Every one of the 20 recorded samples has
`restored_pinned_target: true`; the benchmark therefore verified its retained
pin after compaction and prune. The broader retained-state/replay invariant is
also covered by `test/test_compaction.ml` and `test/compaction_property_test.ml`.

[Inference] On this one trace and host, fewer retained generated checkpoints
coincide with fewer active object bytes and shorter reported restore medians
than keep-all. This is not a general causal, workload, or cross-host claim.

## Limits and unsupported cases

The report measures only M3's implemented keep-all, recent-window, periodic,
and storage-budget selectors. It does not measure exponential thinning,
validation/test-boundary retention, capsule-boundary retention, content GC,
cross-domain size reclamation, networked repositories, or user-intent quality.
It does not rank policies, set a performance target, or generalize timing
outside the recorded environment.

Reproduce the evidence with:

```text
make compaction-retention-benchmark
make compaction-retention-benchmark-verify
opam exec -- dune runtest test/test_compaction_retention_benchmark.exe
make property-test PROPERTY_TEST_SEED=17
```
