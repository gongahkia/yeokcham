# ADR-0089: Read and verify bounded Git object batches in parallel

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: ADR-0028
- Superseded by: None

## Context

Git import verifies every source object's SHA-1 identity before storage. The existing single-threaded adapter leaves independent object decompression and hashing serial even on multi-core hosts. Gitoxide's `ThreadSafeRepository` becomes `Send` only with its `parallel` feature; its thread-local repository values remain isolated per worker.

## Decision drivers

- Preserve exact source-object verification before any object reaches canonical storage.
- Bound concurrent decompressed object bodies and worker count.
- Preserve deterministic storage and ref-publication order.
- Retain isolated Git opening and Rust 1.85 support.

## Considered options

### Keep all source reads serial

This preserves the prior resource profile but leaves independently hashable large objects on one core.

### Share one adapter instance across workers

`ThreadSafeRepository` is deliberately not `Sync`; sharing it is invalid.

### Clone a Send adapter for bounded scoped workers

Each worker owns a cloned adapter and creates its own thread-local Git repository. Read batches retain at most 64 MiB of object bodies, use at most eight workers, and publish their verified results in source-ID order.

## Decision

Enable gitoxide's `parallel` feature and use cloned `ThreadSafeRepository` handles only in bounded scoped import-read workers. The initial import policy selects `min(available_parallelism, 8)` workers. An explicit worker override accepts one through eight workers. Batches below 2 MiB and single-object batches remain serial; segment writes, SQLite updates, manifest publication, final verification, and ref publication remain serial.

## Consequences

Import can use multiple cores for independent source-object reads and SHA-1 verification while retaining deterministic canonical writes. The adapter feature graph changes and reading a source concurrently remains only a point-in-time operation, as it was before. Large singleton objects are not parallelized because Git's object ID is a sequential SHA-1 input.

## Invariants

- Every stored object still verifies against its requested Git object ID.
- A batch never buffers more than 64 MiB of declared object body bytes before serial publication.
- Read failure prevents publication of that failed or later ordered object.
- Immutable records, refs, crash recovery, and repository formats remain unchanged.

## Compatibility and migration

No persistent format, protocol, or migration change. Existing stores and exports are unchanged. Rollback returns source reads to serial operation without touching stored data.

## Security and recovery

Worker-local adapters retain isolated, strict, ownership-checked opening. Object size bounds are checked before body allocation. No source body is logged. A source mutation can still cause a checked read failure; recovery remains the existing verified import/export path.

## Verification

Core tests compare serial and multi-worker import output, verify exported Git object sets with C Git, reject invalid worker counts, and prove a bounded oversized batch stays serial. The macOS parallel-import benchmark records serial and multi-worker wall time, CPU time, RSS, and storage for a deterministic large-object fixture before any performance claim is made.
