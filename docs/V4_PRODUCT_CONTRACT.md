# V4 product contract

## Status

Accepted for the V4 implementation track on 2026-08-27.  V4 is a new,
side-by-side repository format.  It does not reinterpret or mutate V1, V2, or
V3 repositories.

## Current milestone

The current milestone is the V4 functional core: exact local recovery,
explicit drafts and sharing, conservative composition, durable decisions, and
manual delivery. Completed slices are the in-memory model, the versioned
canonical model-state record with a compare-and-swap `v4-project-state` head,
command-triggered exact capture, the local four-fact CLI, in-place
journaled restore with a retained safety checkpoint, bounded checkpoint
retention with explicit pins, and Linux watcher capture that reuses command
`save`. The inotify quiet-window loop is implemented but was **not** executed
on the Darwin development host; run `dune exec test/test_v4_watch.exe` on
Linux (see [ADR-082](adr/082-v4-linux-command-capture.md)). The signed offline
collaboration slice is also implemented: the CLI creates a device through the
native signer provider, initialises a self-signed administrator certificate,
signs shared and resolution revisions, lets any current administrator enrol a
device, and imports a verified directory package without materialising it.
This is an offline package adapter, not a network transport or a complete
new-device join workflow.

The record slice owns these types: `state`, `checkpoint`, `draft`,
`shared_change`, `change_revision`, `edit`, `resolution`, `delivery`, and
`username_registration`. Its
invariants are one active draft, unique identities, linear immutable revision
chains, a resolution based on the current delivery baseline, retained unique
checkpoints, a one-to-one device-to-local-username registration, and canonical
field/list ordering. A delivery that includes a
resolution consumes the resolved shared changes and drops resolutions bound to
the previous baseline. It requires round-trip, noncanonical-byte,
malformed-state, and golden-byte tests. Project-state schema version 4 retains
the V1, V2, and V3 fixture decoders. Version 2 decodes as an empty pin list,
version 3 appends canonical pins, and older records decode as an empty local
username-registration list rather than manufacturing a label. Version 4
appends canonical username registrations. The local adapter adds a
`V4_project_state` object and one `v4-project-state` mutable head.  Initialization refuses a pre-existing
`.yeokcham` directory, so it cannot reinterpret or add V4 records to an
existing repository.  Saves write the immutable object before the head changes;
stale writers receive a compare-and-swap error.  Tests require first-write,
reopen, stale-writer, and corrupt/wrong-type failure coverage. ADR-079 remains
applicable; no new architecture decision is needed because this is the
already-approved persistent-adapter boundary.

Signed projects place a versioned collaboration wrapper around that canonical
V4 project record in the same `V4_project_state` object. The wrapper carries a
repository ID, canonical public certificate set, detached signed revision
records, and the local certificate ID; it carries no private key. Every
currently visible shared or resolution replacement revision has exactly one
verified signed record. Historical signed records may remain after the model no
longer displays their revisions. A bare save is refused when its expected head
is collaborative, so a caller cannot silently strip this wrapper. Existing
bare V1--V4 project records remain decodable. ADR-083 governs this extension.

The command-triggered capture adapter owns `init`, `save`, `status`, `user
register`, `draft new`, `share`, `withdraw`, `resolve`, `deliver`, `device`,
`package create`, and `receive`. It captures an
exact tree through the existing byte-correct scanner, maps the stored snapshot
identity into the V4 model, and does not write a new head when a save observes
an unchanged snapshot. `save` remains recovery-only: a later checkpoint becomes
a shared revision only when `share` is run again. Shared revisions record
`Whole_path` edits for paths that differ from the current delivery baseline and
are signed in a collaborative project. Linux `watch` calls the
same capture path after a one-second quiet period, with a thirty-second maximum
delay during sustained writes. macOS and WSL watchers are not implemented.

The inspectable CLI is `yeokcham-v4 init`, `save`, `status`, `device create`,
`device show`, `device enroll`, `user register`,
`timeline`, `restore`, `draft new`, `share`, `withdraw`, `resolve`, `decision show`,
`decision materialize`, `deliver`, `pin`,
`unpin`, `compact`, and `watch`.
`status` renders the four facts, lists shared-change, decision, and
delivery identities where they exist, lists local username registrations, and
reports `capture command` plus whether the tree has uncaptured edits. `decision
show` and `decision materialize` copy or list exact candidate snapshots without
rewriting the project directory. Candidate directories are generated direct
children such as `alice-001`, in canonical candidate order; a raw revision ID
is never used as a filesystem path. The output keeps the canonical author
device ID beside its optional local display username.
`resolve --tree PATH` uses that isolated tree as the resolution snapshot.
`compact` drops unnamed scratch
checkpoints under a count-based extra-keep policy; it does not delete object
bytes. `watch` is Linux-only. The command rejects unsupported V4
actions instead of routing them through V3 or Git behaviour. CLI journey tests
cover saved work, two drafts, sharing, overlap decisions, restore, withdrawal,
delivery, enrollment, and offline receive.

