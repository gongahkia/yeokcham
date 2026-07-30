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

Milestones 1 and 2 are implemented. The local `git-remote-yeokcham` bridge supports ref discovery, clone, fetch, and a staged local `git push` workflow through C Git, using verified Yeokcham storage and a disposable snapshot-pack cache. Push accepts fast-forward branch creation, update, and deletion; tags are create-only. Signed multi-device updates, crash injection, encryption, and remote backends remain unfinished.

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
git --git-dir=<destination-git-repo> fsck --full --strict
```

`init` requires a destination path that does not exist. A failed import can leave unreachable immutable records in that fresh path; remove the failed destination before retrying. The initial CDC threshold is 4 KiB; `--chunked-blob-minimum <bytes>` is available for controlled storage-policy comparison, not as a benchmark-backed default recommendation.

`sync` is a controlled local-source maintenance workflow, not `git push`: it imports only newly reachable verified objects, then appends a checked full ref-state transition. Reuse one canonical UUIDv4 `--device` value for its writer. V1 journal events detect corruption, stale expected state, and divergent histories but are not signed. The core also supports caller-supplied Ed25519-signed V2 events, but it has no persistent key store, device-key registration, authorization, or revocation yet; `sync` therefore remains a single-trusted-local-writer workflow.

## Local remote helper

Build the binaries, place the build directory on `PATH`, then use Git's explicit remote-helper syntax:

```bash
cargo build -p yeokcham-cli
export PATH="$PWD/target/debug:$PATH"
git ls-remote yeokcham::/absolute/path/to/yeokcham-repository
git clone yeokcham::/absolute/path/to/yeokcham-repository
```

For each `connect git-upload-pack` request, the helper verifies the effective Yeokcham ref state. It reuses a full bare snapshot pack under `<store>/cache/packs/<ref-state-sha256>` only after exact-ref comparison and `git fsck --full --strict`; a missing, partial, or corrupt entry is rebuilt from a verified export. This cache contains local conventional Git objects, is disposable, and is not a cache of a negotiated upload-pack response. The helper then delegates the smart protocol and negotiated pack stream to C Git. This remains a correctness bridge, not a measured performance path. After a successful `yeokcham sync`, ordinary Git can fetch updated and deleted refs with `git fetch --prune`.

`git push` stages each `connect git-receive-pack` operation in a private temporary bare repository. C Git checks the pack and advertised old ref values, then Yeokcham imports and verifies the complete staged graph using its normal storage policy. The helper relays a successful final status only after a checked canonical ref-journal append. Fast-forward branch create, update, and deletion are allowed; force branch replacement is rejected. Tags are immutable after creation: move and delete requests are rejected. Push remains an unsigned single-trusted-local-writer workflow, and shallow operations remain deferred.

## Contributing and licence

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Yeokcham is licensed under the [`MIT License`](LICENSE).
