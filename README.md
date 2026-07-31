# Yeokcham

Yeokcham is a **Git-compatible, local-first, encrypted repository accelerator and sovereign remote**.

Its design principle is:

> Git-compatible at the boundary, chunk-addressed internally.

Yeokcham is intended for ordinary software developers who want to keep using Git tooling while gaining:

- Better storage efficiency for long histories and frequently changing large binaries.
- Faster metadata-first clones and working-set hydration.
- A canonical repository that can live on local disk, a self-hosted server, Google Drive, or another dumb object store.
- Optional GitHub mirroring rather than mandatory GitHub dependence.
- End-to-end encryption before objects leave the user's machine.
- Recovery and export paths that do not depend on a Yeokcham-hosted cloud service.

## Status

Milestones 1 and 2 are implemented. The local `git-remote-yeokcham` bridge supports ref discovery, clone, fetch, and a staged local `git push` workflow through C Git, using verified Yeokcham storage and a disposable snapshot-pack cache. Push accepts fast-forward branch creation, update, and deletion; tags are create-only. Ref-transaction crash injection covers bootstrap and journal mutation boundaries. The integration test restores stale local remote-tracking state after an accepted push; a fresh retry then leaves the journal un-duplicated. Signed multi-device authorization, encryption, and remote backends remain unfinished.

## Recommended implementation language

Rust, using the stable toolchain.

The implementation may use gitoxide and other mature crates for low-level Git primitives. Yeokcham's differentiation is not reimplementing SHA parsing or packfile decoding from scratch. The important work is the storage model, chunking, encryption, crash consistency, remote protocol, caching, mirroring, and operational simplicity.

## Repository goals

Yeokcham should eventually support:

1. Importing any ordinary Git repository.
2. Serving it through a Git-compatible remote.
3. Chunk-deduplicating large and repeatedly changed content.
4. Keeping Git commit, tree, tag, and blob identities intact.
5. Reconstructing valid Git objects and packs on demand.
6. Encrypting repository data before uploading it.
7. Using Google Drive as an immutable blob backend, not as a synchronised `.git` directory.
8. Supporting local filesystem, HTTP, and other backends through a common backend interface.
9. Mirroring selected refs to and from GitHub.
10. Exporting a complete conventional Git repository at any time.

## Non-goals for the first usable release

- Replacing the Git CLI.
- Building a complete GitHub alternative.
- Multi-tenant hosting.
- GitHub issues, discussions, wikis, or Actions replacement.
- A virtual filesystem for giant monorepos.
- Peer-to-peer repository discovery.
- A novel source-level merge algorithm.
- Claiming universal performance superiority before benchmarks support it.

## Read order for an implementation agent

1. `PROJECT_CONTEXT.md`
2. `PRD.md`
3. `ARCHITECTURE.md`
4. `DECISIONS.md`
5. `SECURITY_AND_RECOVERY.md`
6. `TESTING_AND_BENCHMARKS.md`
7. `TODO.md`
8. `AGENTS.md`
9. `CODEX_PROMPT.md`

## First implementation target

The first end-to-end milestone is deliberately narrow:

> Import a Git repository into a local Yeokcham store, serve it through `git-remote-yeokcham`, clone it into a new directory, and prove byte-for-byte and object-ID equivalence with the original repository.

Do not start with Google Drive, GitHub synchronisation, a daemon, a web UI, or performance claims.

## Rust support

Yeokcham's minimum supported Rust version (MSRV) is 1.85. The repository toolchain is pinned to 1.85.0, and CI also tests the latest stable Rust release. Raising the MSRV requires an explicit documented change.

The remote-helper integration suite runs with the two latest pinned upstream C Git releases, currently 2.54.0 and 2.55.0. Updating this matrix requires updating the checksum-pinned build script and exercising the same clone/fetch/prune scenario.

## Development

Run `make help` to list development targets and `make ci` for the complete locked local CI gate.

## Local workflow

```bash
yeokcham init --from-git <source-git-repo> <yeokcham-repo>
yeokcham sync --from-git <source-git-repo> <yeokcham-repo> --device <device-id>
yeokcham verify <yeokcham-repo>
yeokcham inspect refs <yeokcham-repo>
yeokcham inspect storage <yeokcham-repo>
yeokcham inspect object <yeokcham-repo> <git-object-id>
yeokcham export-git <yeokcham-repo> <destination-git-repo>
yeokcham recover --export-git <yeokcham-repo> <destination-git-repo>
yeokcham cache inspect|verify|clear <yeokcham-repo>
yeokcham cache trim --max-bytes <bytes> <yeokcham-repo>
yeokcham github configure <yeokcham-repo> --repository <owner/repository> --direction <publish-only|pull-only|bidirectional-fast-forward|manual> --publish <heads|tags|refs/heads/*|refs/tags/*>
yeokcham github inspect <yeokcham-repo>
yeokcham github plan [--show-objects] <yeokcham-repo>
yeokcham github publish <yeokcham-repo> --apply [--transport <https|ssh>]
yeokcham github publish-pr <yeokcham-repo> --source <refs/heads/branch> --branch <remote-branch> --apply [--transport <https|ssh>]
yeokcham github fetch <yeokcham-repo> [--show-refs] [--transport <https|ssh>]
yeokcham github resolve <yeokcham-repo> --accept-remote <refs/heads/branch> --remote <refs/heads/branch> --apply [--transport <https|ssh>]
yeokcham drive auth --client-id <google-desktop-client-id>
git --git-dir=<destination-git-repo> fsck --full --strict
```

