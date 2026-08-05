# ADR-0030: Traverse bounded SHA-1 Git object graphs without tag peeling

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Milestone 1 must determine every Git object required to import a repository. Regular refs can point directly to any object or symbolically to another ref. Commits, trees, and annotated tags add graph edges; blobs do not. The walk must preserve tag objects themselves, fail before unavailable data becomes trusted, and bound hostile-repository memory use.

## Decision drivers

- Match C Git reachability from all regular refs.
- Preserve annotated tag objects rather than peel them away at ref resolution.
- Traverse iteratively with deterministic output.
- Reject malformed or unavailable graph state before import.
- Respect the current SHA-1-only `GitObjectId` compatibility boundary.
- Bound accumulated object IDs and pending work.

## Considered options

### Peel every ref to a commit or non-tag object

This loses annotated tag objects, which must be imported and reconstructed for Git compatibility.

### Use only commit-history traversal

This omits direct tree/blob refs, annotated tags, and tree entries.

### Resolve symbolic refs to their first object and walk object edges

This retains every rooted object type and separates target resolution from tag traversal.

## Decision

`GitRepository::reachable_object_ids` follows regular symbolic refs only to their first object. It then walks iteratively: commits add their tree and parents; trees add every entry; annotated tags add their target; blobs add no edges. Pseudo-refs are excluded.

The result is a byte-sorted, duplicate-free list of SHA-1 `GitObjectId` values. The traversal permits at most 1,000,000 scheduled objects. Unsupported object hashes fail with `unsupported`; malformed, unreadable, or unavailable reachable graph data fails with `corrupt_data`. The method does not expose raw object bytes and does not claim a transactionally consistent ref snapshot.

## Consequences

The next import slice can consume a deterministic complete object-ID set while still reading and verifying bytes through a separate API. Large repositories above the admission limit require a future streaming or persistent-work-queue design. SHA-256 traversal remains unavailable until the compatibility identity type is extended deliberately.

## Invariants

- Each returned ID is reachable from a regular ref through Git object edges.
- Direct and symbolic ref targets are roots without annotated-tag peeling.
- Annotated tag, commit, tree, and blob IDs are retained when reachable.
- Duplicate graph edges do not duplicate output or pending work.
- No unavailable or malformed reachable object is silently omitted.
- At most 1,000,000 objects are scheduled.

## Compatibility and migration

This introduces no persistent format. SHA-1 repositories are unchanged. SHA-256 rejection is an adapter admission result, not a migration.

## Security and recovery

The scheduled-object cap bounds result and work-list growth. Iterative traversal avoids stack exhaustion. Default errors do not disclose ref names, object IDs, or underlying Git diagnostics. Recovery remains independent of source-repository traversal once verified Yeokcham records exist.

## Verification

Tests build commits, nested trees, blobs, a direct tree ref, a direct blob ref, a symbolic regular ref, and an annotated tag with C Git. The returned set is compared with `git rev-list --objects --no-object-names --all` and excludes a stored unreachable blob. A dangling ref target fails as `corrupt_data` without default ID disclosure. CI runs the suite on macOS and Linux.
