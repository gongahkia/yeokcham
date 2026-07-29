# ADR-0033: Store verified Git object metadata in a local versioned SQLite database

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Milestone 1 needs a durable local mapping from a verified Git object ID to the minimal facts later storage and reconstruction steps will need. The existing repository bootstrap is canonical binary state, while the architecture explicitly reserves SQLite for local metadata and coordination. No segment, manifest, or remote portable record exists yet, so metadata must not become a hidden recovery dependency.

## Decision drivers

- Persist only facts independently verified from Git canonical bytes.
- Keep the existing V1 repository-layout contract readable without a directory migration.
- Version the SQLite schema independently and reject unknown versions.
- Avoid storing source bytes, keys, or storage representations before their formats exist.
- Reject database symlinks, malformed rows, and conflicting records.
- Keep Rust 1.85 support consistent across macOS and Linux builds.

## Considered options

### Extend the bootstrap record

The bootstrap is small, canonical, and repository-wide. Rewriting it per object would make routine coordination updates expensive and incorrectly make object metadata canonical recovery state.

### Write an ad hoc metadata file per object

This creates unbounded file counts and lacks transactional conflict handling, schema inspection, and later indexed queries.

### Add a new required repository-layout directory

Existing V1 repositories would then fail the fixed-layout validation until an explicit repository-format migration existed. This slice does not require a canonical format migration.

### Local SQLite database

SQLite provides transactional local records and schema versioning while leaving canonical portable metadata for later manifests and journals.

## Decision

Use exact `rusqlite 0.37.0` with its `bundled` SQLite feature. The bundle removes system-SQLite version variance from the supported macOS and Linux build environments; dependency upgrades require the normal Rust 1.85 review.

Create `metadata.sqlite3` lazily at the repository root. It is deliberately outside the fixed V1 required-directory list, so opening a repository created before this slice does not require migration. The connection resolves the validated repository root, refuses a final database symlink through both filesystem inspection and `SQLITE_OPEN_NOFOLLOW`, disables trusted schema behavior, and uses immediate transactions with no implicit busy wait.

SQLite `application_id` is `YKMD` (`0x594b4d44`) and `user_version` is schema version 1. An all-zero new database is initialized transactionally; an invalid identity is corrupt data and an unknown version is unsupported.

Schema version 1 contains exactly one table:

```text
object_metadata(
  git_object_id BLOB PRIMARY KEY CHECK(length = 20),
  kind INTEGER CHECK(1 <= kind <= 4),
  size INTEGER CHECK(size >= 0)
) WITHOUT ROWID
```

`LocalRepository::record_object_metadata` verifies the supplied `GitObject` ID from its canonical Git type/header/body bytes before opening SQLite. It inserts the ID, type, and decompressed body size only. A repeated identical record is idempotent; an existing record with different type or size is a conflict and is never replaced. `object_metadata` validates decoded kind and nonnegative size before returning local metadata.

## Consequences

The import path can retain durable verified object facts without storing source content twice. The project acquires a bundled C SQLite build dependency and a local `metadata.sqlite3` file. Future object-to-manifest, segment, ref, and migration tables extend the SQLite schema through explicit migrations; they do not change this record in place without a new schema version.

## Invariants

- A recorded ID has passed canonical SHA-1 Git-object verification in the same call.
- Metadata contains no object body, key, manifest, segment, or remote canonical record.
- IDs are exactly 20 bytes; kinds are blob/tree/commit/tag encodings 1 through 4; sizes are nonnegative signed SQLite integers decoded as `u64`.
- A conflicting record is not overwritten.
- Unknown schema versions and malformed local metadata fail closed.
- Default errors do not disclose database paths, Git IDs, or object bodies.

## Compatibility and migration

The V1 binary repository bootstrap and required layout are unchanged. New repositories do not gain a database until metadata is first recorded. SQLite schema version 1 is local state; later versions require an explicit transactional migration or a clear unsupported error. Rebuilding local metadata from verified canonical records remains a supported recovery path once those records exist.

## Security and recovery

SQLite is acceleration and coordination state, not the only canonical copy of any remote or repository metadata. Deleting it must not lose reconstructable data once manifests and journals are implemented. This slice has no recovery record to reconstruct yet, so it persists only verified identifiers, type, and size. Symlink rejection, fixed SQL, typed parameter binding, schema identity checks, and row validation limit hostile local-database behavior. SQLite write conflicts fail rather than selecting a last writer.

## Verification

Unit tests record all four Git object kinds, verify persistence after reopening, verify idempotence and absent lookups, reject an altered body before database creation, reject conflicting and invalid rows, reject a future schema version, and reject a symlinked database. Full formatting, lint, test, documentation, and macOS/Linux Rust 1.85 CI run before acceptance.
