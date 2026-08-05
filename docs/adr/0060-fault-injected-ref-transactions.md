# ADR-0060: Fault-inject local bootstrap and ref-journal transactions

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Local push imports immutable objects before publishing one checked ref transition. A transition may first replace `repository.bin` to enable the journal and then publish an immutable ref-event file. Existing regular tests prove success and ordinary errors but cannot demonstrate the restart state after interruption at each durable mutation boundary.

## Decision drivers

- Exercise real local filesystem publication rather than a mock-only state model.
- Keep the production storage format and API unchanged.
- Cover every bootstrap and journal mutation in the acknowledged ref transition.
- Reopen and verify physical on-disk state after each injected interruption.

## Considered options

### Option 1: transaction-scoped fault-injecting filesystem wrapper

Route bootstrap replacement and ref-event staging, synchronization, publication, and cleanup through one internal filesystem trait. A test wrapper delegates each action to the host filesystem, records the completed boundary, then aborts at a selected boundary.

### Option 2: process-wide filesystem mocking

Intercept all filesystem calls in the repository. This would change unrelated storage and export paths before their crash contracts are defined, and makes the first crash-safety slice difficult to audit.

## Decision

Use Option 1. The internal `LocalRepositoryFilesystem` supports create-new staging files, writes, file synchronization, rename, hard-link, removal, and directory synchronization. Production uses `HostFilesystem`. Tests use `FaultInjectingFilesystem`, which performs the host operation then aborts after the selected completed mutation.

The harness establishes an imported V1 repository, appends its first ref event, records the complete ordered boundary list, and reruns once for every boundary. It covers bootstrap staging create/write/sync, bootstrap replacement/directory sync, and event staging create/write/sync, final hard-link publication/directory sync, and staging cleanup/removal sync. After each injected interruption it opens a fresh `LocalRepository`, materializes refs, and runs full repository verification. Only the predecessor or successor ref state is accepted.

## Consequences

The test model checks durable API boundaries rather than filesystem-sector behavior. It proves the recovery behavior of observed complete host operations; operating-system or hardware reorder behavior outside file and directory synchronization remains a platform assumption.

The wrapper only covers the acknowledged bootstrap and ref-event transaction. Object segments, indexes, and manifests are immutable and written before it; an interrupted import can leave unreachable records, but the transaction does not publish refs until required target reconstruction succeeds. Their own crash-injection coverage can be added without changing the journal contract.

## Invariants

- A mutation boundary is recorded only after its host filesystem operation completes.
- An injected interruption returns no successful transition result.
- Reopened state is exactly the complete predecessor or complete successor state.
- A published event is immutable and remains independently decodable and verified after restart.
- Unreachable immutable records are never interpreted as acknowledged refs.

## Compatibility and migration

This changes no on-disk bytes, repository-format version, CLI behavior, or recovery procedure. The internal wrapper is only used by tests; production continues to execute the same filesystem operations through `HostFilesystem`.

## Security and recovery

Fault tests run against actual temporary local repositories and reopen through normal validation, so malformed partial staging files are exercised by recovery. Staging files are not canonical evidence and recognized journal staging names remain ignored. The test wrapper records no source bytes, object IDs, ref names, or keys.

## Verification

The core test fixes the expected list of 12 transaction boundaries, injects one crash after every boundary, reopens the repository, materializes its refs, and runs repository verification. Existing integration tests continue to prove that push sends success only after the canonical journal append returns.
