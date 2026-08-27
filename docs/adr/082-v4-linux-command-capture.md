# ADR-082 — V4 Linux command capture and watcher debounce

- Status: Accepted
- Date: 2026-08-27
- Deciders: maintainers
- Supersedes: None
- Superseded by: None

## Context and problem statement

Command `save` already exists, but status did not warn about a dirty tree, and
there was no Linux loop that called that save path after quiet filesystem
activity. macOS and WSL watchers are out of scope.

## Decision drivers

- Keep exact scan as authority; the watcher only requests a save.
- Use the existing Linux inotify adapter as a generic substrate, not V2 daemon
  semantics.
- Honor the contract: 1s quiet, 30s maximum delay; failed scans keep the
  previous checkpoint.
- Fail clearly on non-Linux hosts.

## Considered options

### Platform-specific capture daemons

Rejected for this slice. They import V2 product behaviour and macOS/WSL work
the contract excludes.

### Status warning plus Linux `watch` calling `save`

Selected. Default inspectable mode is `capture command`. `watch` is an optional
Linux process that debounces inotify and invokes the same capture path.

## Decision

`status` scans the current tree and prints `capture command` plus
`uncaptured yes|no`.

`yeokcham-v4 watch` exists only where `yeokcham_linux_watcher` links. It
debounces path changes for one quiet second, captures after thirty seconds of
sustained writes, captures immediately on overflow or watcher loss, then
restarts the watcher. `.git` and `.yeokcham` events do not schedule a save.
Scan failure prints an error and leaves the previous checkpoint current.

Non-Linux builds print `Linux watcher capture is not supported on this system`
and exit 2.

## Consequences

Unsaved edits are visible without a config file. Automatic capture is Linux-only
and process-lifetime only; there is still no durable `capture=` setting.

## Model and invariant impact

Not applicable. Debounce is an adapter window around the existing `save`
transition.

## Persistent-format and migration impact

Not applicable. No new record is written.

## Verification

- local-service tests for uncaptured status and the 1s/30s window;
- CLI status warning;
- non-Linux CLI refusal of `watch`.

## CLI and user impact

`yeokcham-v4 status` always names command capture. `yeokcham-v4 watch` is the
Linux automatic-capture loop.
