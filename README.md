# `Yeokcham`

<div align="center">
  <img src="./asset/logo/yeokcham.png" width="25%" alt="Solomon logo">
  <p><strong>A model-first, local-first version-control system for small trusted teams.</strong></p>
</div>

## Rationale

... Blah Blah to update

Yeokcham separates automatic scratch recovery, explicit shared changes,
unresolved decisions, and delivery history. It is deliberately conservative:
a filesystem event, conflict, device name, or CI result is never treated as
user intent.

## Features

`Yeokcham` was designed to be as joyful as possible. It [currently](https://github.com/gongahkia/yeokcham/issues) has the below capabilities.

* Exact byte, mode, directory, and symlink snapshots, with saved checkpoints,
  pins, bounded retention, and journaled restore.
* `changes`: a stable, exact comparison of the working tree against the active
  draft's latest checkpoint, without guessing textual intent.
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

After building the source checkout as described in the
[installation guide](docs/INSTALL.md), create an empty directory and start a
draft. `init` displays a 24-word recovery mnemonic exactly once; record it
offline before continuing.

```sh
YEOKCHAM="$PWD/_build/default/bin/yeokcham_v1.exe"

mkdir first-task && cd first-task
"$YEOKCHAM" init --username alice --draft first-task --title "first task"

printf 'hello\n' > note.txt
"$YEOKCHAM" changes
"$YEOKCHAM" save
"$YEOKCHAM" timeline
```

This creates local scratch and an explicit saved checkpoint; it does not share
anything. The [local recovery tutorial](docs/GETTING_STARTED.md) is the
supported first-run demo. It works in a temporary directory, inspects the
saved-versus-current state, and restores a checkpoint into a separate
destination before attempting in-place recovery.

Use `yeokcham --help`, `yeokcham help COMMAND`, and
`yeokcham COMMAND --help` to explore the implemented surface. `--version`
reports an unreleased V1 source build rather than implying a published release.

## Other docs

* [Installation and support](docs/INSTALL.md) — supported source-build and
  platform paths.
* [Yeokcham simple guide](docs/YEOKCHAM_GUIDE.md) — the shortest path from
  initialization to safe recovery and explicit sharing.
* [Local recovery tutorial](docs/GETTING_STARTED.md) — the runnable first-use
  demo.
* [Concepts glossary](docs/CONCEPTS.md) — scratch, drafts, revisions,
  decisions, delivery, and custody.
* [Collaboration and relay guide](docs/COLLABORATION.md) — packages, bootstrap,
  synchronization, and their trust model.
* [Troubleshooting](docs/TROUBLESHOOTING.md) — recovery and operational
  failures.

## Nerd stuff

For the nerds, `Yeokcham`'s formal model and implementation structure are stored here.

* [`FORMAL_MODEL.md`](docs/FORMAL_MODEL.md) 
* [`ARCHITECTURE.md`](docs/ARCHITECTURE.md)
