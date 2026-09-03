# Local recovery tutorial

This is a local, source-checkout evaluation of the V4 scratch/recovery path.
It does not contact a relay, create a team member, or exchange Git data. Build
the command first with [Installation and support](INSTALL.md). Use a private
terminal: `init` prints a real recovery mnemonic once.

The examples use a source-build command variable. If a future supported release
installs `yeokcham` on `PATH`, set `YEOKCHAM=yeokcham` instead.

```sh
YEOKCHAM=./_build/default/bin/yeokcham_v4.exe
"$YEOKCHAM" --version
"$YEOKCHAM" help changes
```

## 1. Create isolated work

```sh
DEMO_ROOT=$(mktemp -d)
mkdir "$DEMO_ROOT/work" "$DEMO_ROOT/recovered"
printf '%s\n' 'first note' >"$DEMO_ROOT/work/note.txt"
```

`DEMO_ROOT` is a new directory. Do not point this tutorial at existing work.

## 2. Initialise and record the recovery ceremony

```sh
"$YEOKCHAM" init --root "$DEMO_ROOT/work" \
  --username alice --draft first-task --title "first task"
```

The command prints status, a public 12-word root-verification phrase, a local
recovery-package path, and a unique 24-word recovery mnemonic. This guide does
not show, invent, or store a mnemonic. Record the mnemonic offline before
continuing; it is shown only in the ceremony. The root phrase is public but
must be independently compared with another device owner during `join`.

## 3. Inspect, save, and inspect again

```sh
printf '%s\n' 'second note' >>"$DEMO_ROOT/work/note.txt"
"$YEOKCHAM" changes --root "$DEMO_ROOT/work"
"$YEOKCHAM" save --root "$DEMO_ROOT/work"
"$YEOKCHAM" changes --root "$DEMO_ROOT/work"
"$YEOKCHAM" timeline --root "$DEMO_ROOT/work"
```

The first `changes` lists `note.txt` as an exact file-entry change from the
latest saved checkpoint. It describes a path, file mode, and content-object
identity rather than a text patch. The second reports no differences. `changes`
uses the same exact scan boundary as `status`: it can create immutable
unreferenced scan objects, but it does not create a checkpoint, change the
state head, alter source bytes, sign, share, resolve, deliver, import, or
contact a relay.

Copy the **first** checkpoint ID shown by `timeline` after `checkpoint`: saves
are listed newest first, so this is the snapshot containing both notes. It is
needed in the next command; call it `CHECKPOINT` below.

## 4. Prove recovery into a separate directory

Make an unsaved edit, then restore the named checkpoint into the empty
`recovered` directory:

```sh
printf '%s\n' 'unsaved line' >>"$DEMO_ROOT/work/note.txt"
"$YEOKCHAM" changes --root "$DEMO_ROOT/work"
"$YEOKCHAM" restore --root "$DEMO_ROOT/work" \
  --checkpoint CHECKPOINT --destination "$DEMO_ROOT/recovered"
printf '%s\n%s\n' 'first note' 'second note' >"$DEMO_ROOT/expected-note.txt"
cmp "$DEMO_ROOT/recovered/note.txt" "$DEMO_ROOT/expected-note.txt"
```

The destination restore does not rewrite `work`; it materialises only the
checkpoint you named into the empty directory. Inspect `work/note.txt` to see
that its unsaved line remains.

## 5. Learn the in-place boundary before using it

An in-place restore omits `--destination` and changes the working tree only
after its recovery journal is durable. It prints a restore-proof operation ID.
That proof retains both the pre-restore safety checkpoint and target checkpoint
until `restore forget --operation ID`:

```sh
"$YEOKCHAM" restore --root "$DEMO_ROOT/work" --checkpoint CHECKPOINT
"$YEOKCHAM" restore proofs --root "$DEMO_ROOT/work"
"$YEOKCHAM" storage roots --root "$DEMO_ROOT/work"
```

Do this only after checking the named checkpoint and working directory. The
[concepts glossary](CONCEPTS.md) explains why a checkpoint is not a shared
revision or delivery. For common failures, see [Troubleshooting](TROUBLESHOOTING.md).

When finished, remove the temporary demo directory yourself if it contains no
material you need to retain:

```sh
rm -rf "$DEMO_ROOT"
```

That final cleanup is outside Yeokcham and removes the demo's recovery package
as well as its files. Do not use it on an actual repository.

## Runnable fixture

[`examples/local-recovery-demo.sh`](../examples/local-recovery-demo.sh) performs
the same disposable-directory journey without embedding a mnemonic. It stops
after `init` so a person can record the real ceremony, then gives the exact
commands to continue. It is intentionally an instructional fixture rather than
a CI substitute: the native signer and recovery ceremony require a real local
custody environment.
