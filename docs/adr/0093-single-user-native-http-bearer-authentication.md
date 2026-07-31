# ADR-0093: Require one private bearer token for native HTTP V1

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: ADR-0092 only for unauthenticated endpoint access
- Superseded by: None

## Context

Native HTTP V1 initially restricted listeners to loopback, but another process on the same host could still read served repository metadata and object bodies. Milestone 9 requires a single-user authentication boundary before browser features or any consideration of a non-loopback service.

## Decision drivers

- Require credentials for every endpoint, including health.
- Avoid command-line, environment, tracing, and response disclosure of the secret.
- Reject symlinked, group-readable, and world-readable credential files.
- Use an established constant-time equality implementation and OS randomness.
- Preserve the loopback-only listener restriction.

## Considered options

### Keep loopback-only unauthenticated access

This leaves every same-host process able to retrieve repository contents.

### One operator-managed bearer token file

This is a narrow single-user mechanism with an explicit local credential lifecycle and no account database or persistent repository change.

### Multi-user identity provider

This introduces tenancy, account recovery, session management, and deployment dependencies outside the single-user milestone.

## Decision

`yeokcham-server token create <private-token-file>` creates one new 256-bit token using `getrandom`, encoded as 64 lowercase hexadecimal bytes plus a newline in a create-new mode-0600 regular file. It prints no token. Server startup requires `--auth-token-file <private-token-file>`; the loader opens with `O_NOFOLLOW` and rejects non-regular files and any group or other permission bit.

Every native V1 endpoint requires exactly one `Authorization: Bearer <64-lowercase-hex>` header. Incorrect, malformed, duplicate, and absent credentials receive the same `401` `authentication_required` response with `WWW-Authenticate: Bearer`. The server parses the presented token into a zeroized fixed-size buffer and uses `subtle` constant-time equality against its zeroized in-memory secret.

## Consequences

One operator can create a token, distribute it through a separate secure channel, and restart the server with its private file. Rotation is create-a-new-file plus restart; token reload, per-client revocation, sessions, scopes, TLS, and public deployment are not provided. Existing native clients must add the header.

## Invariants

- No endpoint is reached until exact bearer authentication succeeds.
- Token bytes never appear in default diagnostics, response bodies, command-line arguments, environment variables, or `Debug` output.
- Token creation never replaces an existing pathname and synchronizes its file and parent directory before success.
- A server remains unable to bind a non-loopback address after authentication succeeds.
- Authentication failure never changes repository data.

## Compatibility and migration

No repository, segment, manifest, cache, or ref-journal format changes. This changes the native HTTP V1 access requirement only; the local remote helper is unaffected. An unauthenticated client must add the documented bearer header before it can use V1.

## Security and recovery

The token is an equivalent read credential for all V1 objects and refs. Loopback plus bearer authentication reduces same-host exposure but cannot protect a compromised account, process memory, kernel, or terminal session. Do not forward V1 through a proxy or tunnel. Losing a token does not affect repository recovery: create a replacement token and restart the service, then update clients. File permission checks are Unix permission checks; operator filesystem ACL policy remains part of host administration.

## Verification

Tests create a token file, verify its 0600 permissions and exact encoding, reject broad, malformed, symlinked, and existing files, verify redacted diagnostics, and prove absent/incorrect tokens receive `401` while a valid token reaches health, ref, and object endpoints. CLI parsing requires the token file and accepts only the exact creation command.
