# Yeokcham V2 D3: architecture and readiness gate

**DRAFT / OWNER APPROVAL PENDING**

Review date: 2026-11-20, Singapore. Source HEAD:
`ecd6accd0cc496c3566c60f81b2785476116b6ca`.

## 1. Executive verdict

**BLOCKED** for a contract-frozen implementation handoff. Keep the proposed
Python/SQLite/immutable-object architecture, but do not start M0 or production
work from this review. An isolated baseline-documentation assignment could be
authorized independently; it would not close this gate.

The main blocker is semantic, not a preference about programming languages.
D2 section 6.3's global endpoint/common-base algorithm is insufficiently specified
for incremental candidates combined with other selections. Accepting A1 and then
A2 alone works in the worked graph. Adding an unrelated candidate can force the
comparison base backwards and turn the already represented A1 into a competing
edit. Arbitrary pairwise merge order is not an acceptable correction. See
[contract review section 3](D3_CONTRACT_FREEZE.md#3-candidate-and-acceptance-cases),
especially case 4b. This is a design counterexample, not an observed runtime bug.

Model A is still a reasonable product choice. Its independent evolution edge
and public content basis can express A2/B2 without merging siblings. It does not
yet supply a complete algorithm for interpreting represented contributions at
every acceptance target. **Do not claim that Model A has passed the complete
semantic gate.** Model B is a fallback to evaluate, not a proven solution to
incremental composition merely because changes receive different IDs.

Other blocking contracts are the general composition proof in the new public
protocol, exact private plan/action encodings, and destination ownership across
repository stores. SQLite DDL below demonstrates a feasible metadata skeleton;
it does not settle these meanings or qualify native filesystem operations.

## 2. Evidence, scope and limits

The starting tree was clean on `main`, with no nonignored untracked files.
Both requested D3 paths were absent. HEAD differs from D2's observed
`a61749f270ed1c65062f7c2845dc7fce261bbea5`; the intervening tracked delta adds
only the D1 and D2 RFCs. No fetch was made, so `origin/main` is a local tracking
observation. A SHA-256/mode manifest recorded all 515 pre-existing tracked and
nonignored untracked files before writing. Ignored build/dependency data was not
used as design authority or recursively inventoried.

Evidence classes used in both D3 files:

- **Observed:** commands and read-only source inspection in this D3 task.
- **Source:** behavior visible in code/tests; a test's existence is not a fresh pass.
- **Historical:** retained reports, with their original source and host limits.
- **Proposal / [Inference]:** architecture rules and predicted consequences.
- **OPEN:** an unresolved contract, with the dependent tranche prohibited.

Both canonical RFCs were read in full. Relevant approved contracts, V1 documents,
CLI/pilot design, implementation ledger/interfaces and P03 evidence were inspected.
Key source evidence includes:

| Evidence | What it establishes; limit |
| --- | --- |
| [Envelope registry](../../lib/yeokcham_envelope/yeokcham_envelope.ml), `object_type_code`, `make_prefix` | Codes 1–47 allocated, fixed Envelope-1 framing; no new code was registered |
| [Core codec](../../lib/yeokcham_v1_record/core_record.ml), `signature_domain`, `encode`, `id` | Actual body, signature, logical-ID and storage-ID distinctions |
| [Composition](../../lib/yeokcham_v1_composition/yeokcham_v1_composition.ml), `Graph.common_base`, `effective_base`, `reconciled_base` | Existing represented-predecessor and multi-parent checks cannot simply be deleted |
| [Selected share](../../lib/yeokcham_v1_local_service/native_share.ml), `prepare`; [integration](../../lib/yeokcham_v1_integration/yeokcham_v1_integration.ml), `selection_root` | Actual same-change fork gates intentionally proposed for change |
| [Publication proof](../../lib/yeokcham_v1_store/publication_receipt.ml), `proof`; [preservation](../../lib/yeokcham_v1_integration/preservation.ml), `basis`, `prepare` | Scoped private correspondence and known-present D/E mechanism |
| [Receipt](../../lib/yeokcham_v1_local_service/native_receipt.ml), `receive_with`; [state store](../../lib/yeokcham_v1_store/yeokcham_v1_store.ml), `store_with_history` | Nonapplying admission; current nested local metadata |
| [Native C](../../lib/yeokcham_snapshot/yeokcham_scan_stubs.c), `open_at`, `rename_at`; [safe apply](../../lib/yeokcham_v1_local_service/safe_apply.ml), `classify`, `entry_bytes_match`, `apply_with` | No-follow handles, exclusive/exchange displacement, complete-byte checks; not a Python binding |
| [Safety tests](../../test/test_safe_apply.ml), `crash_boundaries`, `concurrent_old_descriptor_edit`, `copyout_open_directory_writer`, `byte_verification_rejects_preserved_mtime_edit` | Relevant adversarial cases exist; they were read, not rerun |
| [Core vectors](../../test/generate_core_vectors.py), [composition vectors](../../tools/generate_composition_vectors.py), [goldens](../../test/golden/core) | Independent existing byte generators; the Core generator writes files and was not run |
| [P03 report](../implementation/reports/P03-attempt-01.md), [ledger](../IMPLEMENTATION_PROGRESS.md) | Scoped historical P1–P3 complete; P4 unstarted; only G01 complete as a full original phase |

The observed host is macOS 26.5.2 arm64, CPython 3.15.0, linked SQLite 3.54.1.
This differs from D2's Linux/3.14 host. It does not qualify the proposed Python
3.13/3.14 matrix. Official documentation was accessed for SQLite, Python,
native rename, service managers, candidate providers and Git/Jujutsu; citations
appear at the relevant contracts. No dependency was installed.

No OCaml build, runtime suite, full CI, accepted G01 benchmark, native destructive
experiment, service installation, public vector generation or agent experiment
was performed. The small external SQLite experiment checks the illustrative SQL
and transaction assumptions only; its exact checks and limitations are in
contract section 12. No live Yeokcham data was used.

`BASELINE-COPYOUT-20261116` remains unresolved. The exact historical test is
`test/test_benchmark_runner.py::RunnerTests.test_resume_preserves_samples_and_refuses_changed_inputs`;
linear and branching subcases reported
`installed target bytes changed at "restored" after application`.
The introduction revision and root cause are unknown. Historical P03 passing CI
and later incomplete CI are different evidence, not conflicting current results.

## 3. Owner-decision register

All five dispositions are **PENDING OWNER APPROVAL**. D28's earlier delegation
of defaults does not substitute for the five explicit V2 decisions in this task.

| Decision | Recommended default and qualification |
| --- | --- |
| A: quiet history, Model A, selective acceptance | Approve the qualified product promise and independent continuation. Approve selective selection with visibly disclosed dependency contents. Withhold algorithm freeze until case 4b and represented-versus-accounted-for cases have a deterministic solution |
| B: persistence | Approve SQLite plus immutable objects, DELETE/EXTRA initially. Require ordered publication, pins, consistent backup and measured contention; no database-only durability claim for external files |
| C: compatibility | Approve retained exact content identities plus new public controls and isolated stores. No implicit upgrade, old-control reinterpretation or wire interoperability; new schema/vector freeze remains a prerequisite |
| D: agents | Approve existing workspace IDs, ordinary directories and one typed API. No persisted lane or new authority primitive; require the fair experiment before reconsidering |
| E: migration and commitments | Approve sequential side-by-side development preserving review/archive/platform obligations. Every M-tranche still needs separate authorization and original-roadmap coverage accounting |

Approval of A–E would approve direction. It would not resolve the OPEN technical
fields by implication or authorize implementation.

## 4. Keep, revise and reject

| Disposition | Decision and reason |
| --- | --- |
| Keep | One pure typed domain and one application API; SQL owns private mutable facts; CAS owns immutable bytes. This avoids translating both V1 and Core aggregates |
| Keep | Capture/publication/receipt/acceptance remain different transitions. A public candidate can be recorded for transfer without being accepted or acknowledged remotely |
| Keep | Native preservation-aware application, per-workspace locks, short shared metadata commits and external custody. These protect different failure boundaries |
| Keep | DELETE/EXTRA as the first measured configuration; defer WAL, ORM, event sourcing, packs/deltas and virtual filesystems |
| Revise | Define S0 as already accepting R0 in the principal example. A merely published R0 is a different fixture with a different disclosed dependency effect |
| Revise | Distinguish material content basis, evolution, proof dependencies and acceptance provenance. An edge proving a conflict was considered must not prove its contents survive |
| Revise | Do not infer no-op, correspondence or safe tip elimination from graph reachability or equal snapshots. Every such reduction needs a role-specific proof |
| Revise | Burn an operation's reserved sequence in its Prepared transaction; never reuse it after cancellation. Cursor advancement still occurs only at capture/acceptance commit |
| Revise | A shared gate excludes GC, not concurrent SQL root release. Backup pins must be derived from the completed destination database while the gate remains held |
| Revise | Separate immutable action intent from mutable progress. Preserve pause origin and the Materialized boundary; a retry never replays writes after that boundary |
| Revise | Reserve destination prefix scopes as well as source workspaces. Per-source serialization alone does not cover two sources writing the same export tree |
| Reject | A generic endpoint merge as a complete Model A acceptance algorithm; ordered pairwise merges, timestamp winners, inferred ancestry and implicit all-sibling inclusion |
| Reject | Treating a root FK, verification flag or orphan signed object as proof of durable bytes or successful publication |
| Reject | Automatic history eviction, source overwrite fallbacks, plaintext keys, permissive required-policy fallback, implicit migration or a Python executable silently replacing `yeokcham` |

## 5. Product value, simplicity and package ownership

The intended ordinary experience remains initialize once, edit while healthy
capture runs, publish explicitly, receive without applying, and accept/reconcile
only when needed. A manual-save-only tool does not meet J1. An always-running
watcher without successful reconciliation and readiness does not meet it either.

The proposed advantage is an integrated capture/provenance/exact-selection/recovery
workflow. Git already offers shared-store independent working directories
([worktrees](https://git-scm.com/docs/git-worktree)); Jujutsu offers workspaces,
command-time capture, deferred conflicts and an operation log
([working copy](https://docs.jj-vcs.dev/latest/working-copy/),
[conflicts](https://docs.jj-vcs.dev/latest/conflicts/),
[operations](https://docs.jj-vcs.dev/latest/operation-log/)). Practical superiority
is unproved. Compare modestly scripted versions with matched capture cadence,+retention and visibility; count automation and verified restoration costs.

Keep facts, not a class/service/table for each noun:

| Responsibility | Representation/owner |
| --- | --- |
| Candidate group, current tips, accepted heads, conflicts, visible status | Queries over immutable admitted records and exact plans; no writable latest/accepted flags |
| Capture/history position | One immutable occurrence; workspace row owns the cursor and allocator |
| Public revision and shared candidate | One signed fact, not two parallel objects |
| Correspondence, request result, acknowledgement | Small authoritative facts: these cannot be regenerated reliably from arbitrary object files |
| Plan | Immutable private value plus roots; no second state tree |
| Operation/action | SQL intent and progress; no separately writable JSON journal |
| Process/run/test evidence | Private annotation tied to exact inputs; not a lane or approval |
| Heartbeat, dirty hint, trace, search/head cache | Disposable observations/derived data; never replay authority |

Recommended future package, not created here:

```text
python/src/yeokcham_py/
  domain.py       typed facts, role-specific graphs and pure transitions
  composition.py  exact byte/path composition and scope validation
  codec.py        bounded canonical profile, envelopes, typed IDs
  objects.py      immutable streams, durable create-only publication
  metadata.py     schema, transactions, roots, requests and operation facts
  native.py       narrow qualified filesystem/lock/flush binding
  workspace.py    observation, staging, classification and recovery executor
  security.py     trust evaluation and opaque custody adapters
  application.py one API coordinating those owners
  service.py     readiness, fair scheduling and hints through application
  transport.py   frozen public batches and verified receipt
  cli.py         arguments/presentation through application
```

`domain`/`composition` have no IO, SQL, clock, key or service dependency. Codec
does not admit records. Objects does not choose roots or accept work. Metadata
does not scan or sign. Workspace uses metadata operations and native/object
adapters, never transport. Application is the coordinator; CLI/service/IDE/agent
adapters cannot write SQL directly. Add archive only at its security-reviewed
tranche. Avoid introducing interfaces/factories solely to mirror this list.

## 6. Ranked risks and contract departures

| Severity | Risk / required closure |
| --- | --- |
| Critical B1 | Incremental multi-input composition and representation proof: solve case 4b, conflicting resolutions and rebases; freeze a deterministic reference algorithm before M1a public-composition consumers/M4 |
| Critical B2 | Public proof/authority/plan formats still OPEN: no signed V2 control bytes or interoperable consumer before schema and independently reviewed vectors |
| Critical B3 | Native action encoding and cross-store destination reservation not frozen/qualified: no filesystem-writing handoff before M2 gates |
| High | Object/SQL/GC and uncertain commit: validate real process faults and concurrent readers/publishers/collector at M1b; initial history eviction off |
| High | Existing copy-out failure: blocks old-runtime green/parity claims; Python M2 needs its own discriminating negative and positive cases, not a weakened guard |
| High | Sole authoritative DB loss and incomplete physical backup: distinguish history recovery from resumable operation bundles; preserve matching readers |
| High | Current admission, principal proof and private-cache disclosure: minimum custody/authority before M4/M5; required policy/adoption refuse until complete |
| Medium | Full scans, SQLite contention and service fairness may miss D2 budgets; measure and amend implementation, not fidelity |
| Medium | Unqualified Python/provider/platform matrix, especially Windows; native refusal is acceptable staging, not parity |
| Product | No measured advantage over adapted Git/jj; retain the falsifiable M6 experiment and willingness to reject a lane primitive |

Intentional proposals departing from approved V1/Core contracts are SQL private
metadata instead of TC05 immutable metadata-page/head CAS, raw loose objects before
TC05 compression/packs, new TC06 public controls/signature domains, Model A's
single evolution predecessor and selective acceptance instead of current all-head
gates, exact-old-source publication, and TC04 per-workspace application isolation
instead of repository-long writer ownership. D05's replacement of delivery by
integration is already approved product direction. No approved document is
changed here. Existing authority, scope, fidelity, private preservation, preview,
review, archive and retention obligations are retained.

## 7. Platform, service and security gates

Retain systemd user service and macOS LaunchAgent, with a foreground fallback;
Windows is a per-user login-started adapter, not a privileged root-style service.
Official service-manager documentation supports those lifecycle mechanisms, not
Yeokcham readiness ([systemd](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html),
[Apple](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)).
Readiness must identify the live protocol/process generation, supported store,
root attachment, first completed reconciliation and degraded/pending operations.
Registration alone is insufficient. No service is installed during D3.

Keep 500 ms debounce, attempts within 5 seconds under activity, 60-second namespace
reconciliation and daily rotating content audits as scheduling targets. Use two
CPU workers, four transfer requests and fair workspace queues. Avoid letting two
long asset scans occupy every slot indefinitely. Interrupted A remains excluded
from ordinary capture while B/C can progress. Human/key/network waits hold no
workspace/GC/SQL locks. These are proposed tests/budgets, not measured outcomes.

The qualification floor remains CPython 3.13; qualify 3.13 and 3.14 explicitly.
Require SQLite STRICT support (feature floor 3.37.0), FK/partial-index/backup and
flush functionality, verified pragmas and a reviewed exact build allowlist before
M1b. A feature floor is not approval of every newer library. The actual host's
3.15/3.54.1 experiment cannot supply that matrix. WAL stays off; if reconsidered,
also check SQLite's documented WAL-reset fixes and exact vendor backports
([WAL](https://www.sqlite.org/wal.html#the_wal_reset_bug)).

`cbor2`, PyNaCl/libsodium, optional python-zstandard and an audited small native
binding remain candidates. Freeze versions, source/wheel hashes, licenses,+supported wheels/architectures, strict parser resource bounds, signature negatives,
custody integration and native capability behavior before their consumer tranche.
Generic canonical CBOR mode is not the restricted Yeokcham decoder contract.
No dependency lock or production provider is approved by being named here.

Native Linux/macOS operations must preserve displaced nodes and verify bytes,
not just metadata. Windows has no qualified replacement binding in this review.
Network filesystems/cloud-synced live stores, same-user hostile-code isolation,
unsaved buffers, every intermediate write, global multi-file snapshot atomicity
and hardware-independent durability are outside the initial claim.

Public relay data remains visible to its operator; private backup is a separate
encrypted channel. No receipt executes project hooks/tests. Review and account
enrollment remain distinct from device possession and relay credentials.

## 8. M0 scope after gate closure and separate authorization

M0 is one bounded **baseline and reference-freeze** assignment, not M1a disguised
as a baseline. D4 must first dispose of B1 and the semantic parts of B2, or the
owner must explicitly authorize a smaller evidence-only assignment that makes no
freeze/readiness claim. A–E direction approval and a separate M0 instruction are
both required. This document supplies neither.

Future allowed additions only, after checking their absence:

```text
python/reference/README.md
python/reference/baseline.json
python/reference/semantic-cases.json
python/reference/protocol-v2.schema.json
python/reference/metadata-v2.sql
python/reference/vector-inventory.json
python/reference/qualification.json
```

One reviewed independent reference-vector script and its new vector directory
may be added only if the separately issued M0 scope explicitly includes them;
otherwise M0 records the inventory and leaves byte generation pending. Do not
silently expand the assignment to dependencies, native bindings, executable
entry points, service configuration or a Python product package.

Inputs: exact Git/source preservation manifest; D1/D2/D3 plus D4 disposition;
existing immutable content/control fixtures and independent generator source;
P03/ledger evidence; TC01/02/04–08 invariants; actual host/build capability facts.
Record old-code registry and all normative-fixture hashes. Do not run the
writing Core generator in place, recreate absent G01 outputs or rerun accepted
measurements. Read-only vector checks or external disposable copies are enough.

M0 outputs freeze: typed identities, supported exact content formulas, semantic
cases with selection/dependency/status distinctions, public/private departures,
schema decision register, independent-vector plan, platform fault assumptions,
budget fixture/host definitions and the named copy-out evidence gap. An OPEN
field stays OPEN and blocks its consumer; M0 cannot close it by choosing an
implementation opportunistically.

Acceptance requires one controlled diff limited to the authorized paths; unchanged
old source/vectors/evidence; machine-readable fixtures with expected results or
typed refusal; no placeholder expected hashes; independent review of any new
byte vectors; SQL constraint checks in external scratch; complete dependency and
platform gate lists; truthful BASELINE-COPYOUT disposition; and a matching
reference-reader/format ownership plan. No production module or user-data writer
is an acceptable M0 deliverable. No claims of quiet history, collaboration,
filesystem parity, migration or performance superiority.

Rollback: stop the assignment and preserve its reference artifacts for review.
Removing those newly authorized reference additions after inspection changes no
repository data format or user files. No source reset, old-reader removal,
fixture rewriting or active-data rollback. No commits/pushes unless a future
instruction separately authorizes them.

M1a/M1b/M2/M3/M4/M5/M6/M7a/M7b/M8 retain D2 section 16's order and evidence gates.
This sequence does not execute or close P4 or any G-phase. Map coverage to the
existing ledger when a future approved execution workflow permits ledger edits;
do not update that ledger now. Windows qualification work begins with M2/M3;
full review/archive remain M7 obligations, with minimum security before M4/M5.

## 9. D4 handoff and exact blockers

The next proposed design task is D4, only upon a separate instruction:

1. Resolve B1 using independently checkable reference cases, including case 4b,
   selected-versus-accounted variants, explicit rebases and shared/private
   correspondence after a resolved sibling. Accept a restricted model only with
   explicit product limitations; evaluate Model B if the correction becomes a
   provenance algebra larger than the product warrants.
2. Close B2's exact proof, authority carriage, private plan/request and parser
   bounds. Review proposed codes 48–51 against actual HEAD again. Generate no
   public protocol bytes until approved schemas have independent vectors.
3. Close B3's native intent encoding and cross-store destination-prefix ownership.
   Qualification tests can follow at M2, but implementation must not invent the
   safety contract. Preserve the known copy-out issue and its test guards.
4. Record A–E owner decisions without inferring approval, and then issue the
   bounded M0 assignment separately if the resulting gate allows it.

Readiness by capability: direction is suitable for owner review; isolated
reference research can be scoped safely; the advertised M0 contract-freeze handoff
is blocked; filesystem-writing and public collaboration code are not ready.
Sections marked FROZEN_FOR_REVIEW in the companion are stable review proposals,
not owner-approved specifications or experimentally proven guarantees.

## 10. D3 verification and repository handoff

The companion records the exact lightweight validation. Only the two requested
D3 documents are added. Existing tracked files and the 515-file preservation
manifest are checked again at closeout; no branch switch, commit, push, dependency
installation, production change, M0, P4 or G-phase is performed.

Documentation links/structure and a disposable SQL feasibility check do not
establish runtime preservation, native durability, public interoperability or
owner approval. The overall verdict remains **BLOCKED** until B1–B3 receive the
specified dispositions. No next action is authorized by this review.
