# Yeokcham V2 D1: product RFC

**Status: DRAFT / NOT YET OWNER-APPROVED**

Date: 2026-11-19, Singapore

Observed source HEAD: `a61749f270ed1c65062f7c2845dc7fce261bbea5`

Prior D0/D1 audit HEAD: `ce482b23f3c46f8ffd6fcc43c9d475b342c524cc`

This is the canonical **proposed** V2 product document submitted for owner review,
not an approved replacement for existing V1/Core contracts. The D2 task treats
D1-A through D1-F as provisionally accepted planning directions. Neither this
document nor its companion [architecture RFC](D2_PYTHON_ARCHITECTURE_RFC.md)
authorizes implementation, migration, P4, or any G-phase. Architectural defaults
in the companion are proposals requiring D3 review. Existing specifications and
the research draft remain unchanged.

## 1. Executive summary

Yeokcham is a local-first version control system that automatically records
recoverable versions of included files saved to disk. People and coding agents
can develop competing ideas independently, revisit earlier experiments, and
choose what to share. Receiving work leaves current files alone. Publishing work
does not accept it. Users explicitly select the exact work entering an accepted
shared version; other candidates remain accessible under explicit retention
rules. Conflicts request decisions when combining or applying incompatible work,
rather than blocking valid independent preservation and publication.

The implementation should be predominantly Python for readability, debugging,
and maintenance. Python is an implementation preference, not the differentiator.
Priority order is preservation/correctness, low routine friction, inspectability,
independent human/agent work, offline operation, maintainability, then measured
efficiency. A smaller implementation may decline unsupported operations; it may
not report success with weaker preservation or authorization.

## 2. Evidence and current state

Git inspection found a clean working tree on `main`. The only committed change
since the audit HEAD adds `yeokcham-python-rewrite-research.md`; its SHA-256 is
`df3b48f40be92e64f987104b3677287453b1f8b74cf0798fd3d3ea9b7e579365`, matching
the preceding audit. Both RFC target paths were absent before this task.

Use these evidence categories throughout:

- **Existing:** source behavior supported by cited tests/reports, not necessarily
  freshly executed here.
- **Committed product requirement:** an existing decision/technical contract,
  even where implementation is incomplete.
- **Proposed:** V2 behavior or implementation direction, not demonstrated runtime
  behavior. Predictive judgments are design inferences, not measured advantages.

[Implementation progress](../IMPLEMENTATION_PROGRESS.md), lines 7–56, and the
[P03 report](../implementation/reports/P03-attempt-01.md) establish scoped P1–P3
completion. P4 remains unstarted; only G01 is complete as a full original phase.
Core provides private capture, alternatives, selected publication, verified
exchange/nonapplying receipt, exact integration, explicit conflict choices and
recovery. Managed capture, private archive, complete native onboarding, incremental
persistence and full native/human qualification remain incomplete.

The later full CI attempt exited 2. The unresolved test is
`test/test_benchmark_runner.py::RunnerTests.test_resume_preserves_samples_and_refuses_changed_inputs`,
linear and branching subcases, with
`installed target bytes changed at "restored" after application`.
Earliest independently documented failing source: `fba3daa945eb2c670595ab660576be30b8b3d380`;
first checked-in report located: `ce482b2`. Introduction revision and root cause
are unknown. See the [ledger](../IMPLEMENTATION_PROGRESS.md), lines 2127–2149,
and [receipt](../implementation/results/cli-graph-20261116.json). No fresh OCaml
suite, reproduction, agent experiment or performance comparison was run for this
documentation task. Passing historical P3 CI does not make the later state green.

## 3. Scope and non-goals

The first Python milestone delivers exact local storage, private history,
recoverable restoration and managed capture on qualified native hosts. Manual
capture, inspection and recovery controls remain available. Subsequent small
tranches add candidate continuation, native exchange and acceptance. The complete
product retains self-hosted exchange, security, review policy, private backup,
retention and platform commitments; staging is not retirement.

Initial non-goals: an agent orchestrator, virtual filesystem, semantic/AI merger,
automatic team publication, mandatory online service, managed hosting, Git
interoperability, advanced delta chains, or a claimed speed advantage. Opaque and
large assets remain first-class even before performance optimization. Native
macOS and Linux are initial targets; Windows follows closely, with qualification
work starting before the final migration tranche.

## 4. Observable product rules

### 4.1 Quiet private history (D1-A)

