# ADR-0087: Verify and cache only current-HEAD sparse paths

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The local helper's complete Git snapshot cache lets C Git filter sparse checkout results, but it reconstructs excluded Yeokcham records first. Daemon prefetch cannot improve that path until Yeokcham can resolve exact current paths without reconstructing every blob.

## Decision

`LocalRepository::prefetch_current_sparse_paths` resolves the effective current `HEAD`, follows only an annotated-tag chain when present, parses the current commit and tree graph with `gix`, and reconstructs only the exact selected paths. A selected directory visits its current subtree; an exact file visits that blob. The method uses the existing manifest and segment bounds from `GitImportLimits`, rejects malformed object links, checks every reconstructed Git object ID, and inserts only verified bodies into a caller-owned `SharedObjectCache`.

The shared cache must be large enough for the selection budget. The report exposes counts and bounds but redacts object identity from `Debug`. Missing exact paths are reported, not treated as a repository mutation or a path traversal. Gitlinks have no local blob body and are reported separately.

## Consequences

This creates the native path-aware hydration seam needed by the daemon. It avoids scanning the same tree once per selected path by traversing a deterministic in-memory path trie. It does not yet expose a daemon prefetch request, discover a worktree's sparse configuration, change remote-helper pack construction, or establish a performance improvement.

## Invariants

- Only current `HEAD`, selected path trees, and selected blob bodies are eligible.
- Historic commits, unselected current blobs, source working-tree bodies, and sparse patterns are not read.
- Object and tree-entry counts, manifest sizes, segment sizes, and selected bytes remain bounded.
- Cache loss changes no Git or Yeokcham persistent state and recovery remains cold-path compatible.
- A cached object is accepted only for the requested repository, Git ID, kind, and manifest body size.

## Compatibility and migration

No persistent format or remote-helper protocol changes. Existing repositories can use the method after normal validation. Disabling or clearing the shared cache has no correctness effect.

## Security and recovery

Tree entries and object links are treated as hostile. Malformed commits, tags, trees, duplicate selected names, invalid tree entry names, unavailable manifests, and mismatched cached data fail closed. Exact sparse paths were already validated as relative local metadata; no caller path is opened.

## Verification

Unit tests import a real Git repository, prefetch one current directory plus one absent path, prove that its blob enters the shared cache while an excluded current blob does not, and verify the report is redacted. A second test constrains the byte budget below the current commit size and proves no body is reconstructed or cached.
