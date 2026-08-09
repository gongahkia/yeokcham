# ADR-051 — Linux inotify as an advisory watcher source

- Status: Accepted
- Date: 2026-08-09
- Deciders: maintainer (autonomous issue workflow)
- Governing issue: [#135](https://github.com/gongahkia/yeokcham/issues/135)

## Context and decision

V2-013 needs a Linux event source, but scan—not an event log—remains the
authority for recovery. The repository had no watcher binding. A root-only
inotify watch is insufficient because inotify does not recursively observe a
directory tree. Ignoring overflow or a lost watch could silently leave a later
exact scan unscheduled.

Use the pinned `inotify` 2.6 OCaml binding as a runtime-only Linux adapter.
`yeokcham_linux_watcher` starts from a non-symlink canonical root, recursively
watches directories without following symlinks, and sends every raw batch to
the pure `yeokcham_watcher` normalizer. It pairs same-batch move cookies and
updates watched subtree paths for in-tree directory renames. Newly created or
moved-in directories are watched before their advisory request is returned.

`IN_Q_OVERFLOW` emits an overflow whole-root scan request. Unmount, root loss,
unknown watch descriptors, unsafe names, the watch-count limit, or failure to
watch a newly observed directory emit a whole-root watcher-loss request and
mark the source for explicit restart. The adapter never scans, writes a V2
root, mutates daemon discovery, or publishes a checkpoint.

## Alternatives and consequences

Polling alone remains a supported scan trigger, but it does not satisfy the
Linux source portion of V2-013. A single root watch was rejected because nested
file changes could remain invisible. Treating overflow as an ordinary path
event was rejected because the kernel reports that observations were dropped.
Following symlinked directories was rejected because it can escape the selected
working-tree root and makes watch coverage ambiguous.

The new bounded dependency is Linux-specific in behavior but returns an
unsupported system error rather than emulating events on other platforms.
macOS FSEvents remains a separate source adapter: it requires Apple framework
linking and native validation. The shared normalization model makes those
platforms agree at the advisory request boundary rather than asserting that
their raw event streams are identical.

## Model and invariant impact

This adds only runtime values: a Linux watcher, kernel watch descriptors, and
same-batch move pairing. The invariants are:

1. Every emitted request is normalized by `yeokcham_watcher`.
2. The watcher never follows a root or descendant symlink.
3. A paired in-tree directory move updates all watched descendant paths.
4. Loss or incomplete coverage requests a full rescan and requires restart.
5. No watcher input creates a checkpoint, canonical event, ref, or persistent byte.

## Persistent format, verification, and user impact

No persistent bytes, migration, golden fixture, CLI command, or user-visible
history semantics are introduced by this source alone. ADR-057 wires it to the
Linux V2 daemon while retaining exact scans as the publication boundary. Focused
Linux tests use a temporary directory to verify recursive new-directory
coverage, paired rename normalization, root-symlink refusal, and invalid timeout
rejection. The shared pure normalizer retains seeded generated burst, overflow,
loss, and path-safety coverage. Full repository checks remain required.

## Sources

[inotify(7)](https://man7.org/linux/man-pages/man7/inotify.7.html) documents
that a queue overflow loses observations and must be handled by rebuilding the
affected state. [Apple documents](https://developer.apple.com/documentation/coreservices/fseventstreamcallback?language=objc)
that FSEvents user/kernel drops can report `/` and are not path-specific, which
is why the macOS implementation must retain a whole-root fallback when
introduced.
