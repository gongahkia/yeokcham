# ADR-0050: Export published objects as standard loose Git objects

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The local store can reconstruct and verify every currently published blob, tree, commit, and tag, but users cannot yet recover those objects into a conventional Git object database. Ref persistence is not implemented, so this slice cannot produce a complete named repository or claim a `git fsck` round trip.

## Decision

Export every published `YKMF` and `YKOM` manifest into a new bare SHA-1 Git repository as standard zlib-compressed loose objects. Use gitoxide to initialize the bare repository and the maintained `flate2` crate with its `zlib-rs` backend to write the exact canonical `<type> <size>\0<body>` byte stream. Verify every reconstructed Git ID before compression and create loose-object paths without replacement.

The destination must not exist. The operation scans manifests with caller-provided bounds, reconstructs through the existing segment verification boundary, synchronizes output files and directories, and returns a count only on success. It intentionally restores no refs; that remains a separate operation.

## Consequences

The output is readable by ordinary Git object commands but contains no reachable refs yet. A later ref-restoration operation can publish names only after all target objects are present. Export is not a filesystem snapshot: source or destination mutation during the operation can cause failure. Failed export can leave an incomplete destination, which callers must discard before retrying.

## Invariants

- Every exported object has a final verified SHA-1 Git ID.
- Exported bytes use Git's canonical loose-object header and zlib stream.
- A destination is never replaced or merged with an existing directory.
- SQLite and indexes are not required for export.
- No successful result is returned before output objects and bare-repository metadata are synchronized.

## Compatibility and migration

This adds no Yeokcham persistent record or migration. The output is an ordinary SHA-1 bare Git repository. Pack export, SHA-256 Git repositories, refs, and working-tree checkout remain later work.

## Security and recovery

Manifest, segment, and output paths are validated as regular non-symlinked files or directories at each trust boundary. Resource limits apply before reading manifest or segment payloads. Diagnostics do not include object bodies. Git object IDs and zlib integrity are checked by Git-compatible readers after export; backend authentication and encryption remain deferred.

## Verification

Tests export binary blob/tree/commit/tag objects, read their exact types and bodies through C Git, reject existing destinations and source limits, test canonical loose headers, and test public limit types. Full formatting, lint, tests, docs, and Linux Rust 1.85 CI must pass before acceptance.
