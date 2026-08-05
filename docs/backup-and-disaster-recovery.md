# Backup and disaster recovery

This runbook covers the implemented encrypted Google Drive recovery snapshot and offline Git export. It does not make GitHub mirrors, the disposable cache, SQLite metadata, or an OAuth refresh token a recovery source.

## Recovery material

Keep three independently recorded items:

1. The canonical repository path.
2. The Drive folder ID created by `yeokcham drive init`.
3. A passphrase-encrypted repository key export stored separately from the Drive account.

Create the key export before the first remote snapshot. The destination must not exist. Supply the passphrase only on standard input; never place it in shell history, arguments, environment variables, or repository configuration.

```text
yeokcham key create-export --passphrase-stdin <yeokcham-repo> <recovery-key-export>
```

Loss of both the repository encryption key and every recovery-key export is unrecoverable. Reauthorizing Drive restores API access only; it does not recover a lost repository key.

## Create a recovery snapshot

First authenticate with an operator-created Google Desktop OAuth client, then create the dedicated app-owned Drive root and record the printed folder ID.

```text
yeokcham drive auth --client-id <desktop-client-id>
yeokcham drive init --client-id <desktop-client-id>
```

Verify the local source before backing it up.

```text
yeokcham verify <yeokcham-repo>
```

Then publish the encrypted immutable snapshot:

```text
yeokcham drive backup --client-id <desktop-client-id> --folder-id <drive-folder-id> --key-export <recovery-key-export> --passphrase-stdin <yeokcham-repo>
```

The backup contains canonical segments, indexes, manifests, ref journals, and the final recovery manifest. It excludes SQLite metadata, cache contents, and recognized interrupted staging files. The snapshot manifest is immutable: backing up changed canonical data to the same accepted Drive root fails with a conflict. For a newer snapshot, create and record a new dedicated Drive root; retain the earlier root until the newer restore drill succeeds.

The backup interval and retention period are operator policy. Choose them from the accepted data-loss window and storage policy; Yeokcham does not claim a default RPO or retention guarantee.

## Verify a remote snapshot

Run this after each accepted snapshot and before discarding its predecessor:

```text
yeokcham drive verify --client-id <desktop-client-id> --folder-id <drive-folder-id> --key-export <recovery-key-export> --passphrase-stdin
```

`drive verify` restores to one generated temporary location, runs ordinary repository verification, and removes only that location after success. It does not alter the canonical source repository or Drive snapshot. An interrupted verification can leave its generated temporary directory for manual cleanup.

## Restore after local loss

On a replacement machine, install a compatible Yeokcham build, authorize the same Desktop OAuth client, and restore to an absent destination:

```text
yeokcham drive auth --client-id <desktop-client-id>
yeokcham drive restore --client-id <desktop-client-id> --folder-id <drive-folder-id> --key-export <recovery-key-export> --passphrase-stdin <absent-restored-repo>
yeokcham verify <absent-restored-repo>
```

The restore authenticates and checks encrypted backend data, reconstructs canonical files, opens the repository, and verifies it before success. A failed restore can leave an incomplete destination; do not reuse it. Preserve it only for diagnosis, or discard that exact failed destination before a new restore attempt.

Produce an independent conventional Git recovery export only after the local verification succeeds:

```text
yeokcham recover --export-git <absent-restored-repo> <absent-bare-git-destination>
git --git-dir=<absent-bare-git-destination> fsck --full --strict
```

`recover --export-git` is offline: it makes no Drive, network, or credential request. It fully verifies the canonical repository before creating the required-absent bare Git destination. If export fails, discard that exact incomplete destination before retrying.

## Local export backup

For a second independent backup path, periodically run `yeokcham verify`, make a conventional Git export, verify it with `git fsck --full --strict`, and store that export using an independently controlled backup system. The export is ordinary Git data; apply the backup system's confidentiality and retention controls. It does not replace the encrypted recovery-key export.

## Failure handling

| Condition | Required action |
| --- | --- |
| Local verification fails | Stop publication and recovery writes; retain evidence and investigate the reported corruption. Do not trust reconstructed objects. |
| Drive backup conflicts | Treat the existing snapshot as immutable; create a new dedicated Drive root for changed canonical data. |
| OAuth credential lost | Repeat `drive auth`; do not create a new key export or overwrite snapshot records. |
| Recovery key/passphrase rejected | Stop. Confirm the separately stored key export and passphrase through an approved recovery process; no backend operation can replace a missing key. |
| Restore/export interrupted | Treat only the exact generated destination as disposable; verify no path ambiguity before removal, then retry to a fresh absent destination. |
| Remote verification fails | Do not accept the snapshot. Retain logs without credentials, preserve the older verified root, and recover from the last verified snapshot. |

## Restore drill record

For each drill, record only non-secret evidence: timestamp, Yeokcham/Git version, snapshot folder identifier under the operator's record policy, `drive verify` result, local `verify` result, and `git fsck` result. Do not record passphrases, key-export bytes, OAuth URLs, tokens, source contents, or remote object names. Clean-machine execution and operator scheduling remain release-validation work.

See [Google Drive setup](google-drive.md) for OAuth scope and headless-host details, and [security and recovery](../SECURITY_AND_RECOVERY.md) for threat-model and key-loss constraints.
