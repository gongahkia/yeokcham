# ADR-0088: Run daemon sparse prefetch only from explicit local selections

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The daemon needs a usable current-path hydration path without searching a user's Git worktrees or guessing history. The core hydration seam in ADR-0087 has no value unless one long-lived daemon owns its shared cache and refreshes it after an acknowledged ref change.

## Decision

`yeokcham-daemon` accepts an opt-in configuration:

`--repository <yeokcham-repo> --sparse-path <relative-path>... [--prefetch-byte-budget <bytes>]`

At startup it validates the supplied Yeokcham store, allocates the 256 MiB process shared-object cache, and hydrates only the 64 MiB-by-default current sparse selection from ADR-0086. It polls only the store's `manifests/refs` and `journals/refs` metadata once per second. A detected change revalidates and reruns the current-HEAD selection; no source Git worktree is discovered or scanned.

The existing private Unix control protocol remains V1 `ping`/`shutdown`. Accepted client streams are returned to blocking mode with a bounded read timeout because a nonblocking listener can yield nonblocking accepted streams on macOS.

## Consequences

The daemon now performs real verified cache hydration and refreshes it after local acknowledged-ref metadata changes. Repository and paths remain explicit user-supplied startup configuration. The cache remains process-local and disposable.

This does not yet connect the remote helper to the daemon cache or derive a worktree's sparse configuration. Therefore it does not establish a sparse-checkout speedup and does not close the daemon-heuristics or workload-improvement roadmap items.

## Invariants

- The daemon never searches parent directories, user worktrees, or historical commits.
- It monitors metadata only; it does not read source file bodies.
- Every cached object is still resolved from a valid manifest and verifies its Git ID.
- A malformed or unavailable current ref state fails the refresh rather than selecting stale data.
- Cache loss and daemon shutdown leave Git and Yeokcham persistent data unchanged.

## Compatibility and migration

No persistent format or remote-helper protocol changes. Running without sparse-prefetch options preserves the V1 control-only daemon behavior. Disabling the daemon has no repository correctness impact.

## Security and recovery

The socket remains per-user Unix-only. Exact sparse paths are validated before daemon startup. The daemon follows no source path, exposes no TCP listener, and stores no object body on disk. Normal repository reconstruction remains the recovery path.

## Verification

Daemon tests cover option validation, startup hydration of a selected real Git path, ref-metadata-change rehydration after clearing the shared cache, and V1 ping/shutdown over a private Unix socket.
