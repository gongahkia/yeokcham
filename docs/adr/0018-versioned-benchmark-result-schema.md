# ADR-0018: Use a versioned JSON Schema for benchmark results

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Yeokcham performance claims must remain traceable to a commit, fixture, environment, configuration, and complete measurement set. Free-form benchmark output omits context easily, changes shape silently, and cannot be validated mechanically.

## Decision drivers

- Results must cover every field required by `TESTING_AND_BENCHMARKS.md`.
- Units and provenance must be unambiguous.
- Schema and example validity must be testable offline.
- Synthetic validation data must not be mistaken for measured evidence.
- Format evolution must not reinterpret historical results.

## Considered options

### Free-form Markdown or CSV

These are easy to inspect but cannot represent nested environment and configuration data consistently or reject missing context reliably.

### Unversioned JSON

This is machine-readable but allows silent semantic and structural drift.

### Versioned JSON Schema

This provides a portable validation contract, explicit evolution, nested metadata, and broadly available tooling.

## Decision

Benchmark results conform to JSON Schema Draft 2020-12. Version 1 requires Yeokcham and tool provenance, hardware and storage details, fixture identity and SHA-256 checksum, cache/backend configuration, network conditions, run parameters, median/p95/p99 wall time, CPU time, peak RSS, I/O, network traffic, requests, and final storage size.

Field names carry numeric units. Unknown fields are rejected except inside explicitly open fixture and benchmark parameter maps. Results state whether they are measured or synthetic validation data and assert that sensitive data is absent. Measured versioned results are immutable; incompatible semantic or structural changes create a new schema version and migration note.

## Consequences

Benchmark producers must collect complete metadata before publishing a result. Consumers can compare like-for-like data and reject incomplete records. Schema evolution requires deliberate version management. Flexible parameter maps remain producer-defined and need workload documentation.

## Invariants

- Every performance claim links to a valid measured result and immutable fixture checksum.
- Synthetic validation examples are never performance evidence.
- Numeric units never depend on external prose.

## Compatibility and migration

This introduces benchmark result format version 1. There are no earlier machine-readable results to migrate.

## Security and recovery

Results prohibit secrets, source content, private paths, and remote URLs. Producers must redact open parameter maps before persistence. Benchmark records are evidence, not canonical repository recovery data.

## Verification

Tests validate the schema against its Draft 2020-12 meta-schema, validate the synthetic example with format checks enabled, and reject missing provenance, negative measurements, and unknown top-level fields.
