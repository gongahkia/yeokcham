# ADR-0090: Derive daemon prefetch directories from an opt-in Git cone configuration

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: ADR-0088
- Superseded by: None

## Context

The explicit-path daemon prefetch in ADR-0088 does not use a user's already-declared sparse focus. Automatically finding a worktree or inferring access history would broaden daemon observation and create an unbounded, privacy-sensitive policy.

## Decision

`yeokcham-daemon` accepts exactly one of these opt-in selections with `--repository <yeokcham-repo>`:

`--sparse-path <relative-path>...`

`--sparse-checkout-file <path>`

The sparse-checkout-file option reads only its supplied regular non-symlink file. It accepts at most 4 MiB of UTF-8 canonical C Git cone-mode patterns: the two root patterns, ordered parent pairs, then ordered recursive directories. It derives only the recursive directory entries for `SparsePrefetchSelection`. Non-cone patterns, escaped names, malformed ordering, and root-only configurations fail closed. Explicit `--sparse-path` values remain available for unsupported selections.

The daemon records only the exact file's length and modification time. It checks that metadata during its existing one-second refresh interval, reparses only after a change, and refreshes the disposable cache. It neither scans a parent directory nor searches for a Git worktree.

The existing private Unix control protocol remains V1 `ping`/`shutdown`. Accepted client streams are returned to blocking mode with a bounded read timeout because a nonblocking listener can yield nonblocking accepted streams on macOS.

## Consequences

Users can connect their stated cone-mode sparse focus to daemon cache hydration without granting worktree discovery. The accepted subset is intentionally narrower than all C Git sparse-checkout syntax. A malformed replacement stops the next refresh rather than retaining an unverified selection.

This still does not connect the remote helper to the daemon cache or measure a sparse-checkout speedup. It closes the explicit prefetch-heuristic selection item only.

## Invariants

- The daemon never discovers a worktree, scans a configuration parent directory, reads worktree file bodies, or predicts history.
- Only one user-supplied regular sparse-checkout file may configure one daemon selection.
- An observed file replacement, truncation, symlink, malformed configuration, or unavailable current ref state fails the refresh rather than selecting stale data.
- Every cached object is still resolved from a valid manifest and verifies its Git ID.
- Cache loss and daemon shutdown leave Git and Yeokcham persistent data unchanged.

## Compatibility and migration

No persistent format or remote-helper protocol changes. Existing explicit `--sparse-path` commands retain their behavior. Running without prefetch options preserves V1 control-only daemon behavior.

## Security and recovery

The socket remains per-user Unix-only. The explicit configuration file is bounded and parsed without logging its paths. The daemon stores no object body on disk. Normal repository reconstruction remains the recovery path.

## Verification

Core tests reject noncanonical configurations and parse canonical recursive directories. Daemon tests cover option exclusivity, startup hydration from a real C Git cone file, cache refresh after that exact file changes, ref-metadata-change rehydration, and V1 ping/shutdown.
