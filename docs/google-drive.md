# Google Drive setup

## Scope and client

Yeokcham uses the non-sensitive `https://www.googleapis.com/auth/drive.file` scope. Enable the Google Drive API in the operator's Google Cloud project, create a **Desktop app** OAuth client, and supply its client ID to Yeokcham. Desktop OAuth clients are public clients: do not add a client secret to command arguments, repository configuration, a key export, or a shell profile.

`drive.file` permits Yeokcham to manage files and folders that it creates or that are explicitly opened with the application. The default Drive backend therefore creates a dedicated visible Yeokcham root folder. It must not claim access to an arbitrary pre-existing folder merely because an operator knows its Drive ID. Selecting arbitrary existing folders needs a separate Picker-capable workflow or an explicit broader-scope design and is not implemented.

Do not use `drive.appdata` for canonical repository data: its folder is hidden from the Drive UI and cannot be shared or moved. Do not request broad `drive` scope for the default backend.

## Authorization

Run:

```text
yeokcham drive auth --client-id <desktop-client-id>
```

The command prints a one-time PKCE authorization URL. Open it in a system browser, grant the displayed `drive.file` request, then return to the command. Yeokcham stores the returned refresh token only in the operating-system credential store. The access token remains in memory and is refreshed through Google's token endpoint when needed.

For a headless host, reserve a local port and forward it before starting authorization:

```text
ssh -L 8787:127.0.0.1:8787 <host>
yeokcham drive auth --client-id <desktop-client-id> --redirect-port 8787
```

Open the printed URL in the browser at the forwarding endpoint. The callback stays bound to `127.0.0.1`, and PKCE plus state validation remain active. Google deprecated copy/paste authorization redirects; Yeokcham does not support them.

## Credential recovery

Losing the OS credential entry requires running `drive auth` again. It does not lose repository data or the repository encryption key, but no Drive API request can authenticate until reauthorization succeeds. Back up repository encryption keys through the separate Yeokcham key-recovery workflow; never treat an OAuth refresh token as encryption-key recovery material.

## Current limitations

- The Drive file backend, remote-key mapping, transfer resume, metadata cache, and repository verification command are not yet available.
- Only the operator's configured Desktop OAuth client can access its app-created Drive files under `drive.file`.
- Sharing or moving the dedicated root remains a later Drive backend workflow and must retain opaque encrypted object names.
