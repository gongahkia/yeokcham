# Local recovery tutorial

This is a local, source-checkout evaluation of the V1 scratch/recovery path.
It does not contact a relay, create a team member, or exchange Git data. Build
the command first with [Installation and support](INSTALL.md). Use a private
terminal: `init` prints a real recovery mnemonic once.

The examples use a source-build command variable. If a future supported release
installs `yeokcham` on `PATH`, set `YEOKCHAM=yeokcham` instead.

```sh
YEOKCHAM="$PWD/_build/default/bin/yeokcham_v1.exe"
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

## Disposable container alternative

The [Docker tutorial](../containers/tutorial/USAGE.md) provides the same local
recovery journey with an isolated Linux signer. It includes a sample project
and an empty restore destination; no host compiler installation is required.

## Current P2 branch checkpoint

`init [PATH]` now generates workspace/branch identities and an initial draft ID;
`--username`, `--draft` and `--title` remain optional overrides. Existing files
are captured privately against authenticated empty accepted genesis. The
command reports automatic capture and private backup as unconfigured. Use
`save` or a running foreground `watch` for subsequent capture.

```sh
"$YEOKCHAM" branch list --root "$DEMO_ROOT/work"
"$YEOKCHAM" branch create experiment --root "$DEMO_ROOT/work"
"$YEOKCHAM" branch list --root "$DEMO_ROOT/work" --format json
"$YEOKCHAM" switch experiment --root "$DEMO_ROOT/work" --preview
"$YEOKCHAM" switch experiment --root "$DEMO_ROOT/work" --yes
```

Creation saves current private disk edits and creates a named shared branch
identity at the current accepted version. It keeps the current selection and
preserves both private positions in the existing history/state root. Names are
case-sensitive; duplicates refuse without retargeting. JSON includes actual
branch IDs, causal heads, workspace identity and local positions. This is a P2
checkpoint: `switch NAME` now selects that branch's private saved position and
preserves source disk edits before replacement. Noninteractive selection needs
`--yes`; `--preview` never moves files/history. Branch selection persists across
restart. Missing target contents or ignored obstructions refuse before
replacement; interrupted switches resume their exact original target. Full
shared exchange/integration is P3. Snapshot copy-out now uses staged whole-directory installation; remaining P2
work includes complete navigation confirmation/outcomes, ordinary restore syntax
and the final acceptance audit.
Existing V1 sharing/delivery commands retain their older record semantics; they
are not the future P3 native core exchange/integration loop.

## Inspect exact local work

The current P2 checkpoint also supports:

```sh
"$YEOKCHAM" status --root "$DEMO_ROOT/work"
"$YEOKCHAM" history --root "$DEMO_ROOT/work"
"$YEOKCHAM" diff --root "$DEMO_ROOT/work"
"$YEOKCHAM" diff 0 1 --root "$DEMO_ROOT/work" --format json
```

`diff` with no states compares saved work with current disk files. Numeric states
select positions within this workspace; history also prints full
`workspace:sequence` identities. Exact saved-state comparisons leave working
files and the history cursor alone. Text differences are readable within the
stated display bounds; opaque files retain type/mode/content identities.
History includes alternate continuations and availability, with 50 rows by
default. Follow `--before` to read another page. Missing contents and unretained
states are reported explicitly.

If rules or a special file prevent a complete observation, `status` still shows
saved metadata and reports capture incomplete with unknown unsaved state. It does
not report clean. The JSON domain result includes outcomes, real data and actions;
current result/error aliases remain supported. Watcher/service and private backup
state are distinct from a successful local save. P2's remaining application
work remains in progress.
