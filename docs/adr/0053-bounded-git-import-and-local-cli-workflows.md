# ADR-0053: Import Git repositories through bounded local CLI workflows

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The core could open, traverse, verify, store, reconstruct, and export individual Git records, but users had no end-to-end command that connected those operations. An import must not publish refs until every referenced byte is reconstructable and verified. The initial local store supports one immutable ref snapshot, so retrying into a partially populated repository would create ambiguous manifests or refs.

## Decision

Expose these local commands:

- `yeokcham init --from-git <source> <destination> [--chunked-blob-minimum <bytes>]`
- `yeokcham verify <repository>`
- `yeokcham export-git <repository> <destination>`
- `yeokcham inspect object <repository> <git-object-id>`
- `yeokcham inspect storage <repository>`

Import accepts a fresh repository only. It bounds source traversal to 100,000 objects, individual object bodies to 64 MiB, segment decoding to 65 MiB, and FastCDC output to 4,096 chunks. The bootstrap representation policy aggregates blobs through 1 KiB, stores blobs below 4 KiB as whole records, and uses the existing FastCDC implementation at or above 4 KiB. `--chunked-blob-minimum` changes only the selection threshold within the same safety limits, enabling whole-versus-chunked comparison.

The importer verifies each source object ID before persistence; writes all object records, indexes, and manifests; fully verifies local immutable storage; then publishes the ref snapshot and fully verifies again. Interrupted imports can leave unreachable immutable data, but no ref is published until its target reconstructs and verifies. Users discard that fresh destination before retrying.

## Consequences

The commands establish the first supported local import/export workflow without adding a new Git porcelain or remote-helper protocol. The defaults are bootstrap compatibility settings, not performance recommendations; the benchmark harness records measured comparisons before any threshold claim changes. Import is intentionally not resumable yet, and the one-snapshot ref model rejects non-fresh destinations.

## Invariants

- Every imported Git object retains its canonical SHA-1 identity.
- Every published ref target has already been reconstructed and verified.
- SQLite metadata is never evidence of recoverability.
- All disk and parser work has explicit bounds.
- `verify`, `export-git`, and both inspect commands use the same bounded decoding policy as import.

## Compatibility and migration

The commands write existing V1/V2 persistent formats only. No migration is required. Future resumable imports or ref journals require a new ADR and cannot alter an immutable snapshot or manifest in place.

## Security and recovery

Source paths and object bytes are not emitted in normal command output. Import fails closed on malformed Git data, bounds, conflicts, or reconstruction failure. A user can recover any completed import with `verify` and `export-git` without SQLite or a hosted service.

## Verification

Core and CLI tests import packed sources across tiny, whole, and CDC representations, verify storage, inspect a chunked blob, export, run `git fsck --full --strict`, compare reachable object IDs and refs, and compare cloned checkout bytes. Pinned loose and packed history fixtures run the same object/ref/checkout/fsck checks.
