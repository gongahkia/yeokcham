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

Design and implementation handoff package. No production implementation should be assumed to exist.

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
