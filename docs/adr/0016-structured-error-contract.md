# ADR-0016: Use an opaque structured core error contract

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Yeokcham must distinguish validation, compatibility, corruption, conflict, I/O, and internal failures across library, CLI, protocol, and logging boundaries. Free-form strings are not machine-readable, while exposing dependency errors directly couples public APIs to dependencies and can leak paths, repository content, or backend details.

## Decision drivers

- Callers must branch on broad failure classes without parsing text.
- Default output and logs must not expose source content or sensitive context.
- Underlying errors must remain available for explicit diagnosis.
- The public API must remain evolvable as subsystems are added.
- Error handling must work on the project MSRV.

## Considered options

### Free-form or boxed dynamic errors

This is convenient for application code but makes recovery decisions depend on text or downcasting and weakens the public contract.

### Public enum containing every subsystem error

This provides exhaustive matching but exposes dependency types and makes routine internal changes breaking API changes.

### Opaque error with a structured kind

This separates a stable classification from private representation and retained diagnostic sources.

## Decision

`yeokcham-core` exposes an opaque `Error`, a non-exhaustive `ErrorKind`, and a `Result<T>` alias. Every error has a stable machine-readable kind code and a static, redacted public message. Default `Display` and `Debug` output omit the source chain; callers may inspect `std::error::Error::source` explicitly in controlled diagnostics. Error sources must implement `Send + Sync + 'static`.

Core and library APIs return typed Yeokcham errors rather than `anyhow::Error`, strings, or dependency errors. Binaries may add presentation context at their outer boundary but must preserve the structured kind. `thiserror` derives the standard error plumbing without becoming part of the public API.

## Consequences

Callers can make recovery and exit-status decisions using `ErrorKind`. Dependency changes do not alter the public error representation. Default diagnostics deliberately contain less detail; privileged diagnostic paths must opt in to inspecting sources and apply redaction rules. New broad classifications may be added because `ErrorKind` is non-exhaustive.

## Invariants

- Error formatting does not include source details by default.
- Error kinds and codes do not depend on human-readable messages.
- Expected runtime failures use `Result`, not panics.

## Compatibility and migration

This introduces the first public error contract and changes no persistent format. Existing code has no error API to migrate.

## Security and recovery

Public messages are static so repository bytes, paths, refs, credentials, and keys cannot be interpolated accidentally. Retained sources may contain sensitive data and must not be logged without explicit sanitisation. Corruption and conflict remain distinct classes so callers can fail closed or request resolution.

## Verification

Unit tests verify classification, stable codes, source chaining, `Send + Sync`, and source redaction from `Display` and `Debug`. CI checks the implementation on the MSRV and current stable Rust.
