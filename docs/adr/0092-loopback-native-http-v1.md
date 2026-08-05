# ADR-0092: Serve a bounded loopback Yeokcham-native HTTP V1 transport

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Milestone 9 needs a self-hosted network boundary after local remote-helper correctness. C Git smart HTTP would add receive/upload-pack advertisement, negotiation, packet-line streaming, and authentication scope at once. The current local helper already delegates that mature Git protocol to C Git, while no HTTP service exists.

## Decision drivers

- Preserve verified Git-object identity at every served object boundary.
- Keep an unauthenticated initial service unreachable from non-loopback peers.
- Bound request parsing, response construction, connection time, and pending work.
- Publish a client-independent protocol before adding a browser or public listener.

## Considered options

### Smart HTTP immediately

This would give ordinary Git clients direct HTTP cloning but expands the protocol and authentication surface before the server lifecycle is proven.

### Yeokcham-native object transport V1

This exposes verified ref discovery and exact Git-object bodies through a small documented HTTP surface. Native clients must walk Git graphs themselves.

### Keep only the local remote helper

This retains current Git compatibility but does not create a self-hosted HTTP service boundary.

## Decision

Add `yeokcham-server`, a documented native HTTP V1 service. It accepts only `GET /v1/health`, `GET /v1/refs`, and `GET /v1/objects/<40-lowercase-sha1>`. Object responses contain a verified Git object body plus its type and ID headers; ref names use hexadecimal bytes without UTF-8 normalization.

The CLI and library reject every non-loopback socket address. The default bind is ephemeral `127.0.0.1:0`; an operator may choose a known loopback port. The service accepts one request per connection, no request body, no transfer encoding, and no keep-alive. It bounds headers to 8 KiB, response bodies to 64 MiB, each I/O phase to five seconds, active workers to four, and queued accepted sockets to eight.

This is not Git smart HTTP and ordinary `git clone http://...` is unsupported. The local remote helper remains the Git-compatible transport. Authentication is required before any future non-loopback binding is considered.

## Consequences

Native clients can discover canonical refs and retrieve exact verified Git objects without a hosted Yeokcham control plane. They must implement bounded Git graph traversal and object-ID verification. The service has no pack negotiation, push endpoint, TLS listener, user management, or public bind mode in V1.

## Invariants

- A served object is reconstructed from published bounded manifests and verifies its requested Git ID before response construction.
- Ref state is resolved through the checked snapshot and journal materialization path; unavailable or invalid state is not served.
- Ref names remain exact bytes through a hexadecimal wire representation.
- No request can select a filesystem path, alter repository data, or create a server-side export.
- The server cannot bind a non-loopback address, including through its library API.

## Compatibility and migration

No repository, segment, manifest, cache, or ref-journal format changes. HTTP V1 is separately versioned and documented in [`native-http-v1.md`](../native-http-v1.md). Future incompatible protocol changes require a new route version.

## Security and recovery

Loopback is a transport-scope restriction, not authentication: another process on the same host may connect. The V1 implementation reveals repository IDs, ref metadata, and object bodies to a local connector. It logs none of them. Public exposure, TLS termination, and credentials are out of scope until a single-user authentication slice explicitly changes this ADR or supersedes it. Server loss does not affect canonical repository data; all endpoints are read-only.

## Verification

The server integration test imports a real Git fixture, requests health, refs, and a commit object over TCP, checks the exact ref/object metadata and object body, rejects request bodies and non-GET methods, and proves a `0.0.0.0` bind fails. Workspace tests, formatting, Clippy, and documentation builds cover the new crate.
