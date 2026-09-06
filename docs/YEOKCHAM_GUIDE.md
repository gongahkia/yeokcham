# `Yeokcham` (a simple guide)

A short guide to saving work, sharing it deliberately, and recovering exact files.

## Setup

Build the source checkout, then point `YEOKCHAM` at the resulting command:

```sh
make build
YEOKCHAM="$PWD/_build/default/bin/yeokcham_v1.exe"
"$YEOKCHAM" --version
```

## Create a new repository

Create an empty directory, open it, and initialise a V1 repository:

```sh
mkdir first-task && cd first-task
"$YEOKCHAM" init --username alice --draft first-task --title "first task"
```

`init` prints a recovery mnemonic once. Record it offline before continuing.

## Workflow

Your working tree and saved checkpoints are separate. Inspect a change, then save an exact local checkpoint:

```sh
printf 'hello\n' >note.txt
"$YEOKCHAM" changes
"$YEOKCHAM" save
"$YEOKCHAM" status
"$YEOKCHAM" timeline
```

`save` is local recovery, not shared intent. `changes` reports exact paths,
file modes, and content identities; it does not guess text edits or moves.

## Recover a checkpoint

Copy a checkpoint ID from `timeline`, then restore it into an empty destination:

```sh
"$YEOKCHAM" restore --checkpoint CHECKPOINT --destination ../recovered
```

The current working tree stays untouched. Omitting `--destination` performs an
explicit in-place restore with a durable safety proof.

## Share work

Sharing is a separate, explicit action. Choose the change and revision IDs,
then run:

```sh
"$YEOKCHAM" share --change CHANGE_ID --revision REVISION_ID
"$YEOKCHAM" log
"$YEOKCHAM" graph
```

Overlap or a stale base becomes a visible decision. Yeokcham does not merge or
resolve it automatically.

## Receive work

Packages and relay synchronization are receipt operations. They verify and
store history, but never populate ordinary source files. Use an explicit
`workspace activate` only after verified bootstrap when you intend to create a
working tree.

## Get help

List the supported surface or inspect one command:

```sh
"$YEOKCHAM" --help
"$YEOKCHAM" help restore
```

For the runnable recovery walkthrough, read
[GETTING_STARTED.md](GETTING_STARTED.md). For complete command and trust
boundaries, read [V1_PRODUCT_CONTRACT.md](V1_PRODUCT_CONTRACT.md).
