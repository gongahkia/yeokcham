# ADR-0081: Discover only validated Yeokcham stores under explicit roots

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The daemon needs bounded local repository discovery. There is no persisted mapping from arbitrary Git worktrees to Yeokcham stores, so broad Git scanning would find unmanaged source repositories and introduce unnecessary source metadata collection.

## Decision drivers

- Never scan a user's home directory or parent paths implicitly.
- Avoid following symbolic links outside a caller-owned root.
- Return only fully validated Yeokcham stores.
- Bound directory traversal and result allocation.

## Considered options

### Option 1: Scan all Git repositories below a default home directory

This discovers unmanaged source repositories, depends on an implicit privacy-sensitive root, and can follow arbitrary Git worktree layouts.

### Option 2: Maintain a mutable registration database before discovery

This adds daemon state before there is a listener, lifecycle, or recovery model for that state.

### Option 3: Scan explicit roots for validated Yeokcham store bootstraps

Accept a caller-provided root and recognize only directories that fully open as local Yeokcham repositories.

## Decision

Use Option 3. `discover_local_repositories` performs breadth-first scanning below one non-symlink directory supplied by the caller. It recognizes a candidate only after its regular `format/repository.bin` marker and complete `LocalRepository::open` validation succeed. It does not enter valid or malformed candidates, does not dereference symlinks, bounds directories, results, and entries sorted from any directory, sorts results by exact path, and reports opaque counts for skipped links, unreadable directories, and malformed candidates.

## Consequences

Discovery cannot infer source Git worktrees or register repositories. A later daemon API can let users select explicit store roots and separately attach source-monitoring state.

## Invariants

- Discovery never traverses a symbolic link or implicit parent/home root.
- Every returned repository has passed normal bootstrap/layout validation.
- Limits fail closed rather than return an unbounded partial result.
- Skip reports contain counts, not source paths or malformed data.

## Compatibility and migration

No persistent state or format migration. The API is process-local and daemon removal leaves repositories unchanged.

## Security and recovery

Caller-selected paths remain necessary output, but debug rendering redacts them. Symlinks and malformed bootstrap layouts cannot redirect scanning or become registered repositories. Recovery does not depend on discovery state.

## Verification

Tests cover sorted discovery, validation, no descent into stores, malformed candidates, root and count limits, debug redaction, and Unix symlink refusal.