`timeline` lists retained saved checkpoints. `restore --checkpoint ID
--destination PATH` materializes one only into an existing empty directory.
`restore --checkpoint ID` restores in place only after capturing and durably
publishing the current tree as a retained safety checkpoint. The in-place path
appends canonical, immutable `Prepared`, `Applying`, `Materialized`, and
`Published` journal generations. Restart re-derives the target from its exact
snapshot and repeats replacement idempotently; `.yeokcham` and `.git` are
preserved. Tests cover prior-byte recovery, rejection of a non-empty
destination, safety recovery, metadata preservation, and interrupted-apply
resumption. Compaction drops unnamed timeline entries under
[ADR-081](adr/081-v4-bounded-checkpoint-retention.md) and prunes published
restore journals. Incomplete restore journals keep their safety and target
snapshots protected. Linux capture is governed by
[ADR-082](adr/082-v4-linux-command-capture.md).

The persistent in-place restore boundary is governed by
[ADR-080](adr/080-v4-in-place-restore-journal.md).

## Product promise

V4 presents four facts rather than a Git workflow:

1. **saved**: selected local work is recoverable without a commit.
2. **shared**: an explicitly selected draft is visible to the project.
3. **needs a decision**: incompatible alternatives are retained and named.
4. **delivered**: a conflict-free selection of shared work was deliberately
   recorded.  It does not claim that a build, test, review, or deployment passed.

The tool must never silently discard a selected file change, invent a semantic
merge, or overwrite active files because a remote change arrived.

## Audience and boundary

V4 serves a solo developer with multiple devices and trusted teams of two to
eight people.  Its first automatic-capture platform is Linux.  Normal daily use
is CLI-first; an editor integration may consume the same status and decision
interfaces later.

V4 is native-only.  `init` may seed a project from an ordinary directory, but
does not import Git history or synchronize with Git hosting.  `.git` and
`.yeokcham` are excluded from snapshots.

## User workflow

Every project has exactly one active draft.  It is created at project
initialisation.  `draft new <title>` closes it and begins another draft.  The
tool does not infer task boundaries.

`init --username NAME` creates a repository ID and a platform-custodied Ed25519
device, makes it the self-signed administrator, and registers the creator's
display name. `device create` provisions an additional platform-custodied
device and prints its opaque device ID and public key. An administrator uses
`device enroll --device ID --public-key HEX --username NAME` to issue its
certificate; `--administrator` delegates equivalent enrolment authority.
`device show` identifies the current repository's local certificate and role.
`user register --device DEVICE --username NAME` records or corrects one safe
display handle for another device. A username is a lowercase ASCII handle
of at most 32 characters (`[a-z0-9][a-z0-9_-]*`); registrations are unique by
both device and handle. This is readable local metadata, not a claimed person
identity, membership record, enrollment, or authorization decision. The
canonical device ID remains the author identity shown by decision inspection.

`share` publishes the complete active draft to the project.  Later checkpoints
amend that shared draft by publishing immutable signed revisions.  Closing or
delivering the shared draft freezes its latest revision.  A user who needs to
share two unrelated pieces of work must create separate drafts before sharing.

The materialized project directory is a projection, not a user-managed Git
worktree.  Incoming revisions with provably disjoint text edits compose.  Any
uncertain, structural, or binary overlap becomes a decision.  Active files stay
unchanged until the user resolves that decision in an isolated resolver view.

`deliver` selects explicit shared revisions from a decision-free projection and
records an immutable baseline.  It accepts no unresolved decision and never
claims validation evidence that was not supplied.

`package create --destination PATH` writes a versioned directory package of
the exact immutable snapshot closure needed by its signed revisions and public
certificate records. `receive --from PATH` first verifies package canonical
bytes, repository continuity from its current root, certificate causality,
revision signatures/parents, and every snapshot, tree, content, manifest, and
chunk reference in a temporary store. Only then does it add immutable objects
and advance the V4 state head. It neither scans, changes, nor resolves the live
tree. A freshly enrolled device still needs a future explicit join command
with independent root-fingerprint confirmation; receiving assumes an existing
V4 project with an established membership root.

