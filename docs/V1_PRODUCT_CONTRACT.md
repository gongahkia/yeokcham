# V1 product boundaries

Yeokcham is a local-first VCS for small trusted teams. Its CLI exposes four
distinct kinds of progress: local checkpoints, explicit shared revisions,
durable unresolved decisions, and delivery milestones. The
[formal model](FORMAL_MODEL.md) defines the transitions; this page describes
the implemented user workflow.

| Intention | Commands | Observable boundary |
| --- | --- | --- |
| Start independent work | `init` | Creates local custody, authority, and an initial checkpoint. Displays a new recovery mnemonic once; requires text output. |
| Observe edits | `status`, `changes` | Scans exact entries; may store unreferenced immutable objects. Does not save or publish history. |
| Recover scratch work | `save`, `watch`, Linux `daemon` | Captures a checkpoint when the observed tree differs. Automatic capture requires a running watcher or daemon. |
| Inspect recorded work | `timeline`, `log`, `graph` | Reads local history without scanning the current tree or contacting a relay. |
| Recover exact files | `restore` | Destination must already exist and be empty. In-place replacement retains safety and target snapshots in a durable proof. |
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

The root `.git` and `.yeokcham` entries are excluded. `.yeokchamignore` contains
literal relative paths, one per line, which exclude those entries and their
descendants. It has no glob or negation syntax. Ignored contents are outside
recovery history. In-place replacement refuses existing ignored entries so
they cannot be deleted without a safety copy. Use an empty destination or move
those entries outside the tree before retrying.

Restore validates target trees, contents, and symlink targets before output.
The journal supports retry after an interrupted in-place write; it is not an
atomic filesystem transaction. Coordinate with editors and other processes
before replacement: a checkpoint cannot protect writes made concurrently
after its scan.

## Human and machine interfaces

Use `yeokcham help COMMAND` for actual arguments. Text output is the primary
inspection interface. `--color auto|always|never` controls styling; JSON is
always free of styling. `verify`, `repair`, and `hook list` provide structured
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
