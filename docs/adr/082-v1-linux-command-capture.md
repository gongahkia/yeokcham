# ADR-082 — V1 Linux command capture and watcher debounce

- Status: Accepted
- Date: 2026-08-27
- Deciders: maintainers
- Supersedes: None
- Amended by: ADR-096 for the foreground macOS adapter

## Context and problem statement

Command `save` already exists, but status did not warn about a dirty tree, and
there was no Linux loop that called that save path after quiet filesystem
activity. At this decision's adoption, macOS watchers were out of scope; ADR-096
later adds a separate foreground macOS adapter. WSL is unsupported and not
planned.

## Decision drivers

- Keep exact scan as authority; the watcher only requests a save.
- Use the existing Linux inotify adapter as a generic substrate, not prior
  daemon semantics.
- Honor the contract: 1s quiet, 30s maximum delay; failed scans keep the
  previous checkpoint.
- Fail clearly on non-Linux hosts.

## Considered options

### Platform-specific capture daemons

Rejected for this slice. They import prior product behaviour and macOS watcher
work the contract excludes; WSL is unsupported and not planned.

### Status warning plus Linux `watch` calling `save`

Selected. Default inspectable mode is `capture command`. `watch` is an optional
Linux process that debounces inotify and invokes the same capture path.

## Decision

`status` scans the current tree and prints `capture command` plus
`uncaptured yes|no`.

`yeokcham watch` exists only where `yeokcham_linux_watcher` links. It
debounces path changes for one quiet second, captures after thirty seconds of
sustained writes, captures immediately on overflow or watcher loss, then
restarts the watcher. `.git` and `.yeokcham` events do not schedule a save.
Scan failure prints an error and leaves the previous checkpoint current.

At this decision's adoption, non-Linux builds printed `Linux watcher capture is
not supported on this system` and exited 2. ADR-096 changes that result only
for macOS; all other unsupported platforms still exit 2.

## Consequences

Unsaved edits are visible without a config file. Automatic capture is Linux-only
and process-lifetime only; V1 deliberately has no durable command-metadata
record.

## Model and invariant impact

Not applicable. Debounce is an adapter window around the existing `save`
transition.

## Persistent-format and migration impact

Not applicable. No new record is written.

## Verification

- local-service tests for uncaptured status and the 1s/30s window;
- CLI status warning;
- CLI refusal of `watch` outside Linux and macOS.

The inotify loop test is `test/test_v1_watch.ml` (`build_if linux`, Alcotest
`Slow`). It was not run on the Darwin development host. Proof on another
machine:

```sh
uname -s   # must print Linux
opam exec -- dune exec test/test_v1_watch.exe
```

Pass is Alcotest success for “watch records a checkpoint after quiet edits”.
`dune runtest` on Ubuntu (including `.github/workflows/ci.yml`) is the
intended automated path; do not treat this ADR as field-trial evidence until
that test has actually passed on Linux.

## CLI and user impact

`yeokcham status` always names command capture. `yeokcham watch` is the
Linux automatic-capture loop.
