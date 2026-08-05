# ADR-0017: Use allowlisted structured tracing

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Yeokcham needs diagnostics for import, reconstruction, storage, recovery, and remote operations. These operations handle source bytes, paths, refs, credentials, keys, and identifiers that can reveal repository contents or topology. Conventional interpolation and unrestricted error logging can disclose that data.

## Decision drivers

- Diagnostics must support structured filtering and future metrics.
- Verbose logging must not weaken confidentiality.
- Library code must not control process-global collection.
- Invalid logging configuration must fail clearly without echoing its value.
- The implementation must support the project MSRV.

## Considered options

### Ad hoc stderr messages

This has minimal dependencies but lacks structured fields, spans, filtering, and consistent redaction review.

### Unrestricted structured tracing

This improves diagnostics but permits sensitive values and dependency errors to enter logs accidentally.

### Structured tracing with an allowlist

This provides consistent instrumentation while treating every field as denied unless documented safe.

## Decision

Use `tracing` for spans and events and `tracing-subscriber` at executable boundaries. Libraries do not install global subscribers. CLI tracing writes to stderr, defaults to `warn`, disables ANSI output, and accepts strictly parsed directives from `YEOKCHAM_LOG`.

Messages and event names are static. Fields follow [`OBSERVABILITY.md`](../OBSERVABILITY.md): only operational categories, safe error data, versions, counts, sizes, durations, booleans, and non-sensitive modes are allowed. Raw content, repository metadata, identifiers, secrets, environment values, error sources, and dependency error formatting are denied. `Redacted<T>` provides a fixed `<redacted>` marker only when a field cannot be omitted.

## Consequences

Instrumentation is reviewable and machine-processable. Some diagnostics contain less direct context and require explicit inspection commands. Adding events requires field-level confidentiality review. Subscriber setup adds dependencies to executable crates but not to core library APIs.

## Invariants

- Increasing trace verbosity never reveals denied data.
- Library crates never install a global subscriber.
- Default error and tracing output never render source chains.

## Compatibility and migration

This changes no persistent format or external protocol. `YEOKCHAM_LOG` is an unstable pre-release diagnostic interface.

## Security and recovery

The allowlist reduces accidental plaintext and metadata disclosure. A redaction wrapper does not erase values from memory and is not a secret-storage primitive. Explicit diagnostic commands must state their disclosure scope before accessing source chains or identifiers.

## Verification

Unit tests prove redacted `Debug` and `Display` formatting. CLI subprocess tests prove default filtering, debug event emission, rejection of invalid directives, and absence of a sentinel secret from errors. CI runs Clippy, tests, and rustdoc on supported platforms and toolchains.
