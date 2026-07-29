# ADR-0044: Publish and scan immutable local blob manifests

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

`YKMF` manifests now name one verified blob representation, but no local durable operation publishes those records or resolves a Git blob ID to them. SQLite cannot be the only mapping because it is disposable local coordination state. Multiple immutable manifests can validly describe one Git blob as policy evolves, so selecting one by directory order would hide a conflict.

## Decision drivers

- Keep a portable manifest file as the local recovery source.
- Publish without replacing a manifest ID or exposing a partial final file.
- Bound directory traversal and individual file reads.
- Detect malformed paths, foreign manifests, corruption, and ambiguity before resolution.
- Avoid adding a mutable canonical index before ref/journal design exists.

## Considered options

### Resolve only through SQLite

This is faster but turns local metadata into an unrecoverable single point of failure.

### Pick the first matching manifest from the filesystem

Directory order is not a representation-selection policy and would silently discard valid competing representations.

### Publish immutable manifest files and boundedly scan them

This is linear in manifest count but preserves a simple recovery path. A later rebuildable local index can accelerate it without becoming authoritative.

## Decision

Publish each `BlobManifest` at `manifests/blobs/<lowercase-manifest-uuid>.ykmf`. The embedded repository and manifest IDs must match the repository and filename. Publication writes a same-directory create-new `.<uuid>.partial`, synchronizes it, creates the final path by hard link without overwrite, synchronizes the directory, and removes the staging file. Identical republishing is idempotent; differing bytes under an existing manifest ID are a conflict.

`resolve_blob_manifest` scans final files with caller-selected limits for directory entries, one manifest's bytes, and declared blob plaintext bytes. It ignores only recognized staging names and rejects all other unexpected names, symlinks, nonregular files, foreign repository IDs, filename/manifest-ID mismatch, malformed bytes, and bound violations. It returns `None` when absent and a `Conflict` when more than one verified manifest matches the requested Git blob ID.

## Consequences

Manifests are now durable local recovery records independent of SQLite. Resolution is intentionally O(number of manifest directory entries) in this slice; a later index must be rebuildable from these files and retain the same ambiguity semantics. This does not yet verify the referenced segment payload or choose a representation; those are later reconstruction tasks.

## Invariants

- Final manifest files are immutable and never overwritten.
- A manifest's repository ID and filename identity match before it is accepted.
- Partial staging files are not resolved.
- Every resolved manifest is decoded under explicit bounds.
- Multiple valid manifests for one Git blob are reported as conflict, never selected implicitly.
- SQLite deletion does not prevent manifest publication or resolution.

## Compatibility and migration

The published path convention stores existing `YKMF` bytes unchanged. Existing repositories need no bootstrap or SQLite migration. Future sharding, encrypted filenames, remote keys, or rebuildable lookup indexes require a new documented path/index contract and copy-on-write publication; existing manifest files remain readable.

## Security and recovery

Directory entries and manifest bytes are hostile. The scan bounds work before reading an unbounded directory or file, rejects symlinks and identity mismatches, and returns redacted errors. SHA-256 verifies manifest bytes but is not backend authentication. A missing/corrupt manifest is visible during recovery; resolution does not trust an index, SQLite, or a segment without later independent verification.

## Verification

Tests cover no-SQLite publish/resolve/reopen, idempotent publication, same-ID conflicts, ambiguous Git-ID matches, staging-file handling, entry/file limits, corrupt and foreign manifests, malformed directory entries, symlinks, invalid limits, and thread-safety. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
