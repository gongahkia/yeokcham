# Yeokcham product design and discussion record

Status: design in progress. Updated November 6, 2026.

This document records agreed direction, proposed behavior, and unresolved
decisions before implementation is delegated. Approval of a product direction
does not settle every default or storage format. No implementation work or
agent delegation is started by this document.

This is the continuing design record. The dated discussion in
[Repository review](REPOSITORY_REVIEW.md#product-direction-discussion-november-6-2026)
preserves its earlier context. [V1 product boundaries](V1_PRODUCT_CONTRACT.md)
and [Local undo](LOCAL_UNDO.md) describe current behavior, not this future design.
The [technical contracts discussion](TECHNICAL_CONTRACTS.md) develops the record
model and component boundaries separately from these agreed product decisions.

## Product purpose

Yeokcham should preserve unfinished work and keep repository data available so
people can explore alternatives and continue working offline without repeatedly
managing snapshots, transfers, and recovery themselves. Continuous capture,
branching local history, native background synchronization, and efficient
storage should form one understandable VCS workflow. Repositories containing
many documents, media assets, datasets, and other non-source-code files are an
explicit target, not incidental test cases.

The CLI must make that workflow understandable to people without version-control
expertise. Effortless normal use and plain-language explanations of issues and
conflicts are core product requirements, including for nontechnical users.

Reimplementing familiar Git functions is acceptable when the resulting product
has a concrete advantage in usability, reliability, performance, or resource
cost. New terminology and a different internal architecture are insufficient.
No performance advantage over Git has been established yet. The product is not
restricted to a recovery utility; that earlier suggestion was not accepted.

## Decision register

| ID | Direction | Status |
| --- | --- | --- |
| D01 | Pursue a VCS with practical advantages over native Git; assess the complete workflow rather than novelty alone. | Agreed |
| D02 | Make persistent, project-wide history of unfinished work and alternate continuations central. | Agreed; initial local undo tree implemented |
| D03 | Provide managed background capture, private backup, and remote synchronization, with useful offline operation and retry after interruption. Publish to teammates explicitly. | Agreed; protocol and lifecycle details need design |
| D04 | Make continuous history affordable through efficient storage, transfer, and background work. Separate lossless compression from history expiration. | Agreed; policy in D13/D14, initial limits in D15 |
| D05 | Replace the separate mandatory delivery ceremony with explicit integration of shared work; no further delivery action afterward. | Agreed interaction; integration mechanics open |
| D06 | Preserve the distinction between work being available and being accepted into a shared version. Automatic transfer alone does not establish acceptance. | Agreed |
| D07 | Core recovery and synchronization should not require an AI agent or online inference service. | Agreed |
| D08 | Continue exploring complementary capabilities. Do not require proof of a recovery-only product before discussing the broader VCS. | Agreed |
| D09 | Download all shared history and branches for offline use by default; allow users to select a narrower scope. | Agreed; availability follows verified download |
| D10 | Do not require backward compatibility or migration for artifacts produced by older Yeokcham development versions. | Agreed; product is still in development with no existing users to support |
| D11 | Ship the managed background service on macOS and Linux first, with Windows following shortly afterward. | Agreed; user can test on all three platforms |
| D12 | Use Yeokcham remotes first. Design one-time carryovers from Git later. | Agreed; continuous Git interoperability is outside the initial scope |
| D13 | Automatically keep recent private history and pinned checkpoints locally and archive older private history remotely. Archived restoration requires connectivity. | Agreed default; configurable limits |
| D14 | Provide sensible built-in limits, account-wide defaults, and per-repository overrides for automatic history management. | Agreed; initial values approved in D15 |
| D15 | Start with a 30-day local-history preference, a 5 GiB private-history target per repository, and a 20 GiB aggregate target per account per device. | Agreed initial defaults; configurable, with protected-data rules below |
| D16 | Ship self-hosted Yeokcham servers first for native remotes, private backups, and account settings. | Agreed; no managed hosted service required for the first implementation |
| D17 | Recovery after losing all devices requires the user's recovery phrase; the server administrator cannot read or recover private history on the user's behalf. | Agreed; recovery material and protocol still need technical specification |
| D18 | Require integration preview and confirmation by default; users may disable confirmation after a warning. | Agreed; disabling confirmation does not bypass conflict or integrity checks |
| D19 | Benchmark ordinary source-code projects by size first, then larger monorepos, then large binary/asset repositories. | Agreed priority; fixture plan and measurement requirements are linked below |
| D20 | Support repositories with many nontraditional code files as a core goal, including exact storage, history, synchronization, and restoration of opaque file contents. | Agreed; no automatic format-aware merge capability is implied |
| D21 | Integrate already-available shared work offline using local verified state; synchronize and reconcile on reconnect. | Agreed; supports the intended effortless background workflow |
| D22 | Use `.yeokchamignore` as the native ignore mechanism; do not consult `.gitignore` during normal operation. Translate ignore rules during later one-time Git carryover. | Agreed; matcher and translation contracts need specification |
| D23 | Allow every trusted repository member to integrate shared work initially, subject to the repository's review policy and ordinary checks. | Agreed; membership administration remains separate |
| D24 | Provide a native PR-style review workflow as an optional collaboration capability. | Agreed; direct integration remains the ordinary default |
| D25 | Let repositories opt into required review approval before integration; optional/advisory reviews are the default. | Agreed; personal confirmation opt-out cannot bypass repository policy |
| D26 | Prioritize an exceptionally understandable, low-friction CLI, including issue and conflict explanations that nontechnical users can act on. | Agreed; applies from the start to every feature and implementation handoff |
| D27 | Require renewed approval after reviewed content or relevant context changes by default; allow an authorized repository-policy opt-out with a warning. Keep this independent of D18's personal confirmation opt-out. | Agreed; required reviews remain opt-in, historical approval scope stays exact, and conflict/integrity checks always apply |

## Discussion minutes

These summarize the conversation by topic because numbered feature lists were
reused across replies. They are decisions and rationale, not a verbatim transcript.

### Earlier feature discussion

- Persistent local undo tree: accepted, subsequently authorized and implemented.
  Local checkpoints alone were not a branching undo history.
- Operation grouping: potentially useful supporting behavior, not a separate
  headline capability or an agreed additional user ceremony.
- Selective undo: design first; no implementation commitment. Ordinary reversal
  already overlaps with Git revert. A useful proposal must address unfinished,
  interleaved work and preserve later work without pretending to infer arbitrary
  semantic dependencies. AI is not a prerequisite for a constrained design.
- A separate feature for alternative implementations: deferred. The local undo
  tree already retains alternate continuations; additional product scope was
  not accepted merely to make Yeokcham seem different.
- Implementation was explicitly paused during discussion, then separately
  authorized for the undo tree. README changes were restricted to the smallest
  accuracy corrections. That documentation constraint remains in force.

### The six-point Git comparison and follow-up

1. **Familiar VCS operations:** the concern was accepted. Replication needs a
   practical advantage. Background synchronization and efficiency became core
   directions; simply renaming Git concepts does not answer the concern.
2. **Unfinished work:** continuous local history and revisiting discarded
   experiments match the intended value proposition.
3. **Collaboration and delivery:** the separate delivery surface appears to add
   friction. Simplify it while preserving meaningful availability/acceptance
   semantics; do not defend a command solely because the model contains it.
4. **Overlap with other tools:** Jujutsu and editor local history are relevant
   comparisons. Existing overlap does not cancel the accepted capabilities,
   but prevents claiming that basic autosave or undo is unprecedented.
5. **Justification for an alternative:** a coherent, measurably useful workflow
   can justify a tool without a wholly new version-control primitive.
6. **Scope and next steps:** the suggested narrowing to a recovery-only product
   was not accepted. Record the core direction and continue design and ideation
   before commissioning further implementation.

The subsequent article discussion reinforced the combined workflow, truthful
offline availability, storage efficiency, delivery simplification, and further
exploration. Candidate ideas below remain candidates; agreement to discuss
them does not set their priority or authorize implementation.

### Design questions answered on November 6

- Q01: the user asked which synchronization policy best fits effortless, quick,
  useful source control. The recommendation was private automatic backup of
  unfinished history with explicit publication to teammates. The subsequent
  agreement to automatic private archiving establishes this as the default
  design direction; the owner/access protocol remains to be designed.
- Q02: all shared history and branches by default, once downloaded; users may
  choose specific branches/work instead. Recorded as D09.
- Q03: explicitly integrate shared work into the accepted version, with no
  further delivery action. Recorded in D05/D06. The technical replacement for
  the current delivery transition remains Q08.
- Second question round: the response to Q04 addressed obsolete development
  formats rather than retention of everyday editing history. Backward
  compatibility and migration for older Yeokcham artifacts are unnecessary
  (D10). That answer did not decide how long to retain checkpoints created during
  normal use, so Q04 was rephrased with a three-month-old experiment as the example.
- Q05: macOS and Linux first, Windows close second. The user has access to all
  three operating systems for testing. Recorded as D11.
- Q06: Yeokcham remotes first; later support one-time carryovers, with a separate
  design discussion about porting. Recorded as D12, not a commitment to ongoing
  bidirectional Git synchronization.
- Retention clarification: the user agreed to recent history and pins remaining
  local, with older private history archived remotely. This should run
  automatically by default with sensible limits, configurable per account and
  per repository. Recorded as D13/D14. This does not authorize team publication
  of scratch history or silently reducing shared-history offline coverage.
- Initial limits and hosting: the user accepted the proposed limits of 30 days,
  5 GiB per repository, and 20 GiB per account per device, and selected
  self-hosting first. Recorded as D15/D16. These are initial product defaults,
  not measured performance guarantees.
- Final product-question round: recovery requires the owner's phrase rather
  than administrator recovery (D17). Integration must preview and confirm by
  default, contrary to the earlier suggestion to apply compatible changes
  immediately; users may turn confirmation off with a warning (D18).
- Performance scope: source-code projects are the default benchmarks, organized
  by source size and other scaling dimensions; larger monorepos and then large
  binary assets follow (D19). Supporting many nontraditional code files is an
  explicit product goal (D20), not a reason to exclude them from correctness or
  performance validation.
- Workflow audit answers: offline integration is required as part of the
  unobtrusive workflow (D21). The user rejected runtime `.gitignore` inheritance
  in favor of a native `.yeokchamignore`, with rule translation in the later
  Git carryover script (D22). Every trusted member may integrate (D23), and a
  native PR-style review capability is also wanted (D24).
- Review policy follow-up: reviews are optional by default, but repositories
  can require approval before integration (D25). Additional review-policy
  complexity that materially adds friction should be discussed before expanding
  the feature, rather than inferred from the request for PR-style reviews.
- Integration contract follow-up: the user accepted all six TC02 behavior
  points. Asked which safeguard should be configurable, they explicitly chose
  both preview confirmation and renewed approval after relevant changes, each
  enabled by default with a warning on disablement (D18/D27). Repository review
  policy remains separate from personal confirmation preferences.
- CLI priority: the user emphasized effortless commands and issue/conflict
  messages that anyone, including a nontechnical person, can understand (D26).
  This shapes every feature's interaction and error data from the start.

## Proposed user flow

This is a design outline. Command names and protocol details are still being
refined; policy and initial capacity defaults are recorded above.

1. Register a workspace and configure its remote and background behavior once.
2. Edit normally. Capture records changed disk states and their local ancestry,
   honoring `.yeokchamignore` without consulting Git ignore configuration.
3. While online, the service receives and verifies remote work, backs up private
   history, and transfers work explicitly published to the team. Transfers resume
   after loss of connectivity. Older private history is archived automatically
   according to the effective account/repository policy.
4. Inspect what is available locally, how current it is, and what is still
   transferring. Select another available version or revisit a local experiment
   without first planning commits or losing the previous continuation.
5. Continue local capture, inspection, comparison, restoration, and integration
   offline for the available data and locally verifiable policy/approval records.
   Queue eligible outgoing work for reconnection; reconcile concurrent advances
   without silently replacing a previously confirmed result.
6. Explicitly request integration of chosen shared work, inspect the proposed
   result, and confirm it. Preview confirmation is the default and can be
   disabled with a warning. There is no additional delivery action afterward.
   Receiving data does not itself overwrite the workspace or establish acceptance.

Any trusted member can follow this direct path by default. A review request can
be used before integration, and a repository may explicitly require approval.
The [review workflow](REVIEW_WORKFLOW_DESIGN.md) specifies that optional path and
the boundary between team policy and personal preview preferences.

## Capability design and acceptance criteria

### Understandable and effortless CLI: D26

The [CLI design](CLI_DESIGN.md) defines the interaction requirements and draft
message examples. Every operation should explain its outcome using the user's
files and work: what happened, what changed or remains safe, what needs attention,
and the next useful action. Technical identities and diagnostics remain available
without making knowledge of internal records a prerequisite for ordinary use.

Keep routine capture and retries automatic, make help and next actions easy to
discover, and distinguish saved locally, privately backed up, shared, and accepted
work. Conflict handling must identify the versions and affected files, preserve
available work, and offer clear choices or a way to decide later. Do not claim
that data is saved or that files are unchanged unless the operation can prove it.

Treat CLI comprehension and minimal interaction as acceptance criteria in every
work package. Package F validates the overall experience; it is not permission
to defer usable commands and errors until the end. Specific command names and
message wording remain design work, with representative journeys evaluated by
people unfamiliar with version-control terminology.

### Local history: D02

Keep exact snapshot identity separate from positions in editing history. The
same contents can occur at different nodes. Undo followed by new editing keeps
the earlier continuation available while its contents are retained.

Build on the current tree rather than adding another competing history model.
Improve finding the intended state and understanding a restoration. Persistent
ancestry, restartable restoration, and truthful retention status are part of
the useful experience. Capture covers disk contents under the existing ignore
and filesystem-fidelity rules, not every intermediate edit or unsaved buffer.

Acceptance examples:

- Capture A, B, C; return to B; capture D; restart; recover both C and D.
- Preview a restoration and preserve current dirty disk work before replacement.
- An interrupted restoration resumes its original target without taking another
  undo step or capturing a half-restored workspace as an ordinary edit.
- Expired content is visibly unavailable; navigation does not invent ancestry
  or silently substitute a different state.

### Native ignore rules: D22

Normal capture uses `.yeokchamignore`, not `.gitignore`, Git's global ignore
configuration, or a Git executable. Keep mandatory internal-metadata exclusions
separate from user rules. Ignoring is based on explicit path rules, not blanket
assumptions that documents, media, archives, or binaries are unwanted.

The existing `.yeokchamignore` accepts literal relative paths only. Specify the
native pattern syntax, ordering, directory scope, and re-inclusion semantics
before extending it into the intended `.gitignore`-style facility. Show which
rule excluded a path so users can understand and adjust capture coverage.
Changing ignore rules must not silently delete earlier recorded history or
erase excluded working files during restoration.

The later one-time Git carryover must translate the source repository's ignore
configuration into native rules and verify the resulting capture scope. Simply
renaming a file is insufficient when semantics differ. Address nested rules,
negation/precedence, and Git-tracked files that match ignore patterns; report
unsupported cases rather than silently changing which work is preserved. D12's
native-remotes-first order remains unchanged; no migration script is implemented
or moved into the initial runtime scope by this discussion.

Acceptance scenarios cover native rules taking effect, `.gitignore` alone not
changing capture behavior, clear exclusion explanations, and preservation of
existing captured history and ignored live files after a rule change. The
future migrator needs separate equivalence and unsupported-case tests.

### Background sync and offline availability: D03

The service must have a managed lifetime, observable status, and durable progress
across disconnection and restart. Network failure must not block local history.
Retries must not duplicate accepted publications or corrupt local state. Use the
existing verification and authority boundaries; background execution is not a
reason to relax them.

An offline claim refers to actual verified local content for a stated scope and
last successful synchronization. A list of remote revisions alone is not enough.
Required objects, including any compression bases, must be present before that
scope is called available. New remote work created while disconnected cannot be
included in that claim. Download all shared history and branches by default;
allow an explicitly selected narrower scope. Retain that scope as repository
configuration and report its completeness. Reducing coverage cannot be an
undisclosed response to disk pressure. D13/D14 govern private-history storage;
they do not turn all shared history into an evictable cache.

Private backup, team publication, and workspace integration need separate
semantics even if transfers use one service. The current shared relay/package
path is not a private backup channel, and local undo ancestry is not exported.
The private backup design must define audience, access, key handling, retention,
and restore behavior before implementation; see Q09.

Default policy: record each capture locally without waiting for the network;
upload private history asynchronously; require an intentional publication
action before teammates can access it. Receiving team work also happens
automatically. This avoids both a manual backup chore and accidental publication
of experiments.
Private backup needs a separate owner/device access model and a client-side
encryption/recovery design; an ordinary shared relay upload does not provide it.

#### Private access and recovery: D17

Only the owner's enrolled devices and recovery capability can decrypt private
history. Losing all enrolled devices requires the recovery phrase to regain
access to the archived history. There is no administrator escrow or account-reset
path that grants a server operator decryption capability. A server administrator
may manage service access and storage, but that authority does not establish
ownership of a private archive or replace the missing recovery secret.

Onboarding must clearly provide the recovery material and explain that losing
both it and all usable devices leaves private history unrecoverable. Recovery
also requires the archive data still to exist; a phrase cannot reconstruct
deleted remote contents. The phrase and unwrapped private keys must not enter
team packages, logs, ordinary configuration, or server-readable records.

The current project-authority recovery mechanism does not by itself specify
private archive recovery. Q09 must define the account/key relationship, device
enrollment and revocation, authenticated encrypted archive/index formats, and
recovery of the keys needed for retained history. Use established cryptographic
constructions and libraries; this document does not select a new primitive or
assume that an identity-recovery seed may simply be reused for encryption.

Acceptance scenarios must include recovery on a fresh device after loss of every
old device, exact restoration of private snapshots and their undo ancestry,
rejection of an incorrect recovery phrase, and inability of server credentials
alone to decrypt a private archive or enroll a decryption-capable device.

Acceptance examples:

- Disconnect during transfer, edit locally, restart, reconnect, and complete
  synchronization without manual repair or lost local work.
- After availability is confirmed, disconnect and inspect, compare, and select
  an unvisited version within the promised scope without a network request.
- Report incomplete synchronization and unavailable content accurately.
- Receiving incoming changes preserves dirty working files and local ancestry.
- Capturing a private experiment does not make it team-visible unless the
  selected policy explicitly includes that behavior.

### Automatic private-history management: D13 and D14

Once a private backup destination is configured, backup, archiving, and eligible
local cleanup run in the background by default. Users can override the policy
per account or per repository, including keeping older history offline. A
workspace without a configured or reachable backup destination continues local
capture but cannot discard its only copy under an archiving policy.

An old private checkpoint may leave local storage only after the archive records
its exact contents and the history needed to find and restore it. A queued upload
is not a completed backup. The implementation must establish and persist archive
completion before making the checkpoint eligible for local cleanup. Protocol
details, owner recovery, and the remote storage contract remain Q09.

Protect the current working state, pinned checkpoints, pending uploads, and
active restoration/recovery roots. Preserve the local history index and branch
topology so archived experiments remain discoverable. Removing a local object
also requires checking that it is not needed by another retained checkpoint or
by promised shared-history coverage. Compression/delta dependencies count too.

History inspection distinguishes locally available, awaiting backup, archived
remotely, and unavailable content. Selecting an archived state retrieves and
verifies the required objects before replacing any working files. A failed or
offline retrieval leaves the current files unchanged and explains the limitation.
Archiving does not itself expire the remote copy or remove the history node.

#### Configuration and initial limits

Resolve ordinary settings in this order: built-in default, account default,
then an explicit per-repository override. Show the effective value and its
source, and allow resetting an override to inheritance. These are personal
settings; editing a repository's files does not grant collaborators control of
another user's private-history retention.

Account-wide capacity limits constrain the combined use of repositories; a
repository override cannot bypass that aggregate limit. Local capacity is
enforced on each device's disk, not pooled across different machines. Remote
quotas also remain authoritative. The account/profile and multi-device settings
representation is part of Q09; the existing display username is not an account
identity.

The following initial defaults are approved. Measurements should evaluate their
practical behavior; they are capacity preferences and targets, not benchmarked
performance guarantees. Keep the accepted defaults unless a later design
decision changes them; users can override them through configuration.

| Setting | Initial default | Meaning |
| --- | --- | --- |
| Recent private history | 30 days | Prefer keeping these captures local while within capacity. |
| Private-history local capacity per repository | 5 GiB | Target for stored private history, including its metadata; not a cap on the working tree or all shared history. |
| Combined private-history local capacity per account per device | 20 GiB | Prevent many repositories from each silently consuming a full independent allocation. |
| Pinned/current/pending/recovery data | Protected | May prevent meeting a capacity target; report this instead of discarding it. |
| Remote archive expiry | Off unless configured | Local archiving alone does not authorize irreversible deletion of archived experiments. Remote quotas still apply. |

The recent window is a preference within the capacity targets, not a promise to
fit arbitrarily large captures into them. When capacity is tight, archive and
evict the oldest eligible, verified-backed-up private captures first, even if
they fall within the preferred window. Show the resulting actual offline
coverage. Users needing a guaranteed older state offline can pin it. Storage
accounting must expose physical usage and avoid double-counting shared objects
in the aggregate budget; the detailed attribution rule needs implementation
design.

If protected data prevents reaching the target, report the overage and available
actions. If a remote quota prevents backup, keep pending data local and surface
the backup backlog; do not silently delete it to satisfy a local target. A
physical disk-full condition must report capture failure rather than claim the
edit was saved. Shared-history prefetch may pause under pressure, with coverage
reported as incomplete, but existing promised coverage is not silently removed.

Settings apply automatically after an override or account-default change. A
smaller local budget only evicts eligible backed-up data. Permanent remote
expiry is a separate, explicit retention setting; its interaction with pins,
devices, quotas, and advertised availability must be defined before enabling it.
No remote capacity or indefinite storage guarantee is implied by expiry being off.

Acceptance examples:

- A new configured repository inherits automatic policy without a separate
  cleanup command. A repository override survives account-default changes;
  clearing it resumes inheritance.
- An old experiment remains visible after local eviction and restores exactly
  from the remote when online; restoring it offline fails before file writes.
- Lost connectivity, a full remote, or an incomplete upload never makes a sole
  local copy eligible for automatic eviction.
- Pins, current state, pending uploads, and active recovery roots remain
  protected under age limits, capacity pressure, and policy changes.
- Changing one repository's private-history policy does not evict another
  repository's protected data or silently narrow shared-history coverage.

### Storage and background performance: D04

Design efficiency across content, history metadata, transfer, and maintenance.
Compression alone does not make an unlimited amount of distinct data fit a
fixed disk budget. Recovery retention and offline cache coverage must be chosen
together; expiry must not masquerade as lossless compression.

Current evidence and evaluation targets:

| Area | Current implementation | Design work |
| --- | --- | --- |
| Content reuse | Content-addressed objects and Buzhash content-defined chunks | Measure reuse for source edits and binary assets, including small changing files. |
| Local representation | Canonical envelopes stored without compression | Evaluate compression at rest and packing small objects while preserving canonical identities and verification. |
| Similar versions | Changed content can produce new chunks | Compare optional delta encoding against compression alone, including restore latency and dependency depth. |
| Capture | Watcher delegates to a full-tree save scan | Evaluate incremental capture with reconciliation after lost events; retain exactness. |
| Undo metadata | State saves encode the complete undo history | Evaluate incremental persistence and indexes so a small capture does not require rewriting ever-growing history. |
| Transfer | V2 supports compressed ranges | Measure missing-object detection, retries, batching, and redundant transfer. |
| Retention | Explicit compaction, pins, recovery roots, and GC | Define predictable policy for local history, remote coverage, pending uploads, and disk pressure. |

Do not expire the only copy of pending outgoing work or silently evict data
advertised as available offline. Repacking must preserve all retained recovery
paths. Development formats may change without legacy readers or migration
tooling (D10). Crash recovery, interrupted maintenance, and integrity within
the chosen format remain required; they protect ordinary current-version use.

Measure capture latency, idle and active CPU, memory, disk allocation, bytes
read/written, transfer volume, and restore latency. Follow D19's order: ordinary
source-code projects by size, larger monorepos, then large binary/asset workloads.
Vary file count, individual file sizes, content mix, history depth, and edit
patterns independently. Include cold/warm caches, disconnections, and maintenance.
The [benchmark design](BENCHMARK_DESIGN.md) specifies the initial workload matrix
and reporting requirements. Compare equivalent retained history and availability
when evaluating Git. Absolute latency targets follow baseline measurements;
no speedup or maximum supported repository size has been established yet.

### Non-source-code files: D20

Core capture, history, storage, transfer, and restoration operate on file contents
without requiring source-code syntax, a recognized extension, valid text, or an
AI service. Test mixed projects containing documents, images, audio/video,
archives, datasets, and other opaque bytes, including many such files rather
than only one large asset. Preserve the documented filesystem fidelity and
ignore behavior; this goal does not silently expand the supported metadata scope.

Exact preservation and useful history are required even when no semantic diff
or merge exists for a format. An integration preview can show opaque file
additions, removals, replacements, and sizes/content identities without rendering
a textual patch. Concurrent incompatible changes to opaque content must remain
explicit choices, with both candidates recoverable; do not concatenate arbitrary
bytes or silently choose one side. Format-specific visualizations or merge
adapters remain future design options, not requirements inferred from D20.

### Sharing and acceptance: D05 and D06

The user-visible distinction is between making work available for collaboration
and choosing the shared accepted version. A team can inspect an experiment
without adopting it. The ordinary workflow should express that distinction
without forcing another delivery ceremony afterward. The selected interaction
is explicit integration of shared work, not automatic acceptance on transfer.

Every trusted member may integrate by default (D23). Native review requests are
available but optional (D24). When a repository enables required approval (D25),
integration additionally verifies review evidence against the effective repository
policy and exact reviewed work. D27 requires renewed approval after relevant
changes by default and permits an authorized, warned repository-policy opt-out;
that opt-out never makes an earlier approval describe unreviewed new contents.
This policy does not make server administrators owners of private history or
grant ordinary members authority to change membership policy.

#### Offline integration and reconnection: D21

An explicit integration can be previewed, confirmed, and recorded locally while
offline when all needed contents, authority, policy, and any required approvals
are already available. It must not require a live server solely to compute or
record the local result. Clearly distinguish locally accepted work awaiting
synchronization from a shared state observed after synchronization.

On reconnect, receive and verify concurrent changes before reconciling shared
history. Preserve both local and remote results; upload order is not a reason to
discard one. If reconciliation produces a different integration result, use the
ordinary preview/confirmation policy for that new plan. Prior confirmation must
not silently authorize new contents. Conflicts, stale policy, or missing required
approval remain explicit, while local editing and history continue to work.

When required review is enabled, offline integration needs the relevant signed
approval records locally. Without them a member can still edit, capture, prepare
a review request, and inspect a plan; they cannot claim approved integration.
The precise concurrent-history and authority-admission rules remain part of Q08.

Acceptance scenarios include two disconnected members integrating independent
work, reconnecting in either order, retaining both histories, and inspecting any
new reconciliation plan. Also cover conflicts, approval-gated offline work, and
rejection of a stale confirmation without loss of unfinished work.

#### Preview and confirmation: D18

The default integration action builds a plan, displays its result and conflicts,
and waits for confirmation before changing the accepted version or ordinary
working files. The preview identifies the selected shared revisions, starting
baseline, proposed accepted snapshot, and effects on the current workspace.
It must distinguish text changes from opaque file replacements. Unrelated
unfinished local work stays recoverable and is not silently included as shared
accepted work. Computing a plan may stage immutable objects, but does not
publish acceptance or advance the baseline.

Bind confirmation to the previewed plan and its input states. Revalidate them
before applying; if the workspace, baseline, selected revisions, or resolution
inputs changed, regenerate the preview and obtain a fresh confirmation. An old
confirmation cannot authorize a different result. This does not by itself make
multi-file replacement atomic against external programs; preserve the restore
preflight/journal guarantees and define concurrent-write handling in Q08.

Users can disable preview confirmation through personal account defaults or a
repository override. Warn when disabling it, including the affected scope:
future explicit integration requests will apply without a confirmation pause.
An explicit per-invocation bypass may serve automation with the same warning;
exact command syntax remains to be specified. A shared repository file must not
silently disable another user's confirmation preference.

Opting out of confirmation still requires an explicit integration request and
does not bypass unresolved conflicts, stale-input checks, verification, or
preservation of current work. It never grants the daemon permission to accept
incoming changes automatically. With confirmation enabled, a noninteractive
invocation must not assume consent: return the preview and an actionable
confirmation-required result until an explicit bypass is supplied.
No confirmation bypass grants an exception to required repository review.

Acceptance scenarios include a compatible change that waits for confirmation,
cancelled preview with no accepted/worktree mutation, warned opt-out and opt-in
again, conflicts that still block with confirmation disabled, and stale previews
that cannot be applied using a prior confirmation. Text and opaque-file changes
must follow the same acceptance boundary.

Current `deliver` advances the baseline, consumes represented changes, clears
resolutions, closes the active draft, and creates the next draft. Its replacement
must account for each responsibility and concurrent baseline updates. Deleting
the command or renaming it is insufficient. Q03 has settled the interaction;
Q08 still covers integration/provenance semantics and the new representation of
accepted versions. Migrating obsolete development delivery records is not
required (D10). A future command name has not been chosen.

Acceptance criteria must cover publication without unintended acceptance,
preservation of unfinished work, explicit handling of conflicting concurrent
changes, and an exact accepted snapshot. The current adapter does not prove that
every snapshot byte is the composition of the listed revisions; the new design
must state which stronger guarantees it does or does not introduce.

## Implementation boundaries

### Development formats: D10

The product assumption is that Yeokcham is still in development with no existing
users whose old repository formats must be supported. Future work may replace
development schemas, remove obsolete compatibility paths, and regenerate test
fixtures instead of building migration adapters. There is no requirement to
read scratch history or other artifacts created by older software versions.

This is separate from retaining a person's earlier edits within the current
format. D10 does not authorize automatically deleting working files or turning
routine crashes, maintenance, or retention into data loss. An unsupported format
should be reported clearly rather than silently reinitialized. The live product
contract remains unchanged until the relevant implementation lands.

### Platform sequence: D11

macOS and Linux are the first managed-service targets; Windows is a close second,
not an indefinitely deferred platform. Keep watcher, service lifetime, and
credential handling behind platform boundaries so Windows support can follow
without redesigning the core capture, storage, and synchronization semantics.
The user can validate behavior on all three operating systems.

Platform order is settled. Service startup, pause/resume, and credential UX still
need concrete design, but do not require reopening the operating-system choice.

### Native remotes and later carryovers: D12

The first implementation uses Yeokcham remotes. Git import/export or continuous
Git synchronization is not a prerequisite for this work. One-time carryovers
from Git are a later capability with their own design, not an implied promise
that Git and Yeokcham histories already map one-to-one.

That later design should decide whether to carry over a selected working state,
selected branches, or complete history; how merges, authorship, and names map
into Yeokcham; and what happens to externally stored content. Preserve the
distinction between imported authorship metadata and verified Yeokcham device
authority. Define validation and unsupported cases before promising historical
fidelity. These are questions for the later porting design, not additions to the
current implementation scope.

### Self-hosted service first: D16

The user or their team operates the Yeokcham server. The initial product must
support configuring a native remote and a private archive on self-hosted
infrastructure without a Yeokcham-operated account service. A managed hosted
product, hosted signup flow, and billing integration are outside the initial
scope. Future hosting options do not need to be settled for this implementation.

A deployment can serve team exchange and private backups while keeping their
audiences and authorization separate. Self-hosting does not make a shared relay
upload private, and project membership does not grant access to another person's
scratch history. Q09 must define private account identity, device enrollment,
recovery, settings, archive completion, and quotas for this deployment model.

The handoff must include a reproducible server setup and configuration guide,
clear storage/quota reporting, and verification that capture and available
offline operations continue during a server outage. Reconnection must resume
pending transfers without a separate manual recovery workflow.

## Decision status and remaining design

Resolved choices are binding design inputs. Items still marked open require
technical design; they do not reopen the accepted product choices.

| ID | Question or answer | Status / implication |
| --- | --- | --- |
| Q01 | Automatically back up local history privately and publish to teammates explicitly. | Policy resolved through D03/D13; owner/access and backup protocol design remain Q09. |
| Q02 | All shared history and branches by default, with optional narrower selection. | Resolved as D09; requires prefetch, completeness checks, and retained scope configuration. |
| Q03 | Explicitly integrate shared work; no further delivery action. | Resolved as D05/D06; replacement mechanics remain Q08. |
| Q04 | Recent history and pins local; older private history archived remotely, automatically by default. Account defaults and repository overrides. | Policy and initial limits resolved as D13-D15. Measure their practical behavior. D10 separately settles old-version compatibility. |
| Q05 | macOS and Linux first; Windows close second. | Platform order resolved as D11. Startup, pause/resume, and credential behavior still need design. |
| Q06 | Yeokcham remotes first; one-time carryovers designed later. | Resolved as D12; no initial Git import/export or bidirectional sync requirement. |
| Q07 | Ordinary source-code projects by size first, larger monorepos second, large binary/assets third; varied file types are a core goal. | Product priorities resolved as D19/D20. See the benchmark design; numeric latency/resource targets require baseline measurements. |
| Q08 | Preview and confirm integration by default; warn on opt-out. What are the exact baseline composition rules and representation of accepted versions? | D18 and TC01/TC02 settle behavior and plan binding; concrete composition, encodings, and persistence transitions need engineering design. Legacy artifact migration is excluded by D10. |
| Q09 | On the self-hosted service, how does an account own private backups/settings, enroll devices, and enforce archive completion, remote retention, and quotas? | Hosting and recovery policy resolved as D16/D17: owner phrase required after all-device loss, no administrator decryption/recovery. Account/key/archive protocol design remains. |
| Q10 | Integrate downloaded shared work offline, then synchronize and reconcile on reconnect. | Resolved as D21; concurrent-history representation and admission are engineering work. |
| Q11 | Use `.yeokchamignore` natively; translate Git ignore rules during later carryover. | Resolved as D22; no runtime `.gitignore` inheritance. |
| Q12 | Every trusted member may integrate; offer a native PR-style review workflow. | Resolved as D23/D24; direct integration is the default. |
| Q13 | Reviews optional by default; repositories may require approval. | Resolved as D25; see review workflow for the proposed minimal policy and exact-revision binding. |
| Q14 | Both personal preview confirmation and required renewed approval after relevant changes default on, with independent warned opt-outs. | Resolved as D18/D27; renewed approval is repository policy, and exact policy encoding/evidence evaluation remain engineering work. |

Next resolve the dependent defaults and engineering design.
Implementation-specific choices such as codec settings should be informed by
measurements; they do not all require product-level questions.

The workflow audit and review follow-up have been answered. Remaining work is
engineering specification: service lifecycle, measured performance targets,
integration representation/verification, the private account/archive protocol,
native ignore matching, and the review record/policy contracts.
TC01 in [Technical contracts](TECHNICAL_CONTRACTS.md) is agreed at the logical
model/behavior level: identity and history of work, including the distinction
between a reviewed revision, an accepted result, and later private working edits.
TC02 is agreed at the behavior/invariant level: exact plans, preserved private
edits, revalidation, recoverable application, concurrent offline histories, and
review coverage with D27's explicit opt-out. Concrete composition algorithms,
record encodings, policy evaluation, and journal transitions remain to specify.
D26's [CLI design](CLI_DESIGN.md) is a requirement across these interfaces.
The [implementation-readiness audit](TECHNICAL_CONTRACTS.md#implementation-readiness-audit-november-6-2026)
lists the remaining contracts, concrete CLI journeys, and validation evidence
needed for handoffs, distinguishing user-visible choices from engineering work.
Use D15's accepted defaults, D16's self-hosted deployment, D17's recovery boundary,
D18's preview behavior, and D19/D20's benchmark scope. Do not reopen these choices
by treating an implementation detail as permission to change product behavior.

The earlier recommendation to inherit `.gitignore` at runtime was rejected and
is superseded by D22. Review support is now agreed scope, rather than only a
possible later feature. Keep its ordinary path optional and discuss any further
requirements that would add material friction. Numeric codec settings, OS service
adapters, and routine implementation details can be specified and validated
within these agreed constraints without another product-preference round.

## Ideas still under discussion

- Selective undo that addresses unfinished interleaved work beyond ordinary
  reversal, with clear behavior when later work depends on the removed change.
- Cheap independent workspaces using shared immutable contents. This is a new
  candidate, not approval of the earlier deferred alternative-implementation
  feature. Working files and local undo histories would remain independent.
- Optional snapshot associations with test/build results or manual labels so a
  person can find a known working state. No mandatory extra ceremony or AI.
- Complete structured inspection/history APIs for editors, scripts, and agents.
  Only the subset needed by the agreed workflow is required before choosing a
  broader API product.

Incremental capture and metadata persistence are efficiency candidates within
D04. Their specific architecture remains open. None of these proposals should
be promoted into implementation scope merely because they are listed here.

## References and interpretation

- [Anthropic's Scion article](https://www.anthropic.com/research/redesigning-source-control):
  shared caching, incremental work, and programmatic access are relevant ideas.
  Scion's online dependency conflicts with Yeokcham's offline goal; its reported
  results do not predict ours.
- [Git background maintenance](https://git-scm.com/docs/git-maintenance):
  scheduled prefetch already exists; automatic downloads alone are not novel.
- [Git packfiles](https://git-scm.com/book/en/v2/Git-Internals-Packfiles) and
  [restic's storage design](https://restic.readthedocs.io/en/stable/100_references.html):
  established references for compression, reuse, and storage tradeoffs.
- [Jujutsu](https://github.com/jj-vcs/jj) and
  [JetBrains Local History](https://www.jetbrains.com/help/idea/local-history.html):
  comparisons for working-state history and recovery; assess the whole experience.

Implementation evidence is in the [architecture](ARCHITECTURE.md),
[watch runner](../bin/v1_watch_runner.ml),
[snapshot scanner](../lib/yeokcham_snapshot/yeokcham_snapshot.ml),
[chunker](../lib/yeokcham_chunking/yeokcham_chunking.ml),
[object store](../lib/yeokcham_store/yeokcham_store.ml),
[local state store](../lib/yeokcham_v1_store/yeokcham_v1_store.ml),
[undo model](../lib/yeokcham_v1_undo/yeokcham_v1_undo.ml), and
[delivery transition](../lib/yeokcham_v1_model/yeokcham_v1_model.ml).

## Future implementation handoffs

These are candidate work packages for later `/goal` prompts. They are not
running goals, assigned tasks, or finalized implementation instructions.

| Package | Outcome | Decisions or dependencies required |
| --- | --- | --- |
| A: measurements | Reproducible baseline workloads and resource/latency results across source sizes, monorepos, and binary/mixed assets | D19/D20 and the benchmark design; derive numeric targets from measurements |
| B: storage and capture | Efficient exact captures, native ignore matching, history persistence, and retained storage | A, D13/D14/D22, representation and archive contract design; no legacy migration requirement (D10) |
| P: private account and archive | Self-hosted owner/device access, phrase-recoverable private backups, inherited settings, and a quota-aware archive protocol | Q09, D13-D17, and agreed object/archive interfaces with B; no administrator recovery |
| C: background service | Managed capture, private archiving, and resumable synchronization on macOS/Linux, followed closely by Windows | D03/D09/D11/D13-D16/D21/D22, B/P contracts, service lifecycle design; stable storage/transfer interfaces |
| D: offline workspaces | Inspect, select, and integrate verified available versions offline | Q02, Q08, D21; completeness and materialization design |
| E: collaboration simplification | Replace delivery with integration that previews and confirms by default, with warned opt-out | Q03, Q08, D10/D12/D18/D20/D21/D23; representation and review-policy integration contracts |
| R: native reviews | Optional PR-style requests, discussion, revision-bound review, and opt-in required approval with configurable renewed approval | D24/D25/D27, review workflow design, signed identity/policy records, and E's integration contract |
| F: integrated experience | Validate coherent commands, status, errors, conflict handling, documentation, and end-to-end journeys for nontechnical users | D26 and the CLI design apply to every package from the start; F validates integration across B-E/P/R |

Before delegation, each prompt must name the design revision, accepted decision
IDs, objective, scope exclusions, owned interfaces/files, prerequisites,
format-compatibility boundaries, acceptance scenarios, and relevant validation
commands. Carry D10-D12 into the prompts: no obsolete-development-format support,
macOS/Linux followed closely by Windows, and native remotes before later carryovers.
Also carry D13/D14: automatic verified archiving, protected local recovery data,
account defaults and repository overrides, and truthful offline availability.
Carry D15/D16 as settled inputs: the 30-day/5-GiB/20-GiB initial defaults and
self-hosted service scope. Do not substitute a managed account service or
silently change the defaults while implementing an individual work package.
Carry D17-D20: owner-controlled recovery, mandatory preview confirmation by
default with a warned opt-out, and benchmarks/support covering source code,
large monorepos, and nontraditional file types. A code-only benchmark or a
silent confirmation bypass does not satisfy the agreed design.
Carry D21-D25: offline local integration and explicit reconciliation, native
ignore rules with later migration translation, integration by trusted members,
and optional native reviews with an opt-in approval requirement. Never equate
disabling personal preview confirmation with disabling repository review policy.
Carry D26/D27: every package supplies understandable outcomes, recovery status,
and actionable errors; review freshness and personal confirmation are independent
default-on safeguards with warned opt-outs at their respective policy scopes.
Define structured error/action data alongside each API so usable explanations
do not require the final CLI layer to infer state from raw error strings.
Unresolved product decisions must not become implicit implementer choices.
Separate shared schema work from consumers before assigning parallel tasks.
Benchmark and validate the integrated workflow, not only isolated modules.

Do not create goals or delegate implementation until the design is sufficiently
resolved and implementation is requested. Preserve unrelated changes and the
minimal-accuracy-only README constraint in all later handoffs.

## Design updates

- November 6, 2026: consolidated prior discussion into this dedicated record;
  recorded D01-D08, implementation gaps, acceptance scenarios, open decisions,
  and prospective handoffs.
- November 6, 2026, first design answers: resolved Q02/Q03 and added D09;
  documented the recommended private-backup policy for Q01 and its requirements.
  At that stage Q04-Q08 remained open.
- November 6, 2026, second design answers: added D10-D12, removed requirements
  for legacy artifact migration, settled platform order and native-remote scope,
  and separated current-use checkpoint retention from old-version compatibility.
  At that stage Q04 remained open.
- November 6, 2026, retention agreement: added D13/D14, resolved the default
  private-backup/archiving policy, and specified account/repository configuration,
  protection rules, capacity behavior, and acceptance scenarios. Added proposed
  numeric defaults and Q09 for the private account/archive contract. No runtime
  behavior was changed.
- November 6, 2026, limits and hosting agreement: accepted the initial defaults
  as D15, selected self-hosting first as D16, and updated the deployment scope,
  decision status, and future implementation handoffs. Account/archive protocol
  details and other remaining engineering design are still open.
- November 6, 2026, final product-question answers: added D17-D20 for owner-only
  recovery, preview confirmation with warned opt-out, ordered benchmark tiers,
  and non-source-code repositories as a core goal. Added recovery/preview
  acceptance scenarios and a dedicated benchmark design. Product preferences
  from these rounds are settled; technical contracts and measurements remain.
- November 6, 2026, workflow audit: identified Q10-Q12 for offline integration,
  ignore-rule inheritance, and integration permission. Recorded recommendations
  as pending choices rather than silently extending the accepted requirements.
- November 6, 2026, workflow answers: added D21-D24 for offline integration,
  native ignore rules, trusted-member integration, and native PR-style reviews.
  The user then selected optional reviews with repository-enforced approval as
  an opt-in policy (D25). Replaced pending audit recommendations with these
  decisions and added the review workflow design and future R work package.
- November 6, 2026, technical discussion started: added TC01 as a proposed
  history/identity contract, with the reviewed-D/private-E example and offline
  concurrency invariants. This is a discussion draft, not an implementation or
  a declaration that all technical interfaces are ready for delegation.
- November 6, 2026, TC01 agreement: the user accepted the logical history model.
  Marked TC01 agreed and drafted TC02 for discussion; no runtime changes or
  implementation delegation followed from that agreement.
- November 6, 2026, TC02 agreement and CLI priority: accepted the six integration
  behavior points, added D26 for comprehensible and effortless CLI interactions,
  and clarified both independent default-on safeguards with warned opt-outs
  (D18/D27). Updated the review design and added CLI requirements and examples.
  Changes remain documentation only; technical formats and APIs are not yet
  ready for implementation delegation.
