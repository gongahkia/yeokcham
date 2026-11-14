# V1 product boundaries

Yeokcham is a local-first VCS for small trusted teams. Its CLI exposes four
distinct kinds of progress: local checkpoints, explicit shared revisions,
durable unresolved decisions, and delivery milestones. The
[formal model](FORMAL_MODEL.md) defines the transitions; this page describes
the implemented user workflow.

| Intention | Commands | Observable boundary |
| --- | --- | --- |
| Start independent work | `init` | Creates local custody, authority, and an initial checkpoint. Displays a new recovery mnemonic once; requires text output. |
| Observe edits | `status`, `diff`, `changes` | Actual changed paths, text/opaque/type/mode differences and capture state. Working comparisons may store unreferenced scan objects; no history publication. |
| Recover scratch work | `save`, `watch`, Linux `daemon` | Captures a checkpoint when the observed tree differs. Automatic capture requires a running watcher or daemon. |
| Inspect recorded work | `history`, `timeline`, `log`, `graph` | Reads local history without scanning the current tree or contacting a relay. |
| Navigate local work | `history`, `undo-tree`, `undo`, `redo`, `restore STATE` | Exact workspace/history identities and alternate continuations. Preview, default cancellation, `--yes`/`--plan` and recorded recovery. Ambiguous redo requires a selected child. |
| Recover exact files | `restore STATE --to DIRECTORY` | Verified separate copy into a new/empty same-filesystem destination; source history/branch unchanged. Destructive in-place selection retains a safety/target proof. |
| Select named branches | `branch list`, `branch create NAME`, `switch NAME` | Authenticated empty genesis/forks with durable private positions; no implicit acceptance/publication of private work. P3 shared exchange/integration remains separate. |
| Start another local task | `draft new` | Starts a local draft from the latest saved checkpoint; it does not switch or rewrite ordinary files. Save outstanding edits first if they belong to the old task. |
| Declare shared intent | `share`, `withdraw` | Creates signed immutable revisions or explicitly withdraws eligible work. Sharing captures the current tree, including directory-only changes. |
| Resolve ambiguity | `decision …`, `resolve` | Inspection and proposals are advisory; only explicit resolution changes the decision. |
| Record a milestone | `deliver` | Requires a decision-free projection and represented active shared work; records the current exact working snapshot and starts the next draft. |
| Receive history | `join`, `receive`, `sync`, `bootstrap` | Verifies public authority and immutable history. Receipt does not populate source files. |
| Populate a bootstrapped workspace | `workspace activate`, `workspace update` | Explicit materialisation from a verified imported basis. Dirty replacement requires `--replace` and a recovery proof. |
| Manage identities | `device …`, `authority …`, `recovery …` | Devices authenticate; usernames label. Divergent authority heads remain explicit until reconciliation. |
| Inspect or reclaim storage | `compact`, `storage roots`, `storage gc …` | Compaction removes checkpoint references. GC reviews and quarantines unreachable objects before explicit irreversible purge. |
| Diagnose damage | `verify`, `repair …` | Verification observes; repair requires a concrete plan, selected candidate, and matching approval digest. |

## Exactness and recovery

Snapshots preserve file bytes, empty directories, symlink target bytes, and
the distinction between regular and executable files. They do not preserve
arbitrary Unix permissions, directory modes, ownership, ACLs, extended
attributes, or timestamps. Snapshot identity is independent of semantic
analysis and editor events.

Root `.git` and Yeokcham metadata entries are always excluded. Root and nested
`.yeokchamignore` files support native globs, negation and ordered precedence;
Git ignore configuration is never consulted. `ignore explain PATH` reports the
winning file/line or mandatory exclusion. See [Native ignore rules](NATIVE_IGNORE.md).
Ignored live contents are outside new captures. Local selection preserves
noncolliding ignored files and refuses target collisions before replacement.
Use a separate recovery copy or explicitly move an obstruction.

Restore validates target trees, contents, and symlink targets before output.
Recorded operations resume their original targets; the whole workspace is not
a single atomic filesystem transaction. Staged exclusive moves/exchange retain
displaced nodes and check native identities and bytes before continuing.
Unexpected external edits cause a conflict; preserve the live tree and recovery
state. Later edits after Materialized are not replayed over during metadata
completion. See [Local undo](LOCAL_UNDO.md) for exact recovery commands.

Local undo nodes have identities independent of their snapshots. Their topology
and current position persist locally; receipt and public exchange do not carry
them. Compaction may expire node contents while preserving parent links. See
[Local undo tree](LOCAL_UNDO.md) for retention, restart, and client-format
compatibility.

## Human and machine interfaces

Use `yeokcham help COMMAND` for actual arguments. Text output is the primary
inspection interface. `--color auto|always|never` controls styling; JSON is
always free of styling. `verify`, `repair`, `hook list`, `undo-tree`, `undo`, and `redo` provide structured
results. Most other commands currently return only a versioned completion
envelope in JSON mode, so that mode is not a complete inspection API.

`init` and `recovery use` refuse JSON before mutation because they must display
a new one-time mnemonic. Local hooks run after eligible successful changes,
receive redacted event data, and report failures as warnings. Their execution
is bounded, including observers that ignore termination or never read stdin.

## Collaboration limits

The relay is an untrusted byte courier behind operator-managed HTTPS. It sees
payloads and does not provide end-to-end encryption. Authority is verified
locally; network ordering and availability cannot grant membership or choose
an authority head. Signing custody stays outside repository data.

Offline join plus receive supplies history inspection, not a populated
working tree. Workspace activation currently requires a relay bootstrap basis;
there is no generic clone, Git interchange, automatic merge, or GUI. The
[collaboration guide](COLLABORATION.md) describes the supported paths.

Delivery's `included` revisions are model bookkeeping. The current adapter
does not independently prove that every working-tree byte is the exact
composition of those revisions. Review the current files before delivery;
CI success and a delivery record do not establish that stronger property.

For the implementation-to-principle assessment and remaining product decisions,
see [Repository review](REPOSITORY_REVIEW.md).