After successful setup and actual service readiness, ordinary editing requires
zero routine VCS commands. Capture records completed observations of included disk
contents. It does not promise every intermediate write, unsaved editor buffers,
or a transactional state of an application writing multiple files.

Watcher notifications are hints. Startup, wake, event loss, interruption and
periodic reconciliation must discover missed changes. Manual `save` requests an
immediate pass. Unchanged automatic/manual capture adds no history node. Equal
snapshots may nevertheless appear at distinct editing positions after a real
continuation, restoration or integration.

Report the last completed capture separately from later dirty/unknown disk state.
An unstable file, malformed ignore rule, unsupported special file, unavailable
storage or interrupted application can block a complete observation. Preserve
the previous completed state, report the cause and retry appropriately. Scheduled
attempt intervals are not capture-completion guarantees.

A capture is a validated filesystem observation, not a transaction across every
file an editor or build writes. Stable per-file/namespace checks do not promise
that all captured bytes coexisted at one global instant. Unsaved buffers and every
intermediate write are outside this product promise.

Supported fidelity: regular bytes, executable distinction, empty directories and
symlink-target bytes; names are lossless within destination-platform limits.
Ownership, timestamps, arbitrary permissions, ACLs and extended attributes remain
outside the promise. Use `.yeokchamignore`; do not silently consult `.gitignore`.
Initialization must make this scope discoverable without claiming secrets are
automatically recognized. See [TC07](../TECHNICAL_CONTRACTS.md), lines 740–791.

### 4.2 Independent work (D1-B)

If A1 and B1 continue R0, A2 may continue A1 and B2 may continue B1 without
accepting or merging the sibling. Ordinary continuation does not require a new
branch. References identify exact predecessors; timestamps and receipt order do
not select one. A successor naming several predecessors is not, by itself,
evidence of content reconciliation.

Separate these possible blockers: invalid input, missing content, authorization,
storage/custody failure, and unsafe or incomplete filesystem application. An
unrelated content conflict in another workspace must not block valid capture or
publication. This does not promise lock-free metadata or bypass authority forks.

The current gate is real: `Native_share.prepare` in
[native_share.ml](../../lib/yeokcham_v1_local_service/native_share.ml), lines
106–140, requires an accepted basis representing every concurrent change head.
Related protections appear in `Integration.selection_root`, `Graph.reconciled_base`
and `Publication_receipt.proof`. V2 changes the product rule while preserving the
proof that each public result derives only from authorized public inputs and
explicitly selected new contents.

Two reviewed alternatives:

| Model | Benefit | Cost | Recommendation |
| --- | --- | --- | --- |
| A: continue an exact revision within one change | One recognizable effort; causal alternatives coexist; no new branch ceremony | Precise selection, pending-work and dependency rules are needed | Provisional default |
| B: split competing continuations into distinct candidate changes | Independent selection is straightforward | More identities/lifecycle work and grouping; a silent split can confuse users | Fallback if Model A proves too complex |

Both require scoped public closure, signatures, authority checks and exact
acceptance. Neither permits exporting the entire private tree as a shortcut.

| Concern | Model A: one change, independent continuations | Model B: separate candidate changes |
| --- | --- | --- |
| User friction | Continue an exact revision; resolve an ambiguous selector when needed | Allocate or automatically split a new change, then explain its relationship |
| Causal history | Same-change evolution and content dependencies are explicit distinct edges | Cross-change origin/dependency links are needed to preserve equivalent provenance |
| Privacy | Publish only selected public derivation; private correspondence stays private | Same requirement; splitting identities does not improve disclosure safety |
| Authority | Each author must be authorized; no exclusive ownership inferred from a change ID | Same authority checks; naming a new change cannot bypass policy |
| Deterministic acceptance | Exact subset and dependency closure; sibling arrival is not a winner | Exact changes and dependency closure; grouping no longer determines selection |
| Implementation/explanation | Fewer user identities, more precise lifecycle/selection semantics | Simpler per-change head selection, more grouping/splitting/lifecycle machinery |

Model A is preferred because independent continuation is ordinary work. If its
provenance/selection rules cannot stay comprehensible, Model B is the fallback;
neither model justifies weakening acceptance or privacy to simplify implementation.

### 4.3 Deliberate acceptance (D1-C)

Four boundaries remain distinct:

1. A private local capture completes.
2. An authorized selected revision is recorded for publication.
3. A recipient verifies its content and authority; transfer acknowledgement is a
   separate fact from local recording.
