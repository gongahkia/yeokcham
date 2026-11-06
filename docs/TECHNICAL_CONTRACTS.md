# Technical contracts: discussion draft

Status: technical design in discussion, November 6, 2026. TC01's logical model
and TC02's behavior and invariants are agreed. Later topics remain
outlines. This document does not describe implemented behavior or mark
implementation handoffs ready. See the agreed [product design](PRODUCT_DESIGN.md).

A contract states what a component receives, what it produces, what remains
true, and how interruption or conflicting work is handled. Components may be
implemented separately only after their shared contracts are sufficiently
specified. Logical record types do not imply separate services, storage files,
or additional user commands.

## Discussion sequence

1. History and identity of work: snapshots, local ancestry, published revisions,
   accepted versions, and reviews. TC01 agreed; wire formats remain to specify.
2. Integration execution: exact preview binding, approval checks, deterministic
   composition, concurrent heads, and recoverable application to working files.
   TC02 behavior agreed; concrete algorithms, encodings, and transitions remain.
3. Private account and archive: device enrollment/recovery, encryption boundaries,
   complete backup acknowledgement, restoration, retention, and quota accounting.
4. Storage and service interfaces: native ignore matching, capture scheduling,
   incremental persistence, compression/packing, transfer retry, and platform
   lifecycle. Use the [benchmark design](BENCHMARK_DESIGN.md) for evidence.

The [CLI design](CLI_DESIGN.md) applies to every contract: expose enough domain
information to explain outcomes, preserved work, and next actions in plain
language. User comprehension is an implementation requirement from the start.

## TC01: identity and history of work

Status: agreed at the logical-model and behavior level. Concrete encodings and
API signatures are still engineering work; this agreement does not imply they
already exist in the implementation.

### Agreed logical records

| Record | Meaning | Identity and change rules |
| --- | --- | --- |
| Snapshot | Exact recorded project contents within the documented filesystem/ignore scope. | Immutable content identity. Storage compression or packing must not change its logical identity. |
| Local history node | A position in one workspace's editing history, referring to a snapshot and parent. | Distinct from content identity: identical contents can occur at multiple positions. Preserve ancestry and alternate continuations. |
| Shared revision | One explicitly published version of a named change, with its base, result, author, and declared edit scope. | Immutable and authenticated. Updating the change creates another revision; it does not mutate a reviewed version. |
| Accepted version | The exact result of an explicit integration, with its accepted parent version(s), included revisions/resolutions, and relevant policy/review evidence. | Immutable and authenticated. Its result must match the validated integration plan. |
| Review request/version and review event | A request to inspect selected published work, and a comment/approval/change request about a particular version. | A stable request groups immutable versions and events. Approval covers exact work and context, never a floating latest label. |

Mutable convenience state, such as the current local cursor or a selected branch
head, refers to these records. Moving a pointer does not rewrite its previous
target. A shared branch is not the same object as a local undo branch or a draft
title. Their representation and concurrent-update rules are part of TC02.

These records are internal bookkeeping. The user's normal flow remains editing,
explicit sharing/review where desired, and previewed integration; there is no
new command for manually creating each record type.

### Local ancestry and multiple devices

Each workspace has its own history and current position. Receiving private
history from another enrolled device must not move that position or replace
working files. Resuming another workspace's recorded state is an explicit
selection/restoration operation.

The present undo node IDs are local integers. A private archive combining
workspaces needs a stable namespace, such as a workspace identity plus a local
node identifier, so two different node `7` values cannot be confused. Specify
the namespace and duplicate/retry rules before exporting private history.
Do not infer ancestry merely from equal snapshots, timestamps, or device names.

### Publishing is a stable boundary

Publishing revision R1 fixes the contents being shared. Subsequent captures of
unfinished local work do not change R1, an approval of R1, or the result of an
integration that names R1. Publishing updated work produces R2 explicitly.

Export only the declared published records and the content dependencies needed
for them. Private undo metadata, unselected private versions, account secrets,
and recovery material must not be included merely because they are in the same
local store. A public revision's declared scope and result must agree; the
composition/export contracts must prevent an unrelated private edit from being
smuggled into a supposedly narrower shared result.

