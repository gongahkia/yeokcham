# ADR-0063: Add backend fault-injection and metrics wrappers

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The runtime-neutral `Backend` contract is intended for failure tests, provider selection, and operational observation. A concrete filesystem backend alone does not prove that callers can inject a failure at the contract boundary or collect bounded provider-neutral outcomes. Wrappers must not record content, keys, sessions, or error-source details.

## Decision drivers

- Inject one deterministic pre-delegation failure in contract-level tests.
- Observe successful and failed calls without changing backend results.
- Keep counters bounded, thread-safe, and free of source data.
- State wrapper and backend consistency limits without inferring remote-provider guarantees.

## Considered options

### Option 1: generic in-process wrappers

Wrap any `Backend`, return its futures, use one atomic global fault-call position, and retain only atomic counters. Support `Box<dyn Backend>` through forwarding so callers can compose a runtime-selected backend and a wrapper.

### Option 2: add fault and metrics methods to every backend

Expand the backend contract with provider-specific instrumentation hooks. This makes every provider implement test-only behavior and leaks observability policy into the storage boundary.

### Option 3: use process crashes and external telemetry only

Exercise only filesystem crash paths and collect metrics outside the core. This cannot test provider-boundary error handling or expose a narrow reusable wrapper.

## Decision

Use Option 1. `FaultInjectingBackend` counts all attempted contract calls and returns an injected `io` error before delegating exactly one caller-selected, one-based attempt. It does not simulate a backend mutation followed by process termination; filesystem mutation-boundary crash tests remain ADR-0060's separate mechanism. Concurrent callers race for the global call index, so deterministic fault tests serialize their operations.

`MetricsBackend` records saturating atomic counters for every operation kind: attempts, successes, failures, supplied bytes for create-only/resumable writes, and returned bytes for successful reads. `metrics` returns a non-transactional snapshot. Counter updates do not modify result values or emit telemetry. Both wrappers redact their `Debug` output. A forwarding implementation lets `Box<dyn Backend>` satisfy `Backend`, allowing composition with runtime-selected providers.

## Consequences

The wrappers add atomic operations and, for metrics, post-operation bookkeeping. They do not allocate or retain source bytes, keys, session IDs, cursors, or error sources. Counts saturate at `u64::MAX` rather than wrapping. A snapshot taken during concurrent calls can contain individually valid values from different operation instants.

The wrappers do not supply retries, cancellation, locking, crash recovery, durability, list ordering, immediate visibility, or cross-object atomicity. A fault-injected error means the inner backend was not called; it says nothing about a real provider's unknown-outcome failure after request transmission.

## Invariants

- The configured fault call returns before the inner backend operation begins.
- All other wrapper calls delegate unchanged and return the inner result unchanged.
- Metrics do not retain plaintext or backend identifiers.
- Metrics counters do not wrap.
- Dynamic backend dispatch remains usable through `Box<dyn Backend>`.

## Compatibility and migration

These wrappers add no persistent format and do not alter existing backend return values. They are public additive core APIs. Future tracing export, histograms, latency, cancellation, and provider-specific request identifiers require a separate observability policy.

## Security and recovery

Aggregate byte counts can reveal activity volume, so core does not log them. Metrics do not authenticate data or establish visibility. Recovery must treat every backend read, listing result, and `AlreadyExists` metadata as untrusted until the existing format, checksum, signature, and Git-ID checks finish.

## Verification

Core tests prove that an injected first put fails before its filesystem backend can publish an object, that later operations delegate, that a boxed dynamic backend can be wrapped, and that metrics record successful and failed calls plus supplied/returned bytes. Formatting, Clippy with warnings denied, full core tests, rustdoc, CI, and fuzz smoke run before acceptance.