4. An explicit integration records exact accepted contents and its provenance.

Accepting A2 can leave B1 pending. The preview names selected revisions,
dependencies, accepted parents and any resolutions; it labels deferred known
alternatives without treating them as included, rejected or deleted. Continued
publication on B1 remains possible. Dependencies actually needed by A2 cannot be
silently omitted in the name of selective acceptance.

Candidate continuation, publication, selection, supersession, rejection,
resolution and accepted-head reconciliation are separate meanings. Causal
replacement does not mean rejected bytes; a resolution may account for a variant
without selecting its contents. Candidate status can differ between accepted
branches or concurrent accepted histories.

Concurrent already-accepted heads still require an explicit plan naming the
heads reconciled to establish a common accepted history. Do not turn selective
candidate acceptance into permission to hide accepted divergence.

Acceptance derives from exact public inputs, never arbitrary live working files.
Preserve separate accepted and workspace outputs, later private edits, default
confirmation, stale-plan checks, authority, applicable review and durable recovery.
No acceptance-only/headless mutation bypasses the existing TC02 application
contract in the initial design. A clean materialized integration workspace can
be used; queries and planning need not require a checkout.

### 4.4 Privacy, availability and trust (D1-D)

Capture is private by default. Configured private backup is encrypted and has a
verified completion state. Team publication requires explicit authorization.
Trusted-team automatic publication remains a future opt-in hypothesis.

Receipt changes neither ordinary files nor local history selection. A relay
acknowledgement is not acceptance or proof that every peer has the work. Offline
availability means a named closure was verified locally; record last successful
contact and unknown remote freshness. Do not evict a sole recoverable copy merely
to meet a storage target. Finite storage can eventually stop new capture during a
backup outage; report that condition honestly.

Signing capability is not membership, a relay token is not authority, and owner
labels are not permissions. Private-account enrollment and repository membership
remain distinct. Received records do not execute project hooks or tests.

Receipt can reveal authenticated accepted alternatives without creating a new
acceptance or selecting one. Distinguish the known accepted-head set from the
workspace's chosen basis. If several accepted heads are already known on the
target branch, common acceptance requires explicit reconciliation of those heads.

### 4.5 Conflicts and automation (D1-E)

Keep verified variants in immutable storage. Show paths, provenance, base,
versions, scope, availability, and concrete compare/select/export/defer actions.
Do not scatter sibling source files into active build/import paths. Opaque files
use exact selection or explicit replacement, not guessed merging.

Use existing workspace identities, separate ordinary directories, private
histories and one typed API for humans and agents. No new persisted lane identity,
virtual filesystem or agent authority system is approved. Directory separation
is not an OS security sandbox. Workspace retirement and deleting its directory
are separate actions; protect captured history and inspect uncaptured/ignored
contents before deletion. Calling a workspace archived does not assert backup.

Provenance links work context, starting snapshot, output snapshot, candidate IDs,
process/session identity and completion/failure/interruption. Test evidence names
the exact tested snapshot, runner, command/environment and observed outcome.
Changed inputs invalidate the relevance of that result to a later snapshot.
Evidence is neither authorization nor proof of semantic correctness.

## 5. Eight acceptance journeys

| Journey | Required outcome | Preconditions, honest limits and friction |
| --- | --- | --- |
| J1: ordinary editing | Initialize, edit without VCS commands, restart and recover last completed capture | Healthy service, included paths and writable storage; later writes/buffers may be uncaptured; service readiness must be actual |
| J2: historical recovery | Revisit an experiment while retaining current and alternate work | Target bytes retained/retrievable; preserve dirty included work and refuse ignored/untracked obstructions; no implicit shared-history reversal |
| J3: two offline laptops | Both histories remain accessible after authorized owner-only exchange | Private-account/history exchange is planned, not current public relay behavior; explicit team sharing is a different journey; no cursor movement on receipt |
| J4: two teammates | Both continue publishing overlapping alternatives; integration deferred | Exact public predecessors, valid authority/custody/storage; ambiguous labels need exact selection, not a mandatory merge |
| J5: opaque asset | Independently accessible exact variants; explicit selection/replacement | Verify full closure and native representation; metadata alone is not availability; text-merge bounds are not file-size cutoffs |
| J6: three agents, one crash | Retain completed captures, identify surviving later disk edits, inspect evidence, selectively accept | Separate working contexts; no promise for all unflushed writes/buffers; labels do not sandbox processes; evidence is snapshot-bound |
| J7: interrupted restore | Diagnose and resume/recover without overwriting later external edits | Preserve journal, staging, safety/target roots; partial filesystem state is explicit; no automatic rollback or normal capture of partial application |
| J8: backup outage | Local retained history works; backup incomplete; no sole-copy eviction | Account/credentials/server may be unavailable; retries do not block local capture until genuine local resource failure |

