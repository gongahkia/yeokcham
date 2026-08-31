# ADR-096 — V4 macOS advisory watcher

- Status: Accepted
- Date: 2026-08-31
- Implements: [#251](https://github.com/gongahkia/yeokcham/issues/251)
- Amends: ADR-082, while retaining its Linux-only daemon decision

## Context

V4's foreground `watch` command is an optional convenience around the exact
`save` transition. Its Linux inotify source is deliberately not a source of
history, intent, authority, or semantic meaning. macOS users otherwise have
only explicit `save`, even though the same product boundary can be preserved by
using the operating system's File System Events (FSEvents) API as an advisory
trigger.

FSEvents is not a byte-level operation log. It can coalesce directory events,
drop buffered events, lose a watched root, and label an item as renamed without
providing a trustworthy old/new path pair. V4 must therefore never convert an
FSEvents observation into a checkpoint or infer a rename operation. Its only
safe use is to ask the existing exact snapshot scanner to decide whether `save`
has anything to record.

## Current milestone and vertical slice

The current slice is a foreground macOS `yeokcham watch` adapter. It adds no
macOS daemon, scheduler, remote trigger, platform identity rule, model
transition, persistent project record, or transport path. WSL is unsupported
and not planned.

The slice provides a shared watcher-source contract:

```text
start(non-symlink root) -> source
poll(source, finite timeout) -> advisory scan request | no request | error
close(source)
```

Linux inotify and macOS FSEvents are interchangeable sources for one shared
foreground debounce/run loop. The loop remains the only consumer that calls
the existing `Local_service.save` adapter.

## Decision

On macOS, `watch` uses one non-persistent FSEvent stream rooted at the
canonical repository path with file-event and root-watch flags. The native
adapter owns a bounded queue and wakeup pipe; an FSEvents callback never enters
the OCaml runtime. It keeps at most 4,096 queued observations or 1 MiB of path
bytes. If either bound is exceeded, it discards path detail and emits one
explicit client-overflow observation. No event ID is stored or used to resume a
stream after process exit.

The adapter converts only safe paths below the canonical source root into the
existing watcher normalization. A precise top-level `.yeokcham` or `.git` path
does not schedule capture. An event at the root or another ancestor is not
treated as metadata even when it follows a metadata write: FSEvents has not
proved that no source path changed, so it requests a whole-root scan. A normal
rename observation names only the path supplied by FSEvents; it may be
displayed internally as a rename-triggered scan but never manufactures an old
path or a move pair.

The following observations request a whole-root exact scan:

- `MustScanSubDirs`, including ordinary FSEvents coalescing, emits
  `Rescan_required` and retains the stream;
- kernel drop, user drop, or local native-queue overflow emits `Overflow` and
  restarts the stream after the scan; and
- event-ID wrap, watched-root change, unmount, an unsafe/outside-root path, or
  source failure emits `Watcher_lost` and restarts after the scan.

If restart finds that the requested root is no longer a directory or has become
a symlink, `watch` reports that permanent error and exits with status 2 after
closing its source. It does not spin forever on a deleted repository root.
Recoverable I/O start failures remain visible and retry after a short delay.
The same runner behavior applies to Linux, replacing its prior unbounded retry
on a permanently missing root.

The shared runner uses the established one-second quiet period and
thirty-second sustained-write bound. A due request calls `save`; a successful
save records an exact checkpoint only when the scanner observes a changed
snapshot. A scan error retains the existing checkpoint. On every platform
other than Linux and macOS, `watch` fails explicitly with status 2.

macOS support ends at this foreground command. `daemon` remains Linux-only and
cannot use FSEvents, schedule synchronization, or gain persistent runtime
state.

## Invariants

1. An observation is never a checkpoint, shared revision, decision, delivery,
   authority action, or transport event. Only the existing exact `save`
   transition may create a checkpoint.
2. No FSEvents path, event ID, callback output, debounce state, or native queue
   enters V4 project state, object storage, packages, relay data, authority,
   delivery, or semantic sidecars.
3. Coalescing, overflow, loss, root movement, and path ambiguity broaden to an
   exact whole-root scan; they never create guessed paths, moves, bytes, or
   history.
4. A platform source excludes only precise `.yeokcham` and `.git` ordinary
   event paths. A root, ancestor, coalesced, or loss signal is never ignored
   merely because metadata may have changed.
5. Source close is idempotent. A failed start, permanent root loss, or normal
   cleanup leaves no running stream, queue, file descriptor, process, or
   project-state write.
6. WSL is not a source variant, test target, fallback, or release-evidence
   platform.

## Persistent-format impact

None. The adapter has no durable record and changes no canonical V4 bytes.

## Verification

- pure unit tests for FSEvents flag/path normalization, including coalescing,
  every drop/loss flag, path exclusion, unsafe path rejection, and no invented
  rename source;
- generated tests establishing that normalized safe path requests are
  duplicate-free and that every uncertainty event becomes a whole-root request;
- macOS-only native tests for create, modify, delete, one-sided rename
  observations, precise and ambiguous metadata activity, close, root loss, and
  a rapid rename storm;
- macOS-only CLI evidence that a debounced foreground watcher reaches the
  ordinary exact `save` path; and
- existing Linux watcher tests plus a root-loss/restart test for the shared
  loop, proving platform sources retain their separate evidence.

Real-host evidence records macOS version, kernel, architecture, filesystem,
FSEvents coalescing/rename observations, timing, and cleanup outcome. It is
limited to that host and does not establish Linux, daemon, WSL, or release
support.

## References

- [Apple: Using the File System Events API](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)
- [Apple: `FSEventStreamEventFlags`](https://developer.apple.com/documentation/coreservices/fseventstreameventflags)