`init` requires a destination path that does not exist. A failed import can leave unreachable immutable records in that fresh path; remove the failed destination before retrying. The initial CDC threshold is 4 KiB; `--chunked-blob-minimum <bytes>` is available for controlled storage-policy comparison, not as a benchmark-backed default recommendation. Import source reads are serial by default; `--object-read-workers <1..8>` is a bounded controlled-comparison option that retains at most 64 MiB of verified bodies before serial publication.

`recover --export-git` is the offline recovery export. It first fully verifies the supplied local canonical repository, then creates an absent conventional bare Git destination with reconstructed refs and objects. It makes no network or credential request. After `drive restore` has rebuilt a local destination from an encrypted snapshot, use this command to produce a conventional Git repository; a failed export can leave an incomplete destination that must be discarded before retrying.

`sync` is a controlled local-source maintenance workflow, not `git push`: it imports only newly reachable verified objects, then appends a checked full ref-state transition. Reuse one canonical UUIDv4 `--device` value for its writer. The local CLI and remote helper remain V1 single-trusted-local-writer workflows. The core separately supports root-pinned remote device registries: immutable `YKDR` registration/revocation records authorize only matching Ed25519-signed V2 ref events, reject stale writers before publication, and retain every divergent branch for explicit resolution. The registry root public key is an out-of-band trust anchor and its signing key is caller-managed; Drive clone/push wiring remains unfinished.

`drive auth` starts a Google Desktop OAuth PKCE flow, prints a one-time browser URL, and stores the returned refresh token only in the operating-system credential store. It needs an operator-created Desktop OAuth client ID with the Drive API and `drive.file` scope enabled. For a headless host, reserve a local port first, forward it with SSH, then run `yeokcham drive auth --client-id <id> --redirect-port <port>` and open the displayed URL on the forwarded machine. Do not use deprecated copy/paste authorization or place refresh tokens in repository configuration. `drive init` creates an opaque app-owned Drive folder; `key create-export`, `drive backup`, `drive restore`, and `drive verify` provide encrypted recovery-snapshot transfer with passphrases accepted only on standard input.

`github configure` stores a local, token-free mirror policy. At least one selected branch/tag rule and an explicit direction are required; omission of `--force-update` uses `reject`. `github inspect` reports the policy and checkpoint counts without echoing the target or selected ref names. `github plan` reconstructs a verified temporary bare export, reports each selected local/remote ref and the complete reachable-object count, then removes that export. `--show-objects` emits every selected graph object ID but no object body.

`github publish` requires the deliberate `--apply` switch and pushes only those configured selected refs. It uses either `https://github.com/<owner>/<repository>.git` (default) through the standard preconfigured Git credential helper or `git@github.com:<owner>/<repository>.git` through the standard SSH agent. Yeokcham stores no GitHub token, disables terminal/askpass prompts, and does not permit inherited Git/SSH command overrides; authenticate with Git before publishing. The push requests atomic remote application, rejects tag replacement, confirms every remote object ID by a second ref read, then atomically records checkpoints only if the local refs remain current. `require-exact-checkpoint` grants a non-fast-forward branch lease only when the remote still equals its recorded checkpoint.

`github publish-pr` publishes one selected local branch to the named remote branch, records that explicit mapping as its checkpoint, and retains the same authentication, atomic-push, post-push-confirmation, and force-policy checks. It does not create a GitHub pull request; open the published branch through GitHub's normal UI or API.

`github fetch` reads selected remote branch/tag refs through the same configured Git credential helper or SSH agent, fetches them only into a disposable bare repository, verifies the fetched IDs still match the preflight read, and imports their immutable objects. It never moves a canonical ref. The summary reports remote-only, local-only, and divergent mappings; `--show-refs` explicitly reveals the selected ref names and object IDs. Existing local refs receive an observed remote checkpoint only after imported objects verify and the local ref remains current. An explicit resolution workflow is still required to adopt a remote ref.

`github resolve --accept-remote <local-ref> --remote <remote-ref> --apply` is that workflow. It permits only a mapping selected by the configured rules or an explicit existing checkpoint, re-reads and refetches the remote ref, verifies/imports its objects, then appends one expected-state local ref event. A concurrent local ref change fails closed. After the ref event, it records a checkpoint whose local and remote IDs equal the accepted remote ID; retry if that final checkpoint write fails. It accepts neither a silent force update nor an unselected mapping.

