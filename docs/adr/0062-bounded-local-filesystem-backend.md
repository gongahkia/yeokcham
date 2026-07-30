# ADR-0062: Implement bounded local backend object storage

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The new backend contract needs one concrete implementation to prove create-only publication, bounded range reads, listing, deletion, and resumable upload semantics before a remote provider is added. The filesystem implementation must not inherit path traversal, symlink following, or in-place overwrite behavior from a naïve path join.

## Decision drivers

- Keep stored object bytes exactly as supplied by the backend caller.
- Publish immutable files without replacement.
- Bound read and list allocation/work before returning data.
- Support interrupted sequential uploads without exposing partial destination files.
- Make local consistency and blocking behavior explicit.

## Considered options

### Option 1: direct key-to-path mapping with private resumable staging

Map validated opaque keys beneath a caller-owned root. Reserve one root child for private sessions. Stage immutable files in their destination directory and publish through hard links without replacement.

### Option 2: SQLite-backed object store

Store backend objects inside one database. This obscures the object-store semantics required for Drive and makes ranged object transfer and recovery inspection less direct.

### Option 3: reuse the local repository layout

Treat Yeokcham's local repository directories as a backend. This couples the backend abstraction to unencrypted implementation details and local metadata.

## Decision

Use Option 1 in `FilesystemBackend`. `create` creates a root and private `.yeokcham-uploads/` directory; `open` validates both. Safe backend keys map directly below the root. The reserved upload prefix and recognized temporary staging names cannot be published as ordinary objects or returned by list.

`put_if_absent` creates a same-directory staging file, writes and synchronizes it, hard-links it to the final key without replacement, synchronizes the destination directory, then removes the staging file. An existing target returns `AlreadyExists` metadata. `get` validates each parent and the final regular file, rejects a range outside the current object length, and enforces the caller byte bound. It rereads metadata after the data copy to detect a changed length. Local listing recursively scans only under caller scan bounds, excludes private uploads, returns lexical pages, and treats malformed or symlinked entries as corruption.

Resumable sessions create one synchronized private staging file keyed by a UUID session identifier. Writes must begin at the current exact length and may not exceed the declared total. Completion requires the exact total length, publishes through the same hard-link path, and is idempotent after an already-completed session. Abort is idempotent. Session IDs and recovery of abandoned upload files are backend-specific; the current interface does not persist sessions in repository metadata.

## Consequences

The filesystem backend performs blocking local I/O inside a runtime-neutral future when polled. It is appropriate for direct local use or an executor's blocking facility, not a guarantee of nonblocking execution. Its lexical list order and immediate local visibility are implementation details, not guarantees of `Backend`.

Object bytes are plaintext and this backend is not connected to Yeokcham repository publication. Encryption, opaque encrypted keys, session persistence, remote-provider multipart behavior, and backend garbage collection remain separate work.

## Invariants

- A completed immutable put never overwrites an existing destination.
- Partial resumable data is confined to the private upload directory.
- Ranged reads and list traversal remain caller-bounded.
- Root, parent directories, objects, and private uploads reject symlinks and invalid filesystem types.
- List never returns private upload or recognized staging files as backend objects.

## Compatibility and migration

The backend root has no versioned Yeokcham repository format and is not yet a recovery source. Existing repository layout and Git workflows remain unchanged. A future encrypted backend format must introduce its own opaque key and envelope versioning rather than reinterpret these plaintext files.

## Security and recovery

Key validation rejects traversal components before path mapping. Reads and mutations revalidate relevant filesystem types, but concurrent local hostile mutation can still race ordinary filesystem calls; returned bytes require higher-level checksum, signature, and Git-ID verification before trust. Private session paths and backend keys are redacted by default diagnostics.

## Verification

Core tests prove create-only puts, bounded full/range reads, deterministic local pagination, deletion, sequential resumable writes, incomplete-upload rejection, idempotent completion, reserved-prefix rejection, redacted debug output, and symlink-root rejection. Clippy and rustdoc run with warnings denied.