### Accepted contents and current working files can differ

An accepted version records the chosen integration result, not whatever happens
to be in the integrator's working directory at that instant. The workspace may
still contain later private edits. Preserve those edits or require explicit
conflict handling rather than silently publishing or discarding them.

Example:

1. The user captures states B, C, returns to B, and develops D. Both C and D
   remain in the local undo tree while their contents are retained.
2. The user shares D as revision R1 and then edits E privately.
3. A teammate approves the exact version R1.
4. Integrating R1 against its unchanged base accepts D; it does not include E
   simply because E is now present in the working files. E stays recoverable as
   unfinished local work. If a different base requires a different result, the
   revised composition/review/preview rules apply to that result explicitly.

This addresses a real current boundary: V1 delivery records an observed working
snapshot and included revision IDs without proving that the two describe the
same composition. The replacement must not inherit that ambiguity by merely
renaming delivery.

### Offline acceptance preserves competing histories

An integration performed offline records its known accepted parent(s), exact
result, and the authority/policy/reviews available locally. It cannot claim that
all other devices have observed or accepted it.

If two members independently integrate different work from the same accepted
version, retain both resulting records after synchronization. Arrival time does
not decide which contents survive. A new reconciliation result must name the
histories it combines and obey the usual review and preview requirements.
Synchronization can discover and prepare that reconciliation; receipt alone
does not authorize applying a newly composed result.

### Contract checks

- Equal contents can have different local history node IDs; repeated transfer
  of an existing record does not create a new edit or duplicate acceptance.
- New private edits do not mutate a previously shared or reviewed revision.
- A shared export contains no unrelated private ancestry or unselected content.
- Integrating a reviewed version does not accidentally include later local edits.
- Confirmed result identity equals recorded accepted snapshot identity.
- Concurrent offline accepted versions survive synchronization in either order.
- Receiving history never silently moves another workspace's local cursor.
- Review decisions remain attached to their actual immutable version/context.

## TC02: integration planning and execution

Status: agreed at the behavior and invariant level, including D27's configurable
renewed-review requirement. This gives D18's preview/confirmation and D21's
offline integration concrete boundaries, while preserving TC01's separation of
accepted contents from private working edits. Exact wire formats, composition
algorithms, and journal transitions still need specification before delegation.

### An integration is one exact plan

Preparing an integration resolves floating names to exact records and constructs
an immutable plan. The logical inputs and outputs are:

| Part | Required information |
| --- | --- |
| Repository and target | Repository identity, target shared branch, and locally known accepted parent/head identities. |
| Chosen work | Exact shared revision IDs, dependency/base records, and any explicit resolution revisions. |
| Authorization and review | Relevant authority and repository-policy identities, review request version, and approval evidence when required. |
| Workspace context | Workspace identity, local history position, recorded working basis, and an exact observation of current disk contents. |
| Accepted result | Deterministically composed snapshot of the selected shared work, excluding unrelated private edits. |
| Workspace result | Proposed post-integration working snapshot preserving private edits, or explicit conflicts preventing safe application. |
| Plan identity | A canonical identity binding these inputs, outputs, conflicts, and the composition-rule version. |

Canonical encodings and concrete function signatures are still to be specified.
The interface must distinguish ready plans from missing contents, unresolved
conflicts, invalid authority, or missing required approval. Preparation can stage
immutable objects and read local state, but cannot advance accepted history,
publish acceptance, or modify ordinary files.

Human confirmation authorizes this plan identity. When confirmation is disabled
by an explicit preference or invocation, the same plan, validation, and policy
checks still apply. Disabling confirmation is not authority to change its inputs
while applying it.

### Composition is deterministic and scope-checked

Construct the accepted result from the named accepted base(s), selected published
revisions, and explicit resolutions. Identical canonical inputs must produce the
same result or the same unresolved decisions, regardless of relay arrival order.
Do not substitute a fresh scan of the live workspace for the accepted result.