## 6. Command and status contract

Ordinary vocabulary: `init`, `clone`, `status`, `history`, `diff`, `restore`, `share`,
`conflicts` and `integrate`. Human wording describes integration as accepting work;
retain the established command spelling rather than adding another synonym now.
`save` is optional immediate capture. `sync` is an optional immediate pass for
already-authorized transfer/backup; it does not select new work or accept it.
Do not add `done`: a combined save/share/accept meaning obscures consent.
Advanced branch, workspace, review, account and recovery controls remain available.

Show independently: completed local capture, dirty/unknown disk state, private
backup coverage, publication pending/acknowledged, accepted locally/pending
exchange, offline coverage, and actionable degraded state. Successful background
events stay quiet. Errors name affected work, preservation facts, uncertainty and
safe next actions. JSON and typed API carry facts, exact IDs, operations and
outcomes; agents do not parse terminal prose. Secrets and private source contents
do not enter ordinary logs or JSON. See [CLI design](../CLI_DESIGN.md).

## 7. Existing decisions and intentional proposals

| Decision group | Disposition | Explanation |
| --- | --- | --- |
| D01/D07/D08/D19/D20/D26 | Keep | Everyday VCS, no mandatory AI, mixed files, useful explanations, measured claims |
| D02/D22; TC01/TC07 | Keep | Exact supported fidelity, history identity, alternatives and native ignores |
| D03/D06/D09/D16/D21 | Keep | Managed local-first background work, explicit sharing, verified offline scope, all shared history by default, self-hosting |
| D05/D18/D23; TC02 | Keep | Explicit exact integration; default confirmation; authority and private preservation; no extra delivery |
| D24/D25/D27 | Keep; stage implementation | Optional reviews, required-policy enforcement and exact freshness; unsupported required modes refuse |
| D11 | Keep | macOS/Linux first, Windows close second; indefinite Windows deferral in the research draft is not adopted |
| D12 | Keep | Native Yeokcham exchange first; one-time Git carryover later, without continuous Git interoperability |
| D04/D13–D17 | Keep; stage implementation | Storage efficiency, private archive, settings/quotas and recovery remain obligations, not first-tranche claims |
| Current same-change publication/selection gates | Revise provisionally | Exact continuation and selective acceptance; do not weaken multi-parent reconciliation proof |
| TC04 workspace writer scope | Refine provisionally | Short shared commits allowed; unrelated workspace conflicts/human waits do not stop independent work |
| D10 and TC05/TC06 | Explicit D2 proposal | Development representation may change, but current identity/encoding defaults cannot silently disappear |
| D28/D29/D30; P4/G01–G20 | Keep authority; sequencing approval open | These drafts do not execute, close or replace existing phases |

The [approved decision register](../PRODUCT_DESIGN.md), lines 41–74, contains
older status text (including P2 in progress); the newer ledger/P03 report governs
implementation status. [Formal model](../FORMAL_MODEL.md) and
[Architecture](../ARCHITECTURE.md) describe V1 and must not be mistaken for proof
of complete Core or future V2 behavior.

### Prioritized simplification

1. **Preserve correctness boundaries first.** Distinct history/content/causal
   identity, scoped publication correspondence, exact public/private outputs,
   trust, policy and native application journals each protect a different failure
   boundary. They are not interchangeable ceremony.
2. **Simplify representation and ownership.**
   [State persistence](../../lib/yeokcham_v1_store/yeokcham_v1_store.ml),
   `store_with_history`, lines 701–746, nests V1 state, local history and Core
   metadata. Replace that overlap in the proposed Python model, not by translating
   every wrapper or deleting the old implementation. Risk: losing private
   correspondence or recovery roots while flattening state.
3. **Simplify workflow orchestration.** The existing
   [CLI](../../bin/yeokcham_v1.ml) and
   [local service](../../lib/yeokcham_v1_local_service/yeokcham_v1_local_service.ml)
   concentrate parsing, coordination and persistence. Share one typed application
   API, organize it around transitions, and keep the minimal vocabulary in section
   6. File size is evidence of concentration, not proof that checks can be removed.
