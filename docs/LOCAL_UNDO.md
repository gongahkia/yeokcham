# Persistent local undo tree

Yeokcham records complete saved working states and their continuations. Return
to an earlier state, edit again, and both continuations remain inspectable after
restart. This covers disk bytes, empty directories, symlink targets and the
regular/executable distinction. Unsaved editor buffers and edits between captures
are outside this history. Initialization, `save`, selected `share` and confirmed
integration record the relevant complete private states; foreground `watch` or an
explicitly started Linux runtime can also capture edits. Managed scheduling and
private backup are not configured by initialization. Shared acceptance remains
separate: undo/redo/restore select private alternatives without undoing an accepted
Core version. An incomplete integration blocks competing in-place navigation;
inspect its `operation show ID` before resuming the same confirmed operation.

## Inspect and select

```sh
yeokcham status
yeokcham diff                  # current saved state versus working files
yeokcham history               # 50 rows; --limit 1-200, --before SEQUENCE
yeokcham undo --preview
yeokcham undo --yes
yeokcham redo --preview
yeokcham redo --node 2 --yes
yeokcham restore 0 --preview
yeokcham restore 0 --yes
```

`history` reads saved metadata without scanning working files. It reports parent
and alternate child links, changed paths, recorded times and verified content
availability. A full history identity is `WORKSPACE_HEX:SEQUENCE`; short sequences
are conveniences within the current workspace. A snapshot ID identifies contents,
not a history position. Equal contents at different nodes keep distinct positions.
An unchanged save adds no node. `undo-tree` remains a simpler legacy view.

`undo` selects the parent. With unsaved disk edits, it preserves a new child first
and returns to the previously saved node. `redo` refuses unsaved edits; save or
undo them first. Multiple children require `--node ID`, even with `--yes`.
`undo --to ID` or `restore ID` selects an exact retained history position.
`restore current` selects the current saved state. Snapshot IDs also work; a
retained snapshot without known local ancestry creates a separate root. No
parent relationship is inferred from timestamps or matching contents.

Preview lists exact affected paths, modes and content identities, including
preservation of unsaved work. Use `diff STATE_A STATE_B` for readable text hunks
and explicit opaque/type/mode differences. States include `current`, `working`,
sequences, full history identities and snapshot IDs. Exact saved comparisons do
not scan working files or save history. Working comparisons and previews can
store unreferenced immutable scan objects; they do not move history or rewrite
ordinary files. A provisional preview node is not a durable ID reservation.

Selection prompts default to cancel on a terminal. Without `--yes`, a
noninteractive write returns exit 3 and actionable preview/application commands.
`--yes` authorizes fresh validation. For automation, take `plan_id` from
`--preview --format json` and supply `--plan ID --yes`; changed inputs return
exit 3 without applying a replacement plan. `--dry-run` remains a preview alias.
No-op selection needs no confirmation. JSON includes actual target identities,
changes, preservation effects, recovery operation IDs and next actions.

## Two continuations

```sh
printf 'A\n' > note.txt
yeokcham init
# Record the one-time recovery mnemonic offline.
printf 'B\n' > note.txt
yeokcham save
printf 'C\n' > note.txt
yeokcham save
yeokcham undo --yes           # B, node 1
printf 'D\n' > note.txt
yeokcham save                 # node 3, another child of node 1
yeokcham undo --yes           # B again
yeokcham history
yeokcham redo --node 2 --yes   # C
yeokcham restore 3 --yes      # D
```

The links are `0 -> 1 -> 2` and `1 -> 3`. Navigation preserves both continuations
while their contents are retained. Saving/navigation do not accept or publish
work. Workspace namespaces and monotonic node allocation are persisted with the
history/cursor in the existing atomic state root. Selection never resets the
counter. Whole-history encoding is retained; bounded pages/indexes remain G06.

## Named branches

```sh
yeokcham branch list
yeokcham branch create experiment
yeokcham switch experiment --preview
yeokcham switch experiment --yes
```

Initialization generates identities and captures existing files privately against
an empty accepted genesis. Creating a named branch forks the current accepted
version and captures current private work without changing selection. Switching
restores the selected branch's private history position and preserves the source
position and unsaved work. Selection survives restart. Duplicate names refuse
without retargeting; divergent names/heads require reconciliation. Shared branches,
drafts and local undo continuations are separate objects. These local commands do
not by themselves implement P3's shared exchange loop. Local shared integration
and private recovery are described in [Collaboration](COLLABORATION.md).

