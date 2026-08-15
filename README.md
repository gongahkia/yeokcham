# Yeokcham

An experimental Unix-first version-control system that keeps recovery,
collaborative intent, and release history distinct. Yeokcham aims to become a
native alternative VCS; it is not yet a production-ready replacement for Git.

> Recovery history, collaborative intent history, and release history serve
> different purposes and should not be forced into one commit graph.

Yeokcham is a portfolio and research prototype, not a production Git
replacement. Exact file bytes are canonical; semantic analysis is optional,
bounded evidence rather than source-of-truth history.

## Start here

The supported product direction is macOS, Linux, and WSL. The checked-in
development environment uses opam and OCaml 5.5.0; platform verification is
recorded only where it has actually been run. Create the repository-local
switch and run the standard local check:

```sh
brew install opam actionlint
make setup
make check
```

Try the local CLI from a directory you want Yeokcham to manage:

```sh
dune exec bin/yeokcham.exe -- init
dune exec bin/yeokcham.exe -- status
dune exec bin/yeokcham.exe -- checkpoint
dune exec bin/yeokcham.exe -- timeline --limit 32
dune exec bin/yeokcham.exe -- --help
```

`make check` runs the build, format verification, lint, package validation,
tests, persistent-format audit, and static experiment-schema checks. Run
`make ci` as well when changing GitHub Actions configuration; it additionally
runs `actionlint`.

## The model

| History | Purpose | Current boundary |
| --- | --- | --- |
| Scratch | automatic, bounded recovery checkpoints | A checkpoint is a local safety record and can be compacted under explicit retention rules. |
| Intent | human-curated capsules and their immutable revisions | A capsule describes logical work; selecting revisions in a workspace can yield explicit conflicts. |
| Release | immutable, reproducible snapshots | A release binds validated workspace inputs and remains separate from Git export metadata or attestations. |

The distinction is deliberate: a checkpoint is not a capsule, a capsule is not
a release, and a conflict is a value to inspect rather than an invented merge.
Read the [architecture walkthrough](docs/ARCHITECTURE_WALKTHROUGH.md) for the
implemented data flow and failure boundaries.

## What is implemented

- Exact directory snapshots, automatic scratch checkpoints, guarded restore,
  retention, and compaction.
- Durable capsules, dependencies, immutable revisions, workspaces, explicit
  conflicts, and exact operation retargeting.
- Repository inspection through `status`, enriched `timeline`, `storage stats`,
  and repository-wide `verify`.
- Bounded direct-argv validation, immutable release records, and separate
  test-only deterministic attestations.
- A deliberately narrow local Git preservation/adoption/exit bridge.
- Direct peer publication over a selected local repository or SSH: the
  receiver gets an inspectable capsule or release projection, never a sender's
  scratch history or an implicit workspace mutation.

## V3 direction

The active roadmap is a small native VCS rather than the retired V2 hosted
platform:

1. Stabilise the local scratch, capsule, workspace, conflict, and release
   workflow.
2. Provide explicit Git preservation, adoption, and exit so Git users can try
   Yeokcham without abandoning their history.
3. Add direct peer exchange over a local path and SSH, publishing only
   selected intent and release history by default.

This direction is governed by [ADR-073](docs/adr/073-unix-first-vcs-git-migration-and-peer-exchange.md)
and issues [#233](https://github.com/gongahkia/yeokcham/issues/233) through
[#236](https://github.com/gongahkia/yeokcham/issues/236).

Important limits remain intentional:

- Production release signing is deferred; the deterministic signer is test-only
  and does not authenticate a release.
- Semantic TypeScript and Rust adapters are isolated experiments. They do not
  become canonical data or authorise a rewrite.
- The V3 Git bridge preserves selected Git refs as foreign bundles, supports
  explicit one-parent (or root) capsule adoption with a durable receipt, and
  reconstructs a valid Git exit repository. It does not provide implicit sync,
  general Git semantic equivalence, or automatic merge interpretation.
- Peer exchange is deliberately proposal-only. Capsule projections can be
  adopted into a receiver-authored local capsule; release projections retain
  provenance but cannot manufacture local validation or a native release.
- The local CLI currently uses the V2 repository format. The retired parts are
  its hosted, browser, MLS, mesh, and IDE roadmap; they are not a supported
  delivery path.
- Restore and workspace materialisation guard divergent work, but are not
  crash-atomic for a populated working directory.

## Command-line workflow

The short recovery loop is `checkpoint`, `timeline`, and `restore`. Capsules
capture selected scratch work; workspaces compose their revisions; a release is
created only from a complete, validated workspace attempt.

```sh
dune exec bin/yeokcham.exe -- checkpoint
dune exec bin/yeokcham.exe -- restore --dry-run <checkpoint-id>
dune exec bin/yeokcham.exe -- capsule create --current --id <capsule-id> --title <title> --description <description>
dune exec bin/yeokcham.exe -- work create --id <workspace-id> --base <snapshot-id>
dune exec bin/yeokcham.exe -- work materialise <workspace-id> --dry-run
dune exec bin/yeokcham.exe -- release create --workspace <workspace-id>
```

The [CLI reference](docs/CLI.md) records the command groups, mutation rules,
and safety constraints. The executable’s `--help` output is the authoritative
top-level command list.

## Documentation

The [documentation index](docs/README.md) is the starting point for the full
set of project references.

| Need | Read |
| --- | --- |
| Product intent and scope | [Project context](PROJECT_CONTEXT.md) and [PRD](PRD.md) |
| Model, storage, and architecture | [Formal model](FORMAL_MODEL.md), [architecture](ARCHITECTURE.md), and [decisions](DECISIONS.md) |
| Git and local exchange boundaries | [Git interchange](docs/GIT_INTERCHANGE.md) and [local synchronisation](docs/LOCAL_SYNCHRONISATION.md) |
| Demonstrated workflows | [Architecture walkthrough](docs/ARCHITECTURE_WALKTHROUGH.md) and the linked demo documents |
| Measured or negative research results | [Research and benchmark report](docs/RESEARCH_AND_BENCHMARK_REPORT.md) |
| Current work record | [Issue tracking](docs/ISSUE_TRACKING.md) and the live [GitHub issue tracker](https://github.com/gongahkia/yeokcham/issues) |

## Get help

Start with the relevant contract or walkthrough above. If the documented
prototype boundary does not explain an observed behaviour, search the
[existing issues](https://github.com/gongahkia/yeokcham/issues) before opening a
focused, reproducible report. Issue reports are part of the project record, so
they should distinguish an implementation defect from a proposed model change.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the repository’s
[agent guide](AGENTS.md) before proposing a model or persistent-format change.
Contributions must preserve the scratch/intent/release distinction, define
invariants before adapters, and include the appropriate failure and generated
tests. GitHub Issues is the historical and active work record.

## License

Yeokcham is available under the [MIT License](LICENSE).