4. **Remove redundant proposed machinery.** Do not recreate parallel V1/Core
   aggregates, duplicate authoritative cursors, a second event-sourced authority,
   or a persisted lane object without a demonstrated need. This removes work from
   the rewrite proposal; it does not authorize removing existing records or APIs.
5. **Defer optimization and extra primitives.** Packs/deltas, virtual filesystems,
   a lane identity and advanced incremental indexes need measurements or the
   three-agent experiment. Review, archive and Windows can be staged but remain
   product obligations. The detailed dependency order is in D2 section 16.

## 8. Prior art, experiment and rejection conditions

Verified official references, retrieved 2026-11-19:

- [Git worktrees](https://git-scm.com/docs/git-worktree): shared repository with
  separate working directories and per-worktree state; detached use is supported.
- [Jujutsu working copy](https://docs.jj-vcs.dev/latest/working-copy/): command-time
  snapshotting and multiple workspaces.
- [Jujutsu conflicts](https://docs.jj-vcs.dev/latest/conflicts/): conflicts can be
  stored and resolution deferred.
- [Jujutsu operation log](https://docs.jj-vcs.dev/latest/operation-log/): repository
  operation inspection and recovery.
- [Scion](https://www.anthropic.com/research/redesigning-source-control): cheap
  changesets and programmatic operations inspire separation of candidate creation
  from ref movement; its always-reachable server model is not adopted.

These facts do not establish Yeokcham novelty or superiority. Casey's principles
in the task/research draft are design inputs, not an independently verified
description of his implementation. Other external claims in the
[research draft](../../yeokcham-python-rewrite-research.md) are not automatically
verified or adopted.

The future lane experiment compares Git worktrees, Jujutsu workspaces, ordinary
directories with modest coordination scripts, and Yeokcham's workspace API. Use
equivalent automation/capture opportunities and replayable three-agent edits,
overlapping code/opaque files, one agent killed after acknowledged capture plus
later unacknowledged edits, coordinator restart and explicit selection/cleanup.
Repeat worker and capture-process failures separately. Count interventions,
contamination, incorrect preservation claims, time to inspect/recover/select,
storage and resource overhead. Do not run this experiment during design.

Proposed success threshold: every trial's preservation/privacy/identity checks
passes, no increase in operator mistakes, and at least 30% lower median owner
recovery/selection time than the best adapted baseline. This is an experimental
decision threshold, not a measured result. A new persisted lane identity also
needs a recurring requirement that workspace identity plus a small adapter cannot
express cleanly. Otherwise ship the API, not the additional primitive.

Reject any design that loses variants, hides accepted divergence, publishes
private inputs, counts a label as authority, overwrites unexpected edits, or
claims automatic capture without a functioning managed lifecycle. Reconsider the
product thesis if fair comparisons show no useful workflow advantage.

## 9. Owner decisions and D3 gate

Owner decisions remain open: approve the qualified product promise; Model A plus
selective acceptance; evidence-gated lanes; staged Python delivery preserving
review/archive/platform commitments; and the companion's persistence/compatibility
recommendations. Approval of a design is separate from authorizing a code tranche.

D1 acceptance requires each J1–J8 outcome/failure/next-action to be explainable,
the difference between candidate and accepted-head reconciliation to be clear,
and every existing-contract departure to be named. No runtime capability is
accepted merely by approving this text. D3 reviews both RFCs, closes blocking
schema/protocol questions, reconciles owner decisions and specifies the first
authorized implementation tranche. It does not automatically start a rewrite.

Owner-review checklist, still pending approval:

- [ ] Approve the qualified capture promise and all J1–J8 outcomes, limits and
  actionable failures; distinguish planned services from existing functionality.
- [ ] Approve independent continuation and exact subset acceptance while retaining
  explicit accepted-head reconciliation, privacy, authority and recovery.
- [ ] Accept or reject each named departure from existing gates/TC04/TC05/TC06;
  preserve review, native exchange, archive, retention and platform obligations.
- [ ] Agree on the minimal vocabulary, structured automation contract and fair
  three-agent experiment; require evidence before a new lane identity.
- [ ] Reconcile the staged Python sequence with P4/G01–G20 without beginning them.
- [ ] Complete D3's architecture/readiness review and separately authorize any
  subsequent code tranche. Product approval alone is not runtime verification.
