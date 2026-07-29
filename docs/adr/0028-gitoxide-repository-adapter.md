# ADR-0028: Open Git repositories through a minimal gitoxide adapter

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Milestone 1 must import existing ordinary Git repositories without reimplementing Git discovery, repository layout, pack access, or configuration parsing. The adapter must accept an explicit bare repository or worktree path while preserving Yeokcham's classified, redacted error contract.

## Decision drivers

- Use a maintained Git implementation instead of reimplementing Git primitives.
- Keep the external library type outside Yeokcham's public API.
- Do not read `GIT_*` environment overrides or global configuration during import opening.
- Reject untrusted repository directories and malformed local configuration before later object parsing.
- Keep the Rust 1.85 MSRV.

## Considered options

### Invoke the `git` executable in implementation code

This would defer Git parsing to C Git but makes object reading, errors, and failure injection process-dependent. C Git remains an integration-test oracle, not the implementation dependency.

### Use libgit2 bindings

This is mature but adds a C library boundary and platform build/distribution surface before the first import slice needs it.

### Use gitoxide `gix`

`gix` is a maintained Rust Git implementation. Version 0.85.0 declares Rust 1.85 support and its `open::Options::isolated` mode prevents access beyond repository-local configuration.

## Decision

Use `gix = 0.85.0` with default features disabled and only `sha1` and `sha256` enabled. The exact version pin protects the declared MSRV; upgrades require explicit compatibility review. `GitRepository` owns `gix::ThreadSafeRepository` privately.

`GitRepository::open` requires an explicit existing path and uses isolated, strict configuration with `bail_if_untrusted(true)`. It does not search parent directories or honor `GIT_DIR`. It exposes Git-directory and optional worktree paths, followed by Yeokcham-owned regular-ref enumeration, reachable-object traversal, and bounded object-body read APIs; ID verification remains later work.

## Consequences

Yeokcham opens bare and worktree repositories through a Rust library while retaining C Git fixtures for compatibility tests. Error sources stay internal to the structured `Error` type. The dependency graph grows substantially; `gix-protocol` transitively includes transport support, but Yeokcham enables no `gix` remote, credential, or command feature and invokes none of those APIs.

## Invariants

- A returned adapter represents an explicitly addressed, ownership-checked Git repository.
- Opening does not use Git environment overrides or global configuration.
- `gix` types do not appear in Yeokcham's public API.
- Missing paths, non-repositories, untrusted directories, I/O, and corrupt configuration have classified errors.

## Compatibility and migration

This introduces no Yeokcham persistent format. The adapter opens existing Git SHA-1 and SHA-256 repositories; the later hash-format policy task determines which are accepted for import and records the rejection behaviour.

## Security and recovery

Isolated opening confines configuration reads to the target repository. Strict configuration and ownership checking fail before import trusts repository state. Default error rendering does not disclose the supplied path or `gix` diagnostics. Recovery remains independent of this library because Yeokcham persistent records do not store `gix` data.

## Verification

Tests initialize C Git bare and worktree repositories, open both through the adapter, and reject missing and non-repository paths without default path disclosure. MSRV and stable CI cover the pinned dependency graph.
