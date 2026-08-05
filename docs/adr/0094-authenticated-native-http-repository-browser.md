# ADR-0094: Add a token-authenticated native HTTP repository browser

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: ADR-0093
- Superseded by: None

## Context

The native V1 service has a private Bearer-token API, but ordinary web browsers cannot set a custom Authorization header when navigating directly. Milestone 9 requires a repository browser without placing tokens in URLs, HTML, JavaScript, local storage, or a separate session database.

## Decision drivers

- Allow a standard browser to authenticate without a custom extension.
- Reuse the existing 256-bit operator token and file lifecycle.
- Keep every route authenticated and all bindings loopback-only.
- Render ref names without HTML injection or loss of non-UTF-8 bytes.
- Keep later commit and tree views separate from the initial repository/ref page.

## Considered options

### Require only Bearer headers

This preserves the API boundary but leaves the HTML browser inaccessible through normal browser navigation.

### Cookie login session

This needs a request body, session-token generation, cookie policy, expiration, CSRF handling, and storage/lifecycle design.

### HTTP Basic with the existing token

This lets browsers prompt for one user/password pair while retaining the current secret and no server-side session state.

## Decision

Accept either exactly one `Authorization: Bearer <token>` header or exactly one HTTP Basic credential with username `yeokcham` and the same token as password. Base64 decoding is bounded to 128 bytes, the decoded credential is zeroized, and the token comparison remains constant-time. Failure continues to return generic `401` with both Basic and Bearer challenges.

Add authenticated `GET /`, a static HTML repository browser that shows the repository ID, regular refs, their current object IDs, and `HEAD`. Valid UTF-8 ref names are HTML-escaped; non-UTF-8 ref names display as `hex:<lowercase-hex>`. At adoption it has no token-bearing links, scripts, forms, object-body display, commit view, tree view, write operation, or persistent browser state. ADR-0095 adds bounded commit/tree metadata pages without changing this authentication decision.

## Consequences

An operator can navigate to the loopback address and use `yeokcham` as username with the generated token as password. Basic authentication encodes rather than encrypts credentials; it is acceptable only because the service still rejects every non-loopback listener and documentation prohibits tunnels and proxies. Bearer remains the native-client path.

## Invariants

- The HTML browser is reached only after the same authentication check as every API endpoint.
- Dynamic ref labels are HTML-escaped or hexadecimal; raw ref bytes never enter HTML markup unescaped.
- Browser response construction is bounded by the existing 64 MiB response limit.
- No browser interaction can mutate repository state or reveal the token in an HTML response.

## Compatibility and migration

No repository, storage, or recovery format changes. Basic is an additive V1 authentication mechanism. It supersedes ADR-0093's Bearer-only HTTP-header rule; token generation, file validation, constant-time comparison, and loopback binding remain unchanged.

## Security and recovery

Basic credentials are full repository-read credentials when presented to this service. They must never leave loopback HTTP; TLS/public deployment remains unavailable. Token loss does not affect repository recovery. The browser has no repository-write, export, session, or recovery side effect.

## Verification

The native HTTP integration test authenticates a normal API request through Bearer, verifies a missing or wrong token fails, authenticates `GET /` through Basic, and checks escaped HTML includes the authenticated fixture's branch and object ID. Unit tests retain private-file, malformed, symlink, duplicate-file, non-loopback, malformed-body, and non-GET coverage.
