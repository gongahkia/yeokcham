# Troubleshooting

## `init` or a signed command cannot use the local signer

On Linux, native V1 custody uses the logged-in session's Secret Service. On
macOS it uses Keychain. Unlock or start the appropriate platform service in the
same user session and retry. On other platforms, native V1 signing is
unavailable. Do not copy a private key into `.yeokcham`; instead use a supported
platform or explicitly configure the documented SSH-agent or PKCS#11 custody
path.

`device custody --root PATH --device ID` reports the configured optional
provider and its local availability. It does not change authority.

## I did not record the recovery mnemonic

The `init` ceremony shows the 24-word mnemonic once by design. It cannot be
recovered from the repository, package, relay, username, or root-verification
phrase. Keep using the local device while it remains available, and follow the
explicit recovery/custody procedures before making a device-loss plan. Do not
post the mnemonic in an issue, chat, shell history, or package.

`init --format json` and `recovery use --format json` refuse before creating
custody or changing the repository. Run these ceremonies with `--format text`
in a private terminal so the one-time mnemonic is visible.

## `changes` reports unexpected paths

`changes` is an exact working-tree comparison against the latest checkpoint of
the active draft. It includes files, directories, mode changes, and symlinks in
stable path order; it does not classify a change as a rename or textual diff.
The `.yeokcham` and `.git` root names are excluded from this scan. Use
`timeline` to identify the saved checkpoint, inspect the path, then either
`save` deliberately or restore a checkpoint into an empty destination first.

Like `status`, the scan can write immutable unreferenced scan objects. It never
saves a checkpoint or changes the working-tree source itself.

`.yeokchamignore` also excludes the exact relative paths listed in it, together
with their descendants. Use one path per line, without a leading or trailing
slash. Blank lines and lines beginning with `#` are ignored. Patterns, `!`
negation, and Git's ignore syntax are not supported. Ignored contents have no
checkpoint; the ignore file itself is normally captured.

## I need an earlier file but do not want to overwrite current work

Use destination restore with an empty directory:

```sh
yeokcham restore --root PROJECT --checkpoint CHECKPOINT --destination EMPTY_DIR
```

Only omit `--destination` when you intend an in-place restore. Afterwards use
`restore proofs` and `storage roots` to inspect the retained recovery boundary.

If in-place restore reports an ignored path, move that entry outside the
working tree before retrying, or use destination restore. The command refuses
before deleting files because ignored bytes are absent from its safety
checkpoint. `workspace update --replace` has the same protection.

Missing or corrupt target content is rejected before materialisation. Use
`verify` to inspect damage and `repair plan --from SOURCE` to examine available
repair material. `timeline`, `log`, and `graph` inspect saved history without
scanning the live tree, so an unsupported live file such as a named pipe does
not prevent you from finding a recovery checkpoint.

## A second person cannot simply clone the repository

That is expected. V1 has no general clone or Git interchange. An existing
administrator must explicitly enrol the device, create an offline package (or
publish an explicit relay bootstrap basis), and the joining person must compare
the public root-verification phrase independently. Follow
[Collaboration and relay](COLLABORATION.md).

## Relay synchronization fails or is unavailable

The built-in relay backend listens as plain HTTP and must sit behind an
operator-managed HTTPS reverse proxy. The operator issues a repository-scoped
secret; the user enters it using `remote login`. A relay is a byte courier, not
authority and not a general clone service. `sync` verifies staged packages and
does not materialise the working tree. Check the remote URL, proxy TLS setup,
and credential scope with the operator rather than weakening verification.

## `watch` or `daemon` is unavailable

`watch` is available only on Linux and macOS. The managed `daemon` is
Linux-only and requires a private `XDG_RUNTIME_DIR`; macOS supports only the
foreground watcher. Both are advisory and optional. Explicit `save` remains the
portable V1 workflow on supported signing platforms.

## Where is the manual for a command?

Run `yeokcham --help`, `yeokcham help COMMAND`, or `yeokcham COMMAND --help`.
Invalid invocations still exit with an error rather than silently succeeding.
Use the [concepts glossary](CONCEPTS.md) to decide which kind of operation you
actually need.