See [Google Drive setup](docs/google-drive.md) for the exact Desktop-client, scope, headless, and recovery requirements.

## Local remote helper

Build the binaries, place the build directory on `PATH`, then use Git's explicit remote-helper syntax:

```bash
cargo build -p yeokcham-cli
export PATH="$PWD/target/debug:$PATH"
git ls-remote yeokcham::/absolute/path/to/yeokcham-repository
git clone yeokcham::/absolute/path/to/yeokcham-repository
```

For each `connect git-upload-pack` request, the helper verifies the effective Yeokcham ref state. It reuses a full bare snapshot pack under `<store>/cache/packs/<ref-state-sha256>` only after exact-ref comparison and `git fsck --full --strict`; a missing, partial, or corrupt entry is rebuilt from a verified export. This cache contains local conventional Git objects, is disposable, and is not a cache of a negotiated upload-pack response. The helper then delegates the smart protocol and negotiated pack stream to C Git. Its disposable C Git invocation enables `uploadpack.allowFilter` and accepts only reachable object-ID wants, so native filtered clones work:

```bash
git clone --filter=blob:none --no-checkout yeokcham::/absolute/path/to/yeokcham-repository
git clone --filter=blob:limit=1048576 --no-checkout yeokcham::/absolute/path/to/yeokcham-repository

git clone --filter=blob:none --no-checkout yeokcham::/absolute/path/to/yeokcham-repository sparse-worktree
git -C sparse-worktree sparse-checkout set --cone path/to/current-work
git -C sparse-worktree checkout main
```

C Git records promisor state and hydrates omitted reachable blobs on checkout or access through a new helper connection. The sparse sequence configures the selected current paths before checkout, so C Git hydrates those paths while excluded current blobs remain promised. Yeokcham still reconstructs a complete disposable snapshot before C Git filters its outgoing pack, so this is Git-transfer compatibility rather than measured backend partial retrieval. It is tested with current C Git cone-mode sparse checkout. Shallow clone and native remote-backend sparse prefetch are unsupported; non-cone and sparse-index configurations are not currently covered. `yeokcham cache inspect <repo>` reports bounded local snapshot-cache counts and bytes. `yeokcham cache verify <repo>` first verifies canonical storage, then checks every cache entry's ref-state-derived name and runs strict Git fsck without emitting cache data. `yeokcham cache trim --max-bytes <bytes> <repo>` enforces a caller-selected snapshot-cache ceiling by evicting least-recently-used entries; run it outside active helper operations. `yeokcham cache clear <repo>` validates the repository bootstrap, rejects a symlink or non-directory cache path, and removes only `<repo>/cache`; the next helper connection rebuilds a required snapshot from verified storage. After a successful `yeokcham sync`, ordinary Git can fetch updated and deleted refs with `git fetch --prune`.

The local daemon accepts either explicit `--sparse-path` values or one opt-in `--sparse-checkout-file <path>` alongside `--repository <yeokcham-repo>`. The latter reads only that supplied regular file, polls only its metadata for changes, and never discovers a worktree. It accepts a 4 MiB maximum canonical C Git cone-mode configuration, derives its recursive directory entries, and refreshes the disposable object cache and verified snapshot-pack cache after a file or acknowledged-ref change. Non-cone, escaped, malformed, and root-only configurations fail closed; use explicit `--sparse-path` values for those cases. The [committed W5 result](benchmarks/results/2026-07-31-daemon-prewarmed/) has a later daemon-prebuilt helper checkout median of 1.10 s versus 2.56 s cold; it excludes daemon startup and prewarm cost, and does not exceed an already-warm helper cache.

## Native HTTP V1

`yeokcham-server token create <private-token-file>` creates a private random token file without printing its secret. `yeokcham-server --repository <yeokcham-repo> --auth-token-file <private-token-file>` then starts the read-only Yeokcham-native HTTP V1 service on an ephemeral `127.0.0.1` port and prints its address. `--bind 127.0.0.1:<port>` selects a known loopback port. Every endpoint requires the token: native clients use Bearer, while a normal browser can use Basic username `yeokcham` with the token as password to view repository refs, bounded commit/tree metadata, verified local-storage counts, a read-only integrity result, and redacted GitHub-mirror policy state. It reports that V1 attaches no remote backend and performs no backend/GitHub network or credential call. It also serves native health, ref discovery, and verified raw Git-object retrieval. It is not Git smart HTTP and accepts no public address. See [the V1 contract](docs/native-http-v1.md).

`git push` stages each `connect git-receive-pack` operation in a private temporary bare repository. C Git checks the pack and advertised old ref values, then Yeokcham imports and verifies the complete staged graph using its normal storage policy. The helper relays a successful final status only after a checked canonical ref-journal append. Fast-forward branch create, update, and deletion are allowed; force branch replacement is rejected. Tags are immutable after creation: move and delete requests are rejected. Push remains an unsigned single-trusted-local-writer workflow, and shallow operations remain deferred.

## Contributing and licence

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Yeokcham is licensed under the [`MIT License`](LICENSE).
