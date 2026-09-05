# ADR-089 — V1 Linux advisory background runtime

- Status: Accepted
- Date: 2026-08-30
- Implements: GitHub issue #261

## Context

V1 already has two deliberately separate operations: Linux `watch` observes
ordinary working-tree changes and delegates recovery capture to `save`; `sync`
receives verified signed publications through the receipt boundary and then
attempts outbound publication. Neither operation is user intent, authority, or
delivery. The foreground watcher is useful but cannot survive a terminal exit,
and asking users to write a service manager configuration would make ordinary
scratch recovery needlessly operational.

The background runtime must not turn this convenience into an online project
manager. In particular, it cannot periodically follow remotes, make authority
conditional on reachability, choose a feed or authority head, or treat an
automatic checkpoint as shared intent. Runtime files also must not become a
second project format or a dependency of V1 recovery.

## Decision

V1 provides a Linux-only, per-repository managed runtime:

```text
yeokcham daemon start [--root PATH]
yeokcham daemon status [--root PATH]
yeokcham daemon stop [--root PATH]
yeokcham daemon sync [--root PATH] REMOTE
```

`start` detaches one process after verifying an existing V1 project. It holds
an advisory kernel lock for its lifetime, so a second runtime for the same
canonical repository root is refused. A process crash releases that lock; a
later start acquires it before removing any stale control socket. This is not a
PID-file lease and never requires deleting a stale lock by name.

The runtime requires an absolute, user-owned, mode-0700 `XDG_RUNTIME_DIR`.
There is no `/tmp`, home-directory, or persistent-state fallback. Its private
directory is `XDG_RUNTIME_DIR/yeokcham-v1/<root-hash>/`, where the hash is
bounded only to satisfy the Linux Unix-domain-socket pathname limit. If the
runtime parent path leaves too little hash space, start fails rather than using
an ambiguous or public location. The directory, socket, lock, log, and
`runtime-state-v1` status file are mode 0700/0600 as appropriate. State is
atomically replaced, explicitly versioned, size-bounded, and disposable. It
contains process observability only: canonical root, nonce, watcher condition,
current task, and bounded last result. It is not V1 project state, a package,
transport state, credential, authority record, or recovery input.

The running process performs exactly the existing Linux watcher debounce and
calls the existing `Local_service.save` adapter. Thus automatic capture remains
an exact scratch checkpoint and preserves the `save` transition’s retention,
pin, and no-change behaviour. Capture failure and watcher loss become visible
runtime status; the watcher is restarted without inventing a model transition.

The daemon does no network work by default. `daemon sync REMOTE` is an explicit
operator request, serialized with capture in the one owning runtime process.
It calls the shared `Yeokcham_v1_sync` orchestration, which is also used by the
foreground `sync` command. That orchestration fetches bytes, stages and
validates them, invokes the existing atomic receipt batch, and only then
attempts outbound upload. It never scans or materialises the working tree.
Unavailable remotes and invalid receipts report failure while retaining the
normal receipt boundary’s no-partial-import and no-working-tree-mutation
rules. The runtime has no periodic remote polling, retry scheduler, autostart,
systemd unit, configuration file, or new network protocol.

## Invariants and verification

1. At most one live daemon may own one canonical repository root. Kernel lock
   release permits recovery after a crash without trusting stale PID data.
2. All runtime artifacts are private, bounded, disposable, and outside the
   canonical V1 object store and mutable project head. Deleting them cannot
   remove a checkpoint, revision, decision, authority epoch, receipt, or
   credential.
3. Automatic work is limited to the existing local scratch `save` transition.
   It cannot create shared intent, delivery, authority, or remote work.
4. Network work occurs only for an explicit `daemon sync` command and takes the
   same verified receive-first path as foreground sync. A runtime cannot choose
   a feed/authority head or change the working tree during receipt.
5. Missing, non-private, relative, or overlong XDG runtime paths fail closed.
   Unsupported platforms fail explicitly rather than emulating this design.

The Linux executable test starts a real detached daemon, verifies private state
and duplicate-start refusal, changes a file and observes a debounced checkpoint,
hard-kills the daemon and restarts it, rejects an absent XDG runtime directory,
and proves a failed explicit sync does not change ordinary file bytes or create
a checkpoint. Existing watcher, receipt, transport, and no-working-tree tests
remain the evidence for the reused transitions.

## Consequences

The runtime is intentionally modest: it gives local scratch capture a managed
lifetime, not a new history, authority, or synchronization model. Explicit
sync may occupy the serialized runtime process until its bounded transport
operation returns; it is not silently retried in the background. Operators who
need host lifecycle management may invoke `daemon start` from their own service
manager, but Yeokcham neither installs nor depends on a unit.

Runtime observability can be lost on logout because `XDG_RUNTIME_DIR` is
disposable. That loss is acceptable: project state is still local and the next
`daemon start` begins a fresh advisory process. A future platform runtime,
network scheduler, or persistent queue would require a separate ADR because it
would change operational, failure, and possibly trust semantics.

## References

- [XDG Base Directory Specification, §3](https://specifications.freedesktop.org/basedir-spec/latest/)
- [Unix-domain sockets, Linux manual page](https://man7.org/linux/man-pages/man7/unix.7.html)