Dependencies and incompatible overlapping edits must be explicit. Compatible
changes can be combined by the specified composition algorithm; opaque-file
conflicts require an exact version or explicit replacement, not a guessed byte
merge. Source revisions whose declared edit scope and base/result contents
disagree must be rejected before their contents can be accepted or exported.
No runtime AI service is needed to decide these mechanical conditions.

The precise text-composition algorithm and its versioned encoding need to be
fixed before implementation; do not leave different clients free to choose
different merge algorithms for the same accepted record.

### Two outputs preserve private work

The accepted snapshot and working snapshot can differ. Use the recorded workspace
basis, local ancestry, and known correspondence to selected shared revisions to
preserve later private edits. Do not naively replay an already-present shared
edit twice or count the entire working-tree difference as newly accepted work.

For the TC01 example, accepting shared D while the user has privately edited E
records D as accepted and retains E in the workspace when their relationship is
known and compatible. If incoming changes conflict with private edits, show that
as a workspace conflict and stop the default application before writes. Preserve
both the private state and proposed accepted result for explicit resolution;
do not silently publish, discard, or temporarily hide the private work.

The preview shows both effects: what enters accepted history and what changes
in the current files. Requiring a conflict to be resolved is separate from a
review approval or confirmation preference.

### Review approval across target advances

Agreed default rule: approval remains approval of the exact submitted revision
and its reviewed file-level context. An unrelated accepted change elsewhere in
the repository need not force another review when the submitted revision and
the preconditions/contents on every affected path remain unchanged. Still
regenerate the integration preview when its target head changes.

Changing submitted contents, manually resolving a conflict, or changing relevant
file/path context means the prior approval does not cover the new composition.
Approval does not certify semantic compatibility with every other file in the repository.
The mechanical coverage check must be explicit and conservative, including
ancestor path/type changes; ambiguous coverage requires review again by default
when the repository enforces approval. Unrelated target changes do not force
another review when the stated coverage remains unchanged.

### Two independent safeguards and their opt-outs

Both safeguards are enabled by default and may be disabled after a warning:

- Integration preview confirmation (D18) is a personal account/repository
  preference. Its warning explains that future explicit integration requests
  can apply without a confirmation pause. It does not disable team review rules.
- Requiring renewed approval after relevant changes (D27) is a repository review
  policy. Authorized repository policy changes can disable it, with a warning
  that later content or conflict resolutions may be integrated without anyone
  reviewing those changes. Personal preferences cannot override this policy.

Required reviews themselves remain opt-in (D25). In an advisory repository,
review freshness is reported but does not introduce a mandatory approval gate.
When required reviews are enabled and renewed approval is disabled, the policy
may permit proceeding on evidence of an earlier review. The old approval stays
bound to its exact version/context; never label the new content as reviewed or
fabricate approval of it. Expose the effective policy and the uncovered changes
in inspection and record the policy/evidence used for acceptance.

Disabling either or both settings never disables conflict detection/resolution,
plan revalidation, authorization, exact-result verification, or preservation of
private work. Reduced review can allow mistakes or semantic incompatibilities
through; it does not authorize silently choosing a side of a detected conflict.
Re-enabling renewed approval requires current coverage for future integrations;
it does not rewrite earlier accepted history or old approval records.

The [review workflow](REVIEW_WORKFLOW_DESIGN.md) specifies the proposed eligibility
rules for earlier-review evidence. Its signed policy encoding and evaluator are
still engineering work. Warn at opt-out with the affected scope, show the active
setting in status/inspection, and avoid replacing the opted-out pause with an
equivalent warning prompt on every operation.

### Revalidate after confirmation

Before applying, verify that the plan's relevant inputs are still current and
that all required result objects are present and valid. A changed working tree,
local cursor/basis, target head, chosen review version, or relevant authorization
and approval state makes the plan stale. Show a new plan and obtain confirmation
again under the active preference rather than applying an unseen replacement.

Unrelated background receipts or comments should not by themselves invalidate
the plan. Check the inputs it actually depends on, then publish metadata against
the latest consistent local state so independent incoming records are preserved.
Serialize Yeokcham's own application/state writers around the critical section;
do not hold that lock while waiting for a human or performing network transfers.

