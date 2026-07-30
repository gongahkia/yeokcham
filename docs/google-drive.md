# Google Drive setup

## Scope and client

Yeokcham uses the non-sensitive `https://www.googleapis.com/auth/drive.file` scope. Enable the Google Drive API in the operator's Google Cloud project, create a **Desktop app** OAuth client, and supply its client ID to Yeokcham. Desktop OAuth clients are public clients: do not add a client secret to command arguments, repository configuration, a key export, or a shell profile.

`drive.file` permits Yeokcham to manage files and folders that it creates or that are explicitly opened with the application. Create a dedicated visible root with `yeokcham drive init --client-id <desktop-client-id>`; it prints an opaque folder ID for later commands. Yeokcham must not claim access to an arbitrary pre-existing folder merely because an operator knows its Drive ID. Selecting arbitrary existing folders needs a separate Picker-capable workflow or an explicit broader-scope design and is not implemented.

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

## Backup, restore, and verification

First create a passphrase-encrypted recovery-key export. This command refuses to overwrite its destination. Supply the passphrase on standard input, optionally with one trailing newline; never pass it as an argument or environment variable.

```text
yeokcham key create-export --passphrase-stdin <yeokcham-repo> <recovery-key-export>
```

After `drive auth` and `drive init`, back up the canonical repository snapshot. It uploads encrypted immutable segments, indexes, manifests, ref journals, and the final recovery manifest; SQLite and interrupted staging files are excluded.

```text
yeokcham drive backup --client-id <desktop-client-id> --folder-id <drive-folder-id> --key-export <recovery-key-export> --passphrase-stdin <yeokcham-repo>
```

On another machine, reauthorize the same Desktop OAuth client, supply the same folder ID and recovery export, then restore to an absent destination:

```text
yeokcham drive restore --client-id <desktop-client-id> --folder-id <drive-folder-id> --key-export <recovery-key-export> --passphrase-stdin <destination>
```

The restore command verifies the reconstructed repository before it reports success. To verify backend data without retaining a repository, use:

```text
yeokcham drive verify --client-id <desktop-client-id> --folder-id <drive-folder-id> --key-export <recovery-key-export> --passphrase-stdin
```

`drive verify` restores into one uniquely named temporary directory, runs normal repository verification, then removes only that directory. If an operator interrupts the command, its temporary directory can be removed manually; it is never a canonical repository.

## Current limitations

- `DriveBackend` maps logical keys to keyed opaque file names, stores an authenticated encrypted key capsule before each physical payload, uses bounded pagination and a positive metadata cache, and uses Google resumable uploads. The cache never records absence, create checks always query Drive, and local deletes invalidate cached metadata. Repository payloads must be wrapped in `EncryptedBackend`; the physical Drive backend does not make caller bytes confidential by itself.
- Create races fail closed. If final confirmation identifies the newly-created duplicate next to one existing file, Yeokcham removes only its own duplicate and returns `AlreadyExists`; it never replaces an existing Drive file. Incomplete resumable sessions are not accepted as backend objects and can be abandoned safely.
- Standalone `chunks/` objects are rejected. Content-defined chunks stay packed in immutable segments, preventing one Drive file per chunk.
- Drive synchronization currently publishes the immutable recovery snapshot; direct remote-helper clone/fetch and multi-device journal reconciliation are not yet available.
- Only the operator's configured Desktop OAuth client can access its app-created Drive files under `drive.file`.
- Sharing or moving the dedicated root remains a later Drive backend workflow and must retain opaque encrypted object names.
