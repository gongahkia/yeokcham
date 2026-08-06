# Research and benchmark report v1

## Evidence boundary

This index links checked-in evidence; it does not rerun, combine, or rank
workloads. `schema_version: 1` selects each linked JSON interpretation. The
repository is an experimental local VCS prototype, not a production-readiness,
performance, interoperability, or semantic-safety claim.

[Measured] Values below come only from the linked v1 records. Timing values are
host-specific observations and never correctness gates. [Unverified] Results
outside the named fixtures, hosts, languages, cache states, and scripts are not
established by this report.

## Versioned evidence inventory

| Evidence | Versioned input/result | Fixture and environment metadata | Recorded boundary |
| --- | --- | --- | --- |
| Canonical codec | [result](../bench/results/canonical-codec-v1.json), [schema](../bench/schema/canonical-codec-benchmark-result.schema.json) | `nested-snapshot-v1`, SHA-256 `e123…522d6`; 10,000 iterations/20,000 operations; OCaml 5.5.0, Dune release, clean revision `767ec45…98bd` | 191 encoded bytes; 173,110,008 ns is one baseline observation, not a threshold. |
| Large content | [result](../bench/results/large-content-v1.json), [schema](../bench/schema/large-content-benchmark-result.schema.json) | 76 deterministic fixture/configuration rows, fixed seed `20260730`, five repetitions; Apple M3 arm64, 16 GiB, OCaml 5.5.0, Dune release | Representation bytes/object/reuse evidence supports ADR-022; approximate working set is not peak RSS. |
| Scratch retention | [result](experiments/results/scratch-retention-benchmark-v1.json), [schema](experiments/schema/scratch-retention-benchmark-v1.schema.json), [report](COMPACTION_RETENTION_RESULTS.md) | 25-checkpoint trace SHA-256 `77f970…6c247`, five repetitions; Unix 64-bit OCaml 5.5.0, Dune release, temporary local directory | Active-object-store bytes, physical depth, and guarded restore timings are limited to four implemented policies. |
| TypeScript retargeting | [result](experiments/results/semantic-retargeting-v1.json), [schema](experiments/schema/semantic-retargeting-v1.schema.json), [method](experiments/semantic-sidecar-v1.md) | Dataset v1, 40 shared deterministic cases; result records host-specific per-case elapsed values but no host record | Semantic and textual evidence are separate strategies over the same byte oracle. |
| Rust/TypeScript boundary | [result](experiments/results/rust-typescript-retargeting-comparison-v1.json), [schema](experiments/schema/rust-typescript-retargeting-comparison-v1.schema.json), [method](experiments/rust-typescript-retargeting-comparison-v1.md) | TypeScript dataset v1: 40 cases by reference; Rust dataset v1: six distinct fixtures | No timing comparison or cross-language rate is recorded. |

An ellipsis in a SHA-256 value abbreviates the linked full value; it is not a
replacement checksum. The TypeScript and Rust comparison records do not contain
host or run timestamp metadata. This report records that absence rather than
inventing an environment.

## Negative outcomes and limits

| Evidence | Recorded negative outcome | What does not follow |
| --- | --- | --- |
| TypeScript retargeting | Semantic has six false negatives; textual has one. Both report zero false-confident and zero false applications on this dataset. | Zero false confidence is not a general safety rate or language-wide semantic guarantee. |
| Rust boundary | Rust semantic attempts are zero; one duplicate case is a safe conflict; macro-heavy and parser-damaged cases require textual fallback. | Rust semantic rename, resolution, macro expansion, or cross-language comparison is not implemented. |
| Scratch retention | Exponential thinning, validation/test-boundary and capsule-boundary retention, content GC, and cross-domain reclamation are outside the record. | Storage/restore figures do not predict a user repository or total disk use. |
| Scripted M11 demos | Invalid roots, malformed IDs, failed validation, conflict states, and invalid Git destinations are checked as non-publication/error paths. | The demonstrations do not measure throughput, remote collaboration, signing, GitHub publication, or production reliability. |

The report itself has no parser, process, or repository mutation. The referenced
implementations expose their malformed/unsupported inputs as structured errors;
their focused tests check non-publication or preserved state where applicable.

## Scripted demonstration evidence

The M11 fixture chain is intentionally behavioral, not benchmark evidence:
[repository](DEMO_REPOSITORY.md), [recovery](DEMO_RECOVERY.md),
[compaction](DEMO_COMPACTION.md), [capsules](DEMO_CAPSULE.md),
[workspace](DEMO_WORKSPACE.md), [conflicts](DEMO_CONFLICT.md),
[retargeting](DEMO_RETARGETING.md), [release](DEMO_RELEASE.md), and
[Git export](DEMO_GIT_EXPORT.md). The final export test composes the bounded
release fixture, runs local `git fsck --full`, and checks byte/mode/symlink
oracles. It does not push, contact GitHub, or make full-Git compatibility
claims.

## Reproduce and validate

```text
make compaction-retention-benchmark-verify
make semantic-experiment-verify
make rust-retargeting-comparison-verify
python3 -m jsonschema --instance bench/results/canonical-codec-v1.json bench/schema/canonical-codec-benchmark-result.schema.json
python3 -m jsonschema --instance bench/results/large-content-v1.json bench/schema/large-content-benchmark-result.schema.json
opam exec -- dune runtest test/test_demo_git_export.exe
opam exec -- dune runtest test/test_research_and_benchmark_report.exe
make property-test PROPERTY_TEST_SEED=17
make check
```

`test_research_and_benchmark_report` checks this index's source links, metadata
absence statement, negative outcomes, and non-claim boundaries. It does not
recompute measurements or execute external tools.