## File and recovery contract

The Linux watcher requests a whole-tree scan after a one-second quiet period,
with a maximum delay of thirty seconds during sustained writes.  Users may set
`capture=command`; command mode captures before VCS mutations and when `save`
is run, and status warns about uncaptured filesystem edits.

Snapshots preserve regular file bytes, executable mode, directories, and raw
symlink target bytes.  `.yeokchamignore` is the only project ignore file and is
itself tracked.  Special files, ownership, ACLs, extended attributes, and
unsupported file sizes are explicit capture errors.  A failed scan, watcher
loss, or concurrent file mutation keeps the previous checkpoint current; it
never silently omits a path.

Automatic checkpoints compact under a documented bounded policy.  Snapshots
named by a shared revision, delivery, explicit pin, unresolved decision, or
restore-safety record are protected until explicitly removed.

## Composition contract

The composition engine is byte- and text-context-only.  It may combine
disjoint text ranges only when a deterministic three-way precondition proves
that the result is independent of application order.  It must create a
decision for same-range text changes, binary changes, add/add, delete/modify,
rename/modify, directory/file, symlink/file, mode changes, ambiguous contextual
application, and case-path collisions.

A decision stores the base, every candidate, author provenance, and affected
paths.  It does not modify active files or convert a conflict into a process
error.  A resolution is a new ordinary revision, not an overwrite of history.
Materialising candidates requires an existing empty destination and creates
only generated safe child names from the registered display handle plus a
rank. It never derives a child filesystem path from a revision identifier.

## Trust and transport contract

V4 device IDs are deterministically derived from Ed25519 public keys. The
repository begins with a self-signed administrator certificate; every later
certificate is signed by an earlier administrator. Any administrator may enrol
a member or administrator. A certificate and a signed revision bind the
repository ID and canonical payload, so they cannot be reassigned to another
repository, device, or revision. Shared revisions and resolution replacement
revisions are signed. Withdrawal, delivery, and local display registration are
ordinary V4 model transitions and are not represented as signed records.

Private signing bytes live outside V4 state and packages. macOS stores them in
Keychain and Linux uses Secret Service; the explicit test provider is enabled
only by `YEOKCHAM_V4_TEST_SIGNER_DIRECTORY`. No claims are made for hardware
keys, a signing agent, non-exportable signing, remote custody, revocation,
epochs, device recovery, or key rotation.

The only V4 exchange adapter is the verified local directory package described
above. There is no relay, LAN, SSH, HTTP, or managed transport; encryption of
transport or package contents is also not implemented. A future transport must
reuse this verification boundary rather than introduce another receive path.

## Explicit exclusions

V4 does not implement Git compatibility, branches, staging, rebase, sparse
trees, linked worktrees, submodules, file locks, semantic parsing, AI task
grouping, semantic merge, review/approval workflows, CI-backed delivery, or
macOS/WSL automatic capture.  Unsupported operations must fail clearly rather
than emulate part of another VCS model.

## Required types and invariants

The core defines `snapshot`, `checkpoint`, `draft`, `shared_change`,
`change_revision`, `projection`, `decision`, `delivery`, `username_registration`,
`device`, `certificate`, `membership`, `signed_revision`, and offline `package`
as distinct types. Stable identities are canonical and
versioned at the persistent adapter boundary.  A draft is never a delivery; a
delivery is never an implicit approval; a decision is never a failed process;
and semantic sidecars are never canonical source.

## Required verification

- unit and generated transition tests for draft lifecycle, sharing, withdrawal,
  composition, decisions, and delivery;
- exact snapshot/materialization and restore-failure tests;
- canonical persistent-format golden fixtures before a V4 record is written;
- duplicate-registration, generated-registration, legacy-record, and
  candidate-path-containment tests for local usernames and decision views;
- canonical certificate/revision round trips, signature tampering,
  unauthorized-enrollment, membership-continuity, duplicate-record, object
  closure, and working-tree-preservation tests for offline exchange;
- future join, removal, and key-rotation tests before those features are
  implemented;
- CLI journey tests for saved work, two drafts, sharing, conflict resolution,
  restore, withdrawal, delivery, enrollment, and receive.
