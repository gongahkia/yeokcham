# ADR-0085: Serve the daemon only through a private Unix socket

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The protocol now needs an operational lifecycle. The local daemon must remain optional and must not create an unauthenticated network listener.

## Decision

`yeokcham-daemon` binds only an AF_UNIX stream socket. Its default location is `$TMPDIR/yeokcham-daemon.sock`; it refuses to start if the runtime parent is unavailable, symlinked, group-accessible, or world-accessible. An explicit `--socket` follows the same private-parent policy. The socket is mode `0600`, never replaced if an entry already exists, and removed when the server exits.

The server accepts one V1 request per connection. `ping` returns `pong`; `shutdown` atomically requests cancellation, returns `shutdown-accepted`, and ends the nonblocking accept loop. Malformed frames are closed without payload reflection. There is no TCP, HTTP, or persistent daemon state.

## Consequences

The daemon is intentionally single-user and local. Operators can run multiple instances only with separate explicit socket paths. A stale socket requires explicit inspection/removal rather than automatic unlinking.

## Invariants

- No daemon path binds an IP socket.
- A shutdown request is acknowledged before orderly server exit.
- Cancellation is process-local and changes no repository bytes.
- A private parent and mode-`0600` socket gate local client access.
- The daemon is removable without any repository-format change.

## Compatibility and migration

No persistent format or migration. Clients must use `YKDP` V1. Removing the executable or its socket leaves all repositories and exports intact.

## Security and recovery

Unix-domain socket permissions are the authentication boundary. The process inherits no credential-helper or SSH-agent logic. Socket paths and protocol payloads are absent from default errors. Recovery uses normal local repository/open/export paths, never a daemon.

## Verification

An integration-style unit test binds a private temporary socket, performs V1 `ping`, requests shutdown, verifies cancellation, joins the server, and proves socket cleanup. Workspace CI covers protocol decoding, format, lint, docs, and all repository tests.
