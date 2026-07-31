# ADR-0101: Copy V1 repositories to verified V2 destinations

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

V2 adds checked local `YKRE` ref journals. Existing V1 repositories need an
explicit upgrade path that leaves a complete rollback source and does not trust
partially copied data.

## Decision drivers

- Preserve a readable V1 rollback source.
- Verify source and destination canonical state under explicit bounds.
- Exclude disposable state and avoid network or credential dependencies.
- Fail closed on corruption or an existing destination.

## Considered options

### In-place bootstrap replacement

This is small but removes the V1 rollback source and makes interruption
recovery depend on local bootstrap replacement state.

### Copy to a new absent destination

This retains the V1 source and makes a failed target disposable. It requires
temporary additional storage and retry starts from a new destination.

## Decision

`yeokcham migrate <source-v1-repo> <destination-v2-repo>` copies a verified V1
repository to an absent destination. It verifies and scans the source before
creating the destination, copies canonical files except the bootstrap, writes
a V2 bootstrap last, and fully verifies the new repository before reporting
success.

## Consequences

The V1 source remains available for rollback. Failed targets may remain on disk
and must be explicitly removed before retrying. The migration is restartable,
not resumable, and requires space for a second canonical repository.

## Invariants

- The source is never written by migration.
- Source verification succeeds before destination creation.
- Destination bootstrap and immutable storage verify before success.
- SQLite and recognized staging files are never migration inputs or outputs.
- The destination preserves the repository ID and all supported feature flags;
  only the version changes from V1 to V2.

## Compatibility and migration

The implementation supports only V1-to-V2. V2 or unsupported sources fail
without destination creation. V1-only readers reject a V2 destination. Future
format migrations require a separate ADR, version/feature definition, and
interruption-recovery contract.

## Security and recovery

Migration performs no backend, GitHub, Drive, or credential operation. It uses
the same bounded canonical-file validation as encrypted recovery and fails on
symlinks, unexpected paths, malformed records, or verification failures. Keep
the V1 source until the V2 destination is independently verified and backed up.

## Verification

Core tests prove a populated V1 repository copies to V2, preserves the V1
bootstrap, excludes SQLite and staging files, and verifies the destination.
They also prove corrupt, V2, and preexisting-target inputs fail safely. CLI
tests cover command parsing. No performance claim is made.