## Recovery and separate copies

```sh
yeokcham restore STATE --to NEW_OR_EMPTY_DIRECTORY --preview
yeokcham restore STATE --to NEW_OR_EMPTY_DIRECTORY --yes
yeokcham status
yeokcham restore --resume --operation OPERATION_ID --preview
yeokcham restore --resume --operation OPERATION_ID --yes
yeokcham restore proofs
```

`--checkpoint SNAPSHOT` and `--destination DIRECTORY` remain aliases. Copy-out
stages a complete verified directory and installs it into a new/empty destination
on the same filesystem. It does not change source history, cursor, counter or
branch selection, and can export a saved safety/target outside a source workspace
whose in-place operation is conflicted. This is an explicit copy, not private
backup. Occupied destinations and unsupported placements refuse before replacement.

In-place selection preflights all target contents and destination constraints.
Noncolliding ignored files remain; a replacement covering an ignored/untracked
obstruction refuses. Malformed rules, unsupported special files and unstable
captures retain the last complete saved state. Git ignore configuration is not
read. Missing or corrupt targets fail before replacement.

A recorded operation binds its exact history position, branch and physical plan.
`status` lists pending scopes and exact resume commands. Resume completes that
operation without taking another undo step or scanning a partial tree. Multiple
pending operations require `--operation`. A completed operation retry acknowledges
its previous completion without rewriting or claiming to reverify current files.
Keep the operation ID when acknowledgement is lost. Repeating a relative `undo`
after a completed acknowledgement is a new request; use explicit operation retry
when the original outcome is uncertain.

Application retains displaced original files/directories under
`.yeokcham/restore-staging/OPERATION_ID/`. Native identities and contents are checked
before continuing; unexpected external edits cause a conflict, retaining both
versions. A crash after materialization can finish metadata without replaying over
later edits. Equal-content cursor moves are journaled without rewriting files.
Destructive source selections retain safety and target snapshots through restore
proofs; metadata-only moves and copy-outs do not fabricate destructive proofs.

Do not delete journals or staging directories to clear conflicts. Preserve them
and the live files; copy a retained safety/target elsewhere for inspection.
Forgetting a proof or collecting immutable objects does not delete displaced
native files. Legacy partial journals without physical identity plans refuse
unexplained replacement. Source rollback alone cannot restore filesystem state.

The writer lock serializes Yeokcham processes, not external editors. Real process
interruption tests run on native Linux. No claim here covers power-loss behavior
on every filesystem or native macOS/Windows validation. Unsupported atomic
filesystem operations refuse explicitly.

Compaction preserves topology but can expire contents. `history` distinguishes
not retained from unavailable/corrupt contents and reports archive as unconfigured.
Pin needed snapshots; private branch positions, pending journals and destructive
restore proofs are retention roots. Local ancestry is not exported by existing
public package/relay operations. Existing V1 roots remain readable; a namespace is
bound on a saved mutation without inventing ancestry. Older clients may not read
new local wrappers/journals; preserve current data before changing versions.

## Pending shared-integration recovery

`operation show ID` distinguishes accepted commit from completed private
recovery. `operation recover ID --preview` proposes restoring pre-integration
private contents while retaining the currently observed tree separately.
`--keep-current` explicitly keeps that observation as private work, and `--replan`
creates another attempt without erasing previous observations. Confirm with
`--plan RECOVERY_PLAN_ID --yes`; ordinary preview/cancellation does not navigate
history or replace files. Recovery uses one distinct private history child and
does not publish the cancelled shared acceptance.

Inspect retained observation IDs through `diff`, or copy them out with
`restore SNAPSHOT --to NEW_DIRECTORY --yes`. A pending copy-out owns its contents
even if the integration's extra roots are subsequently released. Explicit
`operation forget ID --yes` releases a completed recovery's extra roots/proof;
ordinary history and live files remain. Historical operation metadata remains
inspectable after GC, with unavailable comparisons reported truthfully.

Resume preserves external edits after Materialized and pauses when unexpected
edits conflict with Applying. An already committed shared acceptance cannot be
cancelled through private recovery. Use private undo/restore instead; source
reversion does not unaccept work or restore user files. Native clone/exchange
and shared conflict resolution remain unfinished P3 work.
