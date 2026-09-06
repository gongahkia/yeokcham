[![](https://img.shields.io/badge/yeokcham_1.0.0-passing-green)](https://github.com/gongahkia/yeokcham/releases/tag/1.0.0)
[![](https://github.com/gongahkia/yeokcham/actions/workflows/ci.yml/badge.svg)](https://github.com/gongahkia/yeokcham/actions/workflows/ci.yml)
[![](https://github.com/gongahkia/yeokcham/actions/workflows/development-client-artifact.yml/badge.svg)](https://github.com/gongahkia/yeokcham/actions/workflows/development-client-artifact.yml)
[![](https://github.com/gongahkia/yeokcham/actions/workflows/relay-artifact.yml/badge.svg)](https://github.com/gongahkia/yeokcham/actions/workflows/relay-artifact.yml)

# `Yeokcham`

<div align="center">
  <img src="./asset/logo/yeokcham.png" width="25%" alt="Solomon logo">
  <p><strong>A model-first, local-first version-control system for small trusted teams.</strong></p>
</div>

## Rationale

[`Git`](https://github.com/git/git) is legendary for a [reason](https://github.com/torvalds).

In a bid to *(attempt to)* learn how to make a [VCS](https://deepsource.com/glossary/version-control-system), I tried to build `Yeokcham` on one simple premise - that the singular `git commit` overly simplifies the varied granular states *'informal submissions of work'* can take in real projects.

`Yeokcham` separates automatic scratch recovery, explicit shared changes, unresolved decisions, and delivery history and [***never blocks***](#reference) by being deliberately conservative.

## Features

I wanted `Yeokcham` to be as joyful as possible. It [currently](https://github.com/gongahkia/yeokcham/issues) has the below capabilities.

* Exact byte, mode, directory, and symlink snapshots, with saved checkpoints, pins, bounded retention, and journaled restore
* Exact comparison of the working tree against the active draft's latest checkpoint
* Explicit drafts, immutable shared revisions, unresolved decisions, and delivery milestones 
* Inspectable local storage collection
* Offline directory packages, signed relay publication and bootstrap with complete snapshot & closure verification
* Receiver-aware relay object transfer
* Explicit multi-administrator authority, device enrolment and revocation with first-class support for recovery packages and local device custody 
* Read-only history views *(and an optional LSP)*

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

5. For a more detailed tutorial, run `yeokcham --help` or refer to [GETTING_STARTED.md](./docs/GETTING_STARTED.md).

6. For the fastest path to getting started with Yeokcham, see [YEOKCHAM_GUIDE.md](./docs/YEOKCHAM_GUIDE.md).

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

## Reference

The creation of `Yeokcham` was heavily inspired by [this episode](https://youtu.be/a1LhEkCjERE?si=5eq2WN5h8TpfCfJ7) of [TheStandupPod](https://www.youtube.com/@TheStandupPod) where [Casey](https://github.com/cmuratori) covers the internal VCS tool his company uses.

<div align="center">
  <img width="750" alt="image" src="https://github.com/user-attachments/assets/66515367-31de-4acb-b58b-76a47c707460" />
</div>
