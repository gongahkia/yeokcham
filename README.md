[![](https://img.shields.io/badge/yeokcham_1.0-passing-green)](https://github.com/gongahkia/yeokcham/releases/tag/1.0)
[![](https://github.com/gongahkia/yeokcham/actions/workflows/ci.yml/badge.svg)](https://github.com/gongahkia/yeokcham/actions/workflows/ci.yml)
[![](https://github.com/gongahkia/yeokcham/actions/workflows/development-client-artifact.yml/badge.svg)](https://github.com/gongahkia/yeokcham/actions/workflows/development-client-artifact.yml)
[![](https://github.com/gongahkia/yeokcham/actions/workflows/relay-artifact.yml/badge.svg)](https://github.com/gongahkia/yeokcham/actions/workflows/relay-artifact.yml)

# `Yeokcham`

<div align="center">
  <img src="./asset/logo/yeokcham.png" width="25%" alt="Solomon logo">
  <p><strong>A model-first, local-first version-control system for small trusted teams.</strong></p>
</div>

## Rationale

`Yeokcham` separates automatic scratch recovery, explicit shared changes,
unresolved decisions, and delivery history. It is deliberately conservative:
a filesystem event, conflict, device name, or CI result is never treated as
user intent.

## Features

I wanted `Yeokcham` to be as joyful as possible. It [currently](https://github.com/gongahkia/yeokcham/issues) has the below capabilities.

* Exact byte, mode, directory, and symlink snapshots, with saved checkpoints, pins, bounded retention, and journaled restore.
* Changes: a stable, exact comparison of the working tree against the active draft's latest checkpoint, without guessing textual intent.
* Explicit drafts, immutable shared revisions, unresolved decisions, and
  delivery milestones instead of one synthetic commit history.
* Inspectable local storage collection: review retained objects, quarantine
  candidates, restore a quarantine, then explicitly purge it.
* Offline directory packages, signed relay publication and bootstrap with
  complete snapshot*closure verification; receiving never materialises a
  working tree, while an explicit workspace action can materialise a verified
  bootstrap basis.
* Receiver-aware V2 relay object transfer: independently zstd-compressed,
  resumable raw ranges with bounded concurrency and full canonical*byte and
  identity checks before an immutable publish or staged download. V2 sessions
  are relay*local temporary state, never history or source materialisation.
* Explicit multi-administrator authority, device enrolment and revocation,
  recovery packages, and local device custody through platform stores,
  SSH*agent keys, or PKCS#11 tokens.
* Read-only history views and optional external-LSP observations that stay
  advisory, ephemeral, and unable to write, merge, or resolve source.

## Usage

> [!NOTE]  
> For installation instructions, refer to [INSTALL.md](docs/INSTALL.md).

1. Optionally bind Yeokcham to its installed binary executable.

```console
$ YEOKCHAM="$PWD/_build/default/bin/yeokcham_v1.exe"
```

2. To get started, first run `init` inside a folder to create a new Yeokcham project.

3. A 24-word recovery mnemonic will be displayed exactly once, please record it offline before continuing.

```console
$ mkdir first-task && cd first-task
$ "$YEOKCHAM" init --username alice --draft first-task --title "first task"
$ printf 'hello\n' > note.txt
```

4. Next, run any of the below commands to interact with Yeokcham's functionality.

```console
$ "$YEOKCHAM" changes # reflects all repo changes
$ "$YEOKCHAM" save # creates a local scratch & explicit save checkpoint
$ "$YEOKCHAM" timeline # displays yeokcham graph of all edits and saves 
```

5. For a more detailed tutorial, run `yeokcham --help` or refer to [YEOKCHAM_GUIDE.md](./docs/YEOKCHAM_GUIDE.md).

## Other docs

General docs live here.

* [Installation and support](docs/INSTALL.md) for the supported source-build and platform paths
* [Yeokcham simple guide](docs/YEOKCHAM_GUIDE.md) for the shortest path from initialization to safe recovery and explicit sharing
* [Local recovery tutorial](docs/GETTING_STARTED.md) for an even shorter version of the simple guide
* [Concepts glossary](docs/CONCEPTS.md) for the higher-level ideas behind `Yeokcham`'s scratch, drafts, revisions, decisions, delivery, and custody.
* [Collaboration and relay guide](docs/COLLABORATION.md) for small teams planning to use `Yeokcham` for collaboration and sync
* [Troubleshooting](docs/TROUBLESHOOTING.md) for recovery and operational failures

## Nerd stuff

Nerd documentation lives here.

* [`FORMAL_MODEL.md`](docs/FORMAL_MODEL.md) for `Yeokcham`'s formal model and philosophical grounding
* [`ARCHITECTURE.md`](docs/ARCHITECTURE.md) for `Yeokcham`'s implementation structure and the engineering thinking behind it.
