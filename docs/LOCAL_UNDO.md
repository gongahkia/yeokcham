# Persistent local undo tree

Yeokcham remembers how saved working states follow one another. Return to an
earlier state, edit again, and both continuations remain in local history.
The tree survives restarts while its repository metadata is retained.

Navigation covers the whole recorded project: bytes written to disk,
directories, executable state, and symlink targets. Unsaved editor buffers
and intermediate edits between captures are outside this history. Automatic
capture requires a running `watch` or Linux daemon.

## Browse and navigate

```sh
yeokcham undo-tree
yeokcham undo --dry-run
yeokcham undo
yeokcham redo --dry-run
yeokcham redo
```

`undo-tree` reads saved metadata without scanning files. Each row shows a local
node ID, its parent, checkpoint, and originating draft. The current node is
marked `*`. Node IDs identify positions in history; checkpoint IDs identify
exact contents. Editing back to identical contents creates another node.
Saving an unchanged tree creates neither a node nor a checkpoint.

`undo` moves to the parent. If working files contain unsaved disk edits, it
first preserves them as a new child, then returns to the previously saved
node. Redo can recover that new child. At a root, undo reports that no parent
was recorded.

`redo` moves to a child. When several children exist, it reports their IDs and
requires `--node ID`. Redo refuses unsaved disk edits; save or undo them first.
Use `undo --to ID` to navigate directly to any retained node.

Preview with `--dry-run` before replacing files. The preview lists exact
before/after path entries, modes, and content identities, using the same
comparison as `changes`. It is not a line-by-line text patch. Preview can
allocate immutable scan objects but never saves a node, advances the state
head, or writes ordinary files. Applying a later command scans again.

## Two continuations

Start inside a new directory, using an installed `yeokcham` executable or the
source-build command described in [Installation](INSTALL.md):

```sh
printf 'A\n' > note.txt
yeokcham init --username alice --draft experiment --title "Try two layouts"
# Record the one-time recovery mnemonic offline.
printf 'B\n' > note.txt
yeokcham save
printf 'C\n' > note.txt
yeokcham save
yeokcham undo                 # back to B, node 1
printf 'D\n' > note.txt
yeokcham save                 # node 3 is another child of node 1
yeokcham undo                 # back to B again
yeokcham undo-tree
yeokcham redo --node 2        # recover C
yeokcham undo --to 3          # revisit D
```

The parent links are `0 -> 1 -> 2` and `1 -> 3`. Returning to B did not discard
C. Navigation and saving create no shared revisions or deliveries. `draft new`
changes the active task without moving files or adding a node solely for the
task change. Navigation updates the latest checkpoint of the current active
draft; it does not reopen the draft named on a historical node.

## Recovery and retention

When navigation replaces files, it uses the restore journal and retains both
safety and target snapshots in a restore proof. The journal names the exact
target node, including when multiple nodes have identical contents. After
interruption, rerun `undo` or `redo` to finish the original navigation. The
retry does not take another step. Save and watcher capture refuse to record a
partially restored tree while a journal is pending.

Workspace mutations are serialized by a local process lock that the operating
system releases if its owner exits. Coordinate with editors and other programs
before replacement: the lock cannot prevent them from writing after a safety
scan. Existing ignore rules and in-place restore restrictions apply; see
[Troubleshooting](TROUBLESHOOTING.md).

Checkpoint compaction preserves tree topology but can expire snapshot contents.
A node without a retained checkpoint is marked `[compacted]` and cannot be
restored. Its parent links remain visible; undo never silently skips it. Pin
a checkpoint before compaction when you need its contents preserved. Recovery
proofs and journals also protect snapshots under the existing retention policy.

## Locality and existing repositories

Node IDs, parent links, timestamps, and the current position remain local.
Packages, relay publications, and bootstrap bases do not export them. Receiving
shared history does not create local editing ancestry. A fresh bootstrap starts
its own local tree.

Existing repositories start from one root at their current checkpoint. Older
deduplicated checkpoints cannot reconstruct ancestry. Restoring one without a
history node creates a separate root. Snapshot-based `restore` prefers the
closest matching ancestor, then the newest matching node; use `undo --to ID`
when the exact position matters.

The client reads existing V1 state records. The first saved mutation writes a
versioned local wrapper containing the existing project/collaboration record
and the undo tree under the same atomic state-head update. Older clients cannot
read this wrapper. Public project and signed revision encodings are unchanged.

All three commands support structured `--format json` results, including node
IDs, checkpoint availability, and navigation previews. Node IDs are strings in
JSON to preserve integer precision. Root timestamps use zero when the original
capture time is unavailable.