### Recoverable application and publication

The agreed logical sequence is:

1. Validate the selected plan and all needed objects, preserve the exact current
   workspace in a durable recovery root, and write an operation journal binding
   the plan, old local state, accepted result, and workspace target.
2. Apply the working-file changes through the journaled materialization path.
   While incomplete, ordinary watcher capture must not record the partially
   applied tree as a normal editing state.
3. Verify the materialized workspace and atomically publish one local state
   update containing the accepted-version record, relevant local references,
   undo/recovery references, and durable outbound work for synchronization.
4. Mark the journal completed. The daemon sends only acceptance records exposed
   by committed local state; a staged or merely previewed record is not public.

The journal and local commit must make retry idempotent. A crash before the
local commit resumes the same confirmed operation; a crash after it recognizes
that operation as already committed. Neither case creates a second acceptance,
takes an additional undo step, or authorizes a different integration result.
Receipt failure or a lost network acknowledgement leaves the same outbound work
retryable. Remote availability is not part of the local commit condition.

This sequence is not an atomic filesystem transaction visible to editors or
other processes. The detailed journal must specify path-level pre/post checks,
unexpected concurrent-write handling, and forward/recovery behavior at each
interruption point. Unexpected external edits must not be silently overwritten
by a retry. These mechanics need specification before TC02 is implementation-ready.

### Concurrent offline results

Local integration records known parents and local authority/review context.
Synchronization transfers immutable records without declaring the last upload
to be the unique accepted head. If two members accepted different descendants,
preserve both and present their divergence for reconciliation. A newly composed
result follows ordinary review and preview rules; simple receipt does not merge
it into the working files or grant approval for its contents.

If newly received authority or policy makes admission of a local operation
questionable, retain the local work and expose the discrepancy. Do not invent
retroactive global approval from local success. The exact authority/admission
rules must reuse the explicit trust model and be specified alongside branch
references and accepted-version records.

### Contract checks

- A previewed integration creates no accepted head or outgoing acceptance.
- A changed workspace or relevant shared head invalidates prior confirmation;
  unrelated receipt does not erase state or force unnecessary confirmation.
- Accepted output excludes later private edits while the workspace preserves them.
- Incompatible private edits block default application before file replacement.
- Required review cannot be bypassed by disabling preview confirmation.
- Unrelated target changes preserve eligible approval under the stated coverage
  rule; changed submitted work or relevant context does not inherit approval.
- Both safeguards default on and can be disabled independently with a scoped
  warning. A repository-authorized freshness opt-out is distinguished from a
  personal confirmation preference and from actually reviewing the new version.
- With renewed approval disabled, only eligible earlier-review evidence can
  satisfy the configured policy; missing/withdrawn approval and other policy
  blockers are not bypassed. Both settings off still block unresolved conflicts.
- Failures at each journal/metadata transition resume or recover the same
  operation without losing private data or creating duplicate acceptance.
- A failed upload retries the already-recorded acceptance rather than creating
  a new accepted version with new provenance.
- Concurrent offline integrations survive receipt in either order and require
  a separately authorized reconciliation result when contents change.

## Current implementation and outstanding specification

The current [model](../lib/yeokcham_v1_model/yeokcham_v1_model.mli) already separates
snapshot IDs, drafts, shared changes, and immutable revisions with base/result
snapshots. The [undo model](../lib/yeokcham_v1_undo/yeokcham_v1_undo.mli) separates
node and snapshot identities. The [trust interface](../lib/yeokcham_v1_trust/yeokcham_v1_trust.mli)
authenticates revisions under explicit authority context.

Accepted-version history and native reviews are agreed logical additions/
replacements; their wire encodings and APIs are not specified by TC01 alone.
TC02 establishes agreed execution boundaries, but composition, branch references,
exact plan encoding, journal state transitions, and concurrent-history admission still
need a complete specification. TC03 must define private identity/key ownership,
archive formats and completion, and recovery.

