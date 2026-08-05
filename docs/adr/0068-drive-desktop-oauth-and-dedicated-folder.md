# ADR-0068: Use Desktop OAuth and a dedicated Drive folder

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Milestone 5 needs a Google Drive authorization boundary and a location for encrypted canonical data. The repository must remain recoverable, user-visible, and suitable for explicit sharing or migration. Google treats a desktop OAuth client as a public client: it cannot safely keep a client secret. Google also documents `appDataFolder` as hidden app-specific configuration storage with sharing and lifecycle constraints.

## Decision drivers

- Use the least privilege scope that supports user-selected and app-created repository files.
- Bind authorization responses to an in-process local request.
- Keep access and refresh tokens out of repository configuration and diagnostics.
- Do not make encrypted canonical data dependent on a hidden provider-specific app-data lifecycle.
- Preserve an explicit operator-visible recovery location.

## Considered options

### Option 1: Desktop OAuth, `drive.file`, and a selected folder

Use an operator-supplied Google Desktop OAuth client ID. Open consent in the system browser, receive the authorization code on a random localhost port, use PKCE S256 and state verification, then store only opaque encrypted files under an explicit dedicated Drive folder created or opened by the application.

### Option 2: `appDataFolder`

Use Google's hidden app-specific folder and the `drive.appdata` scope. It is not user-browsable, cannot share or move its contents, and does not satisfy the selected-folder recovery workflow.

### Option 3: Full Drive scope

Request unrestricted Drive access. This has more consent and verification burden than the selected-folder workflow requires.

## Decision

Use Option 1. The current core exposes a bounded `DriveOAuthLoopback`: it binds only `127.0.0.1`, generates fresh state and PKCE verifier bytes through the operating-system random source, uses `S256`, and sends the code only to the fixed Google token endpoint through a bounded HTTPS transport. A successful exchange accepts only Bearer access/refresh token pairs and validates a returned scope when present. `KeyringDriveCredentialStore` writes only the refresh token to the platform Keychain/keyring under an account label derived from SHA-256 of the client ID. Default diagnostics redact authorization state, verifier, HTTP body, access token, and refresh token.

The Drive root-folder identifier, Drive file mapping, and a hardware-device OAuth flow are separate subsequent slices. The OAuth client ID is operator configuration, not a secret embedded in Yeokcham. A stored credential can refresh a short-lived in-memory access token at the fixed Google token endpoint without changing its Keychain/keyring refresh token. The `yeokcham drive auth` command prints rather than launches the consent URL; its caller can choose a fixed loopback port for SSH forwarding from a headless host to a browser-capable machine.

## Consequences

The operator must create or supply a Google Desktop OAuth client ID with the Drive API enabled. A browser-capable machine is required for this loopback flow, but it may connect through an explicitly forwarded fixed loopback port. The current implementation relies on platform Keychain/keyring availability and fails rather than creating a plaintext token file. A hardware-device OAuth flow is deferred because Google directs normal desktop/CLI applications to the Desktop flow; deprecated copy/paste redirects are never used.

The dedicated folder can be inspected, retained, shared deliberately, and used for recovery. `drive.file` does not grant arbitrary existing-folder access from a known ID; that selection needs a Picker-capable workflow or an explicit broader-scope decision. Names and IDs inside the dedicated folder must remain opaque once the Drive backend maps Yeokcham keys; that remote-key format is not selected by this ADR.

## Security and recovery

The listener is loopback-only and accepts one bounded HTTP callback. State mismatch, malformed callbacks, non-Bearer token types, omitted refresh tokens, unsupported scopes, and non-success token responses fail closed. Refresh accepts only a new Bearer access token and does not silently replace the persisted refresh token. Network, JSON, and platform-credential error sources are retained for explicit diagnosis but default error rendering omits them. OAuth credentials do not enter repository bytes, manifests, key exports, or default logs.

## Compatibility and migration

This adds no repository record format. A future authorization method or scope change must document how it coexists with stored Drive folder configuration and credential-store entries.

## Verification

Unit tests prove a valid loopback callback exchanges a code only after state validation, wrong state never reaches the token transport, PKCE S256 parameters are emitted, invalid client IDs and missing refresh tokens fail, token diagnostics are redacted, and a credential-store seam persists, loads, and deletes refresh tokens without accessing the operator's OS store. Full workspace CI, rustdoc with warnings denied, and fuzz smoke run before acceptance.
