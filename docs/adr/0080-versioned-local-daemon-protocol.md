# ADR-0080: Define a versioned, bounded local daemon protocol

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Milestone 8 introduces a local daemon. Clients need a small, testable control boundary before repository discovery, filesystem monitoring, caches, or a listener can be added. An undocumented ad-hoc text protocol would make compatibility, limits, and malformed-input behavior ambiguous.

## Decision drivers

- Permit bounded parsing before allocation or repository access.
- Provide explicit versioning and request/response correlation.
- Keep V1 narrow enough to audit before background repository work exists.
- Avoid source paths, Git bytes, credentials, and keys in control records.

## Considered options

### Option 1: Add commands directly to the CLI without a daemon protocol

This does not establish a client/daemon compatibility boundary or a safe shutdown handshake.

### Option 2: Use newline-delimited JSON

Text records need separate framing, parsing, and size rules. They also make it easier to accidentally add unbounded optional fields or source-bearing diagnostics.

### Option 3: Use a fixed versioned binary V1 frame

Prefix each frame with a bounded length and encode a fixed V1 header plus a request ID and small tagged control message.

## Decision

Use Option 3. `DaemonProtocolFrame` encodes `u32` body length, `YKDP` magic, `u16` protocol version, one direction tag, one message tag, and a nonzero `u64` request ID. The V1 maximum body is 64 KiB and V1 has exactly `ping`/`pong` and `shutdown`/`shutdown-accepted` messages. The decoder rejects truncation, length mismatch, unknown magic, zero IDs, invalid direction, unknown message tags, and unknown versions before a daemon action.

The protocol is transport-neutral in core. The listener slice binds it only to a per-user Unix-domain socket; it must not add a TCP listener. Future behavior requires a later protocol version or an explicitly documented compatible extension.

## Consequences

V1 can prove a compatible local daemon is alive and request an orderly shutdown, but it cannot discover repositories or perform storage work yet. The fixed record is intentionally not a persistent repository format and does not require a repository-format feature flag.

## Invariants

- Every encoded V1 frame has one canonical representation.
- A client-generated request ID is nonzero and a response echoes that exact ID.
- The decoder accepts no trailing bytes and no body above 64 KiB.
- V1 records contain no path, object content, token, credential, or key material.
- Decoding never starts a daemon action.

## Compatibility and migration

No persistent-format migration. Existing repositories are unaffected. A V1 client and a daemon using an unknown version fail closed as unsupported. Removing the daemon leaves repository bytes and export behavior unchanged.

## Security and recovery

The frame cap bounds a hostile local peer before any allocation by later stream code. Static error messages avoid reflecting payloads. The eventual Unix socket uses operating-system user permissions; this protocol itself provides no authentication and must never be exposed on a network listener. No recovery state depends on the daemon or protocol.

## Verification

Unit tests prove canonical request/response encodings, request-ID validation, malformed/truncated/oversized rejection, version rejection, and `Send + Sync` bounds. Workspace CI runs the codec with format, Clippy, documentation, and all existing storage/recovery tests.
