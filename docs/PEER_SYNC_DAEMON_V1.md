# Peer sync daemon v1

Peer daemon v1 is a Unix-only foreground runtime for one explicitly selected
peer-sync transport. It belongs to issue #241 and schedules no scratch scan,
capsule, workspace, release, or working-tree operation.

## Vertical slice

`peer daemon run` receives a repository root, private runtime directory, local
identity, pinned contact, tracking name, and exactly one selected transport:

- a configured local-path peer with an explicit owner-readable source key and
  sync head;
- a configured relay directory; or
- a configured SSH contact with known-hosts policy and sync head.

The foreground runner obtains a private capability socket through the existing
local daemon runtime. `peer daemon ping`, `status`, `shutdown`, and `recover`
are explicit control operations. A restart never reconstructs or rewrites a
peer-tracking ref; normal transport verification remains the only path to one.

## Runtime records and invariants

The daemon writes one mode-`0600`, bounded status file beside its private
runtime discovery record:

```text
yeokcham-peer-daemon-status 1
state=<waiting|no-current-update|tracking-advanced|tracking-already-current|tracking-diverged|failed|stopped>
attempts=<nonnegative integer>
next-retry=<finite seconds since epoch|none>
detail=<bounded single-line diagnostic>
```

This is runtime state, never a canonical object, binding, or mutable ref. Its
directory must be owned by the current Unix user and inaccessible to group and
other users. The local control socket is authenticated with the runtime
capability and rejects malformed or unauthorised requests.

Long configured runtime paths can exceed the platform Unix-domain socket limit.
The control runtime therefore preserves discovery/status in the requested
private directory but places only the socket in a private per-user `/tmp`
fallback when required. The endpoint remains root-derived and capability
authenticated; the fallback never carries canonical repository data.

Each polling result uses a normal peer transport. A relay replay receipt is
reported as `no-current-update`, not as a fresh synchronization. A failed poll
records `failed`, doubles its delay from one second up to 60 seconds, and never
reports a successful synchronization. Shutdown cancels later polls through the
control socket.

## Tests

`test_peer_sync_daemon` covers a real two-repository local direct poll, a relay
poll, rejection of an unconfigured relay, tracking isolation, runtime-only
status, malformed and unauthorised controls, shutdown, retry bound, and a
killed-process recovery/restart that keeps the accepted tracking head.
`test_local_daemon` verifies the shared capability protocol and exercises its
short private socket fallback.

## ADR impact

No ADR change is required. ADR-078 already isolates daemon state from canonical
history. The existing local-daemon V2 entry point remains V2-specific;
`start_for_validated_root` is narrowly scoped for callers, such as this peer
daemon, that have opened and validated their own model's repository root.
