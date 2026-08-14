# ADR-050 — Local V2 daemon runtime boundary

- Status: Accepted
- Date: 2026-08-09
- Deciders: maintainer (autonomous issue workflow)
- Governing issue: [#134](https://github.com/gongahkia/yeokcham/issues/134)

## Context and decision

V2 needs one local background owner per repository, but `.yeokcham` has an
exact five-entry canonical layout. Socket, lock, PID, and discovery files
therefore cannot live in the repository or become history. The daemon uses a
pathname `AF_UNIX` listener in a caller-supplied private runtime directory.
The directory must be owned by the current user and have no group or other
permissions. Production callers use an XDG Runtime Directory location; tests
inject a private temporary directory.

The endpoint name is a bounded SHA-256-derived identity of the canonical root
path. Binding the pathname is the singleton claim. A second bind reports busy;
it does not kill, replace, or probe the owner by PID. A stale socket is removed
only by an explicit recovery operation after connection refusal and after its
matching regular discovery file is checked. This avoids PID reuse and never
touches canonical repository data.

Discovery is a strict, versioned, mode-0600 runtime file containing the
endpoint identity and an OS-CSPRNG 32-byte capability. The fixed local stream
protocol accepts only `ping` and controlled `shutdown`; malformed messages and
wrong capabilities receive an error response and do not stop the daemon. The
capability scopes access to the current OS user's protected runtime directory;
it is not a device identity, recovery key, repository authority, or a defense
against hostile processes already running as that same user.

## Alternatives and consequences

Putting runtime files in `.yeokcham` conflicts with the V2 root invariant and
would make process state appear canonical. Abstract Linux sockets avoid stale
paths but are nonportable and do not provide filesystem discovery. PID files
and automatic `kill` introduce stale-PID reuse hazards. The selected pathname
socket works with the XDG runtime-directory contract and makes cleanup explicit.

No V2 persistent bytes or repository semantics change. Runtime protocol bytes
are versioned but noncanonical and disappear with the daemon/session. Future
device authentication replaces or composes with this local capability; it must
not treat it as durable authorization.

## Invariants and verification

1. A daemon starts only for a classified-ready V2 root.
2. One bound endpoint represents at most one live listener for one root identity.
3. Discovery and socket paths are outside `.yeokcham` and in a private runtime directory.
4. Bad frames and bad capabilities cannot trigger shutdown.
5. Stale recovery needs connection refusal and never mutates repository files.

Focused tests cover singleton refusal, valid ping, malformed-client rejection,
controlled shutdown, restart, and explicit stale recovery. A future protocol
extension needs malformed/generated framing tests and a new version marker.

## Sources

The [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir/)
defines `XDG_RUNTIME_DIR` for per-user runtime sockets and requires a local,
user-owned mode-0700 directory. [unix(7)](https://man7.org/linux/man-pages/man7/unix.7.html)
documents pathname socket cleanup and permission limitations; directory and
capability checks are the portability-oriented security boundary here.