No old-development-format compatibility layer is required (D10). That freedom
does not remove the need for exact current-format recovery or consistent retry.
Keep proposed schemas and APIs separate from approved product decisions until
the corresponding technical discussion has resolved them.

## Implementation-readiness audit: November 6, 2026

The user accepted the CLI direction and asked whether further checks were needed.
The product decisions and TC01/TC02 behavior are settled at their stated level;
the documents are not yet complete contracts for independent implementation of
the whole system. The remaining work is:

| Area | Specification or check still needed | How to resolve it |
| --- | --- | --- |
| Private account and archive (TC03) | Initial setup, enrolling/removing devices, recovery, ownership/key boundaries, encrypted history/index records, complete-backup acknowledgement, settings concurrency, and eviction eligibility. | Discuss the user-visible enrollment/recovery flow next; specify the protocol and failure cases against the existing owner-only recovery and retention decisions. |
| Background service and storage (TC04) | Startup and pause/resume behavior, capture scheduling and reconciliation, resource bounds, interrupted transfer/maintenance, packing dependencies, and quota handling. | Specify concrete lifecycle and storage interfaces; use measurements for tuning rather than asking the user to pick codecs or low-level parameters. |
| Shared records and integration | Canonical identities/encodings, deterministic composition, concurrent branch references, stale/revoked authority and policy handling, review-evidence evaluation, and every journal transition. | Complete TC01/TC02's engineering details and executable acceptance cases before assigning dependent consumers. Preserve the agreed behavior. |
| Capture and filesystem scope | Native ignore pattern semantics and behavior while files are changing; representable paths and supported attributes across macOS, Linux, and Windows. Include filename collisions and unsupported materialization cases. | Define exact scope and preflight failure behavior without silently renaming, excluding, or overwriting work. This does not expand the agreed filesystem-fidelity promise. |
| Actual CLI and review journeys | Command vocabulary, contextual next actions, prompts and opt-outs, structured results, and full setup/edit/offline/conflict/recovery walkthroughs. The initial reviewer-count mechanism and earlier-review eligibility rules are still labeled proposals. | Draft complete interactions and settle user-visible choices before freezing command/API contracts; evaluate comprehension using the CLI design criteria. |
| Validation and handoffs | Defined crash/disconnection/disk-pressure cases, workload fixtures, baseline measurements, module/API ownership, dependencies, and focused validation commands for each work package. | Specify the scenarios before feature implementation, then run them against implemented behavior. Derive performance budgets from measurements and state the tested workload/hardware. |

User discussion should focus on consequential workflow choices such as device
setup and recovery. Routine representations, OS adapters, and codec settings can
be designed within the agreed requirements; they do not need another broad
product-preference questionnaire. Raise an engineering limitation if it would
change the promised behavior rather than silently weakening that behavior.

Readiness is assessed per work package. Baseline measurement work need not wait
for a finished private archive, while consumers of a shared format need that
format specified first. This audit does not start implementation, create goals,
or turn unmeasured performance and planned usability checks into completed evidence.

## Discussion record

- November 6, 2026: the user agreed to TC01's logical records, immutability,
  distinction between reviewed/shared work and private edits, and preservation
  of concurrent histories. Concrete encodings remain engineering work.
- November 6, 2026: drafted TC02 for the next discussion, including exact plans,
  separate accepted/workspace results, approval coverage, interruption handling,
  and local commit before asynchronous publication. At that point TC02 was proposed.
- November 6, 2026: the user agreed to all six integration behavior points and
  clarified that both preview confirmation and renewed approval after relevant
  changes should default on with warned opt-outs. Recorded the distinct personal
  and repository-policy scopes without weakening immutable review identity or
  conflict/integrity checks. Added the CLI comprehension requirement; no runtime
  implementation was authorized or performed by this design update.
- November 6, 2026: audited remaining design and handoff gaps after the user
  accepted the CLI direction. Recorded the areas above; private account/archive
  setup and recovery remain the next technical discussion. Documentation checks
  do not establish runtime correctness, performance, or usability results.
