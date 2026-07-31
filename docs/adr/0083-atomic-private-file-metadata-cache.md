# ADR-0083: Persist disposable file metadata through an atomic private cache

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The polling monitor has a process-local metadata baseline. Restarting a daemon should be able to retain a validated baseline without making that cache canonical repository state.

## Decision

`FileMetadataCache` writes one versioned `YKFC` snapshot atomically with a repository ID, sorted relative paths, non-following file metadata, and bounded timestamps. It rejects symbolic-link cache files and non-private Unix permissions, writes new files at mode `0600`, syncs the staged file and parent directory, and can clear the file independently of all repositories.

## Consequences

The cache avoids an initial metadata-only rescan after restart when its caller associates it with the same repository/root. It retains source path metadata locally, so callers must keep it in a user-private directory. Corruption fails closed and the cache is disposable.

## Invariants

- The cache contains no file bodies, object data, credentials, or keys.
- A cache snapshot is bound to one validated repository ID.
- Replacing or clearing it never mutates a source, Git repository, or Yeokcham store.
- Every accepted entry is sorted, unique, relative, and bounded.

## Compatibility and migration

`YKFC` V1 is an optional local cache, not a repository format. Unsupported versions fail closed; deleting the cache is the migration and recovery path.

## Security and recovery

The cache is private on Unix, path-redacted in debug output, and rejects symlink files. It is not encrypted and must not be placed in a shared directory. Recovery relies on a fresh monitor scan, never this cache.

## Verification

Tests prove monitor-snapshot round trips, repository binding, private Unix mode, corruption rejection, clear behavior, ordering checks, and debug redaction.
