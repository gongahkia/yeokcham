# Yeokcham implementation report: P03 — shared-workflow pilot

- Attempt: 01
- Status: complete
- Branch: main
- Session: `p3-shared-2026-11-15`; closeout November 16, 2026 (Singapore)
- Starting commit: `2c7329d3ee930a38d5e8654346fab5d28853c707`
- Final implementation: `2fe8b32e2014ee8f29d36ee2baafbc93d7176553`
- Implementation tree: `3106092977d0d75b0602de61968e2245d4d59f03`
- Design baseline: `d03ac1e095af7c896eede2334c5a1f5fc50c4e74`, with the separately scoped pilot delivery order.
- Predecessor: [P2 report](P02-attempt-01.md), [receipt](../results/P02-acceptance.json), handoff `2c7329d3ee930a38d5e8654346fab5d28853c707`, implementation `e181ff9ec863740ceb511fb888b23472056ebd15`.
- Also verified prerequisite ancestry: `c9c8f2509db2768279287a02724b69367777c9aa`, `822066fbf1f842c42d57a8586c78dfc2e399fd77`, P1 handoff `56eb13d271421720299d7e3f0dcd589d80b4d153`.
- Platform/toolchain: native Arch Linux x86_64, kernel `7.2.15-1-omarchy`, glibc 2.44; opam 2.6.1, OCaml 5.5.0, Dune 3.25.0, ocamlformat 0.29.0. OpenSSL, socat, SoftHSM, zsh and fish available through the existing environment.
- Scope: [P03 task](../goals/P03-shared-workflow.md); [compact acceptance evidence](../results/P03-acceptance.json).

## Delivered behavior

Two separately enrolled members can use native HTTPS clone and explicit foreground
exchange, share selected current disk contents with generated identities, inspect
exact plans, integrate offline, and exchange their accepted history. Receipt keeps
working files/private cursors unchanged. Selected branch contents are requested
before other advertised shared branches/history, including when an older courier
advertises the sender's selected branch first. The client then accounts for all
advertised closure; it cannot prove a relay disclosed every remote record.

Shared work and private continuations have separate results. Text composition uses
TC06's byte-preserving deterministic profile. Conflicts expose named exact versions,
absence/type/mode/content identities and bounded previews. Explicit shared choices
create authenticated scoped proposals; private choices stay in local plans. Defer,
preview and default cancellation accept no work. Confirmed integration persists its
operation before ordinary writes and commits acceptance/history/basis/outbound work
through the existing root. Restart and acknowledgement retries reuse exact identities.
No separate deliver action is required.

The final audit found two ordinary retry/update gaps and corrected them. A stored
resolution whose plan alias failed can now be selected by `resolution:RECORD_ID`
without a signer or its original replacement file; the failed attempt reports
`ok=false`, `outcome=interrupted`, exit 8. After concurrent revisions are explicitly
resolved and accepted, `share --update` can create their causal successor. It names
all old heads and uses an actual accepted base representing all of them. The share,
graph and private receipt reuse one predicate; an unresolved or one-sided base
still refuses. Selected sharing keeps unrelated private bytes outside public closure.

All automated member/signing journeys use explicit disposable test capabilities.
They establish the durable domain/CLI behavior, not native custody onboarding or
human usability. Required policy/review and unsupported adoption refuse explicitly.
No managed service, background completion or private-backup success is claimed.

## Acceptance evidence

| P3 criterion | Evidence and observed behavior | Result |
| --- | --- | --- |
| 1. Exact selected publication | `native_share.ml`, `publication_receipt.ml`, public `Package.Core`; 8 fresh share CLI cases, local-state share/witness/root-fault tests, public-closure tests and TLS successor journey. Generated IDs/titles, preview/current capture, scope/base/result/dependencies, ignore/type/deletion/mode/symlink behavior, identical recorded retries and private-sentinel exclusion. | passed |
| 2. Real native clone/exchange | `Native_clone`, `Sync.Core`, `Core_receive`, `Core_outbound`, HTTP V2 ranges and full 30-case transport suite. Prior enrollment/root pinning, destination/closure verification, requested-branch priority, all advertised shared history, frozen outgoing/ack retry, receipt with unchanged files/history, actual TLS access/integrity failures. | passed |
| 3. Deterministic composition/exact plan | `Composition.Line_hunks`, `Composition.Graph`, `Integration`, `Preservation`; profile golden/property cases, 15 graph cases, independent plan vectors and exact plan/local-state tests. TC06 limits/ties/line bytes, explicit ambiguous bases, exact context/observation/outputs and D/E preservation. Preparation accepts no history and performs no ordinary writes. | passed |
| 4. Recoverable integration/publication | `Native_integration`, `Safe_apply`, existing journals/proofs/root, 86-case local-state suite and 14 integration/5 recovery CLI cases. Exact confirmation/revalidation, all durable phases, actual mutation/journal/root boundaries, offline acceptance/outbound, signer-free resume, duplicate no-op, unrelated receipts and late external edits. | passed |
| 5. Conflicts/authority/offline heads | `Native_resolution`, record/model/trust and graph boundaries, two-person TLS text/opaque choices and private catch-up, all-head/equal-content/permutation cases, stored-file-choice retry. Shared R47 proposals and private decisions remain distinct. Unknown/revoked authority, unsupported required policy/evidence/adoption refuse; no fabricated approval. | passed |
| 6. CLI journeys/verification | Actual fresh Alice/Bob TLS clone/share/update/receive/resolve/integrate/subsequent exchange, mixed/large contents and private sentinels; domain JSON schema 2/plain/help/actions/exits, preview/cancel/stale/missing/obstructions, interrupted ranges/acks/files/root/outbound, restart/GC. Build/lint/CI and independent vectors pass. | passed |
| 7. Documentation/exact remaining scope | [Interfaces](../INTERFACES.md), [collaboration](../../COLLABORATION.md), [local recovery](../../LOCAL_UNDO.md), pilot/workflow/progress, this report and receipt. Current APIs/ordered schemas/registry, original-criterion coverage and rollback/data limits reconciled. | passed |

Named tests and source paths for every row are in the acceptance receipt. The
controlled TLS resolution journey now continues through a later update of the
reconciled change and exact retry, integration and nonapplying receipt.

## Verification

Use `. /home/gongahkia/.cache/yeokcham-p1-20261114/environment.sh` before the
repository commands. Its documented local opam switch and test dependencies were
reused. Full external logs and manifests are under
`/home/gongahkia/.cache/yeokcham-p3-20261115/`; no large fixtures/logs were committed.

The final runner started at `971bc2dd531549094811adcac8f3b4dbb0aca369` with nine
explicitly identified modified files. It hashed every tracked file, checked that
HEAD and source stayed stable throughout, and verified all 12 preserved hashes.
After committing `2fe8b32e2014ee8f29d36ee2baafbc93d7176553`, every tested tracked
hash matched that commit. Source manifest SHA-256:
`feb1d58823ba1a4f95033ef810f01dec967a02698c4392b795ef8b1ba496fb43`.
`p3-closeout-checks.json` SHA-256:
`558a7754205b26144674f29fb6a37e1062a93be8ffcc503d8f4d973446fbf0c4`.
The separate `p3-closeout-provenance.json` binds the exact implementation tree.
Subsequent handoff changes contain only documentation/report/evidence.

| Command/run | Exact source/evidence | Outcome |
| --- | --- | --- |
| `make build` | final source above; `p3-closeout-build.log` | exit 0, 5.570 s |
| `make lint` | same; `p3-closeout-lint.log` | exit 0, 1.080 s |
| `_build/default/test/test_composition_graph.exe` | same; `p3-closeout-graph.log` | exit 0; 15 cases |
| `python3 -B test/test_native_share_cli.py _build/default/bin/yeokcham_v1.exe` | same; `p3-closeout-native-share.log` | exit 0; 8 cases |
| `python3 -B test/test_native_integration_cli.py _build/default/bin/yeokcham_v1.exe` | same; `p3-closeout-native-integrate.log` | exit 0; 14 cases |
| `python3 -B test/test_native_recovery_cli.py _build/default/bin/yeokcham_v1.exe _build/default/test/native_recovery_fixture.exe` | same; `p3-closeout-native-recovery.log` | exit 0; 5 cases |
| `make ci` | same; `p3-closeout-ci.log` | exit 0, 266.460 s; freshly reported 25 OCaml suites/353 cases and 81 Python cases, no reported skips |
| Independent Python generators for Core records, composition/pages, Core package/courier, integration controls and local controls | five exact commands/log digests in receipt | all exit 0; golden files unchanged |
| `git diff --check` | final source and handoff docs | exit 0 |
| `make docs-check` | final handoff docs/report/receipt | exit 0; 273 local file references; exact log digest in receipt |

Fresh final CI includes 86 local-state, 15 Core package and all 30 transport cases.
The graph/CLI focused counts overlap CI and are not an additional unique-case
total. Dune reused valid matching results for unaffected tests. Earlier focused
checks at `c1f8032523069d4007f940e96e2cbe4bd90d68aa` passed 26 commands, including
Core model/record/trust, composition, transfer/workspace/journals/proofs, safe
apply, local state/package, CLI, selected TLS cases and independent vectors.
Their exact immutable source/log evidence is `p3-final-source-checks.json`;
the receipt links its digest. That filtered TLS run intentionally skipped other
cases; the final CI executed the full transport suite without reported skips.

The new graph regression first failed with the expected missing reconciliation
base; the first TLS extension then exposed the separate private receipt refusal.
Both are corrected with passing negative and end-to-end cases. Strict OCaml
fragile-match warnings and formatter-promotion exits were corrected before final
build/lint/CI. Earlier checkpoint failures/timeouts remain in the ledger and
external logs; no test assertion or validation was weakened to hide them.

Unavailable/excluded checks are explicit:

- Optional container targets were not executed: the Docker binary/socket exists,
  but this user cannot read the socket. Actual native local TLS relay tests passed.
- Native custody onboarding, a representative participant/project journey and
  broad responsiveness/performance qualification remain P4 work. No macOS/Windows
  or full power-loss/filesystem qualification is claimed.
- Accepted G01 measurements were not rerun and their absent artifact directories
  were not recreated. CI's existing small synthetic harness fixture is distinct
  from the accepted G01 baseline. All 12 README/predecessor/G01 hashes match.

No required P3 verification is missing.

## Commits and rollback

The table lists implementation commits in chronological order. Interleaved
report/checkpoint commits, all exact subjects and the complete changed-path list
are in the receipt. Fourteen externally created snapshots were inspected and
preserved; attribution does not imply this agent committed or pushed them.

| Implementation commit | Purpose |
| --- | --- |
| `2cb53993ec25951f959ff03021e01435e0a67879` | feat(core): compose exact byte changes and verify paged edit scopes |
| `869a328ef9c8bd3020c56cd84892814ad6294bab` | Accepted-result graph verification, signed local boundary and shared retention roots. External snapshot preserved. |
| `b4080389e539a347e827a5552f1c9d97fbe237b8` | Paged metadata and private publication-receipt foundation with registry allocation. External snapshot preserved. |
| `39db20671da7ea3ae3417d49b07568f7539f6552` | Private publication receipt fixtures. External snapshot preserved. |
| `6c58589ce79acb2d7814280f336932f166addcb0` | fix(store): verify scoped publication witnesses after private content GC |
| `9b119996ccb5f6445c324ecfc8b65dd664d38fca` | Selected native share service/CLI, captured exclusion rules and receipt witnesses. External snapshot preserved. |
| `3f0ed1ab3641bd6194e572cfc0d511b7d9235f78` | test(gc): tolerate existing object shards in corruption fixture |
| `14c6de8e63e9869de1d2f287aa7a93e99f48a1a4` | Private-work correspondence and composition preservation foundation. External snapshot preserved. |
| `57e0c2abd9d2f7058336ca0b4688db410c3826eb` | feat(core): expose causal change heads and bounded metadata reads |
| `41538b820676653f81b5e0faa3670d21c2d6ab18` | feat(integration): retain and revalidate exact private-preserving plans |
| `5f6039a8c4d85a86d8b5214910e67dd5579a6a36` | feat(store): bound typed object reads before allocation |
| `c9da48551a0fa7e30b5b55adf6add7998e703502` | feat(integration): journal safe local acceptance through the state root |
| `7d32acd8a548e3c7d53dd69b39a7dc44a0e489d5` | feat(cli): preview and confirm exact shared integration and resume |
| `e7b87673b218a3a39d486596959a3d8169e65070` | fix(cli): distinguish conflicted plans and incomplete capture outcomes |
| `8b37259e1089aaad48830fcb6feec461dfe22f48` | feat(integration): recover uncommitted plans with retained private alternatives |
| `2a0cc3650319c62ed0730447ffbd6ccd050a4989` | feat(cli): inspect and confirm private integration recovery choices |
| `fa6a89f90526def2ec7a2ed8be6f8db70b42e0a5` | fix(share): release signing locks and reserve recovery identities |
| `b0fe7049f8104789676b23f41f24af36c97733b9` | feat(pages): verify bounded scoped references for shared transfer |
| `1c5e66e9e6fc5a2fbc6e9fdfb54eca7402465094` | Public Core package/export foundation. External snapshot preserved. |
| `a65db94492923b5e6eaa2300e1d40a7e4c3a8222` | feat(package): verify public Core export and native hash vectors |
| `9f79f9dd6d0043eea3b696f429998117fe9444e4` | feat(receipt): atomically admit Core records without moving private work |
| `639553a236ab5c862a29a98bc9a63a430728b911` | Frozen Core outbound controls and acknowledgement foundation. External snapshot preserved. |
| `f6dd1e4a882fb4f9c38688e28ccf92870f7e360c` | Atomic receipt/outbound adapters and bounded native HTTP transfer support. External snapshot preserved. |
| `b78afa53278eef9b206c5b5133450c61039ea62c` | Native Core exchange service/CLI and enrolled-replica fixtures. External snapshot preserved. |
| `10210f528ea424dd0393f3b1d6755df4817de979` | feat(sync): verify native Core exchange and protect private cached contents |
| `94e08c0d3ad990dd52a642ca55390bcdb397d9d0` | Clone guards, credential realm and local activation prerequisites. External snapshot preserved. |
| `766bc88a32bf703553746964b7abf5057d30d640` | Native package selected-content priority and exchange plumbing. External snapshot preserved. |
| `01a54f728fa4484fede320dca7cdb914cfda7ec3` | Verified safe-application support needed by clone. External snapshot preserved. |
| `37311de153d7e9fb91321c99f44ec3f5c300ec73` | Native clone implementation and public sync APIs. External snapshot preserved. |
| `1105c60c8e724b9e49abf9f021b890207f4844e5` | feat(sync): materialize verified native clones with durable resume |
| `bc75d492af15bb8e83bd863d7aceaef370a54c35` | feat(branch): select received work and preserve private branch bases |
| `07ead3a737996ee726d160590adf02766538b3c2` | feat(inspect): retain saved metadata visibility when public contents fail verification |
| `36759aa6150abb2d4b84c75a997a3c9a323e3609` | feat(core): verify exact public resolutions through native accepted application |
| `51a63028250fa987ff870d959294347e0e3ee593` | feat(cli): prepare exact shared and private conflict choices |
| `c1f8032523069d4007f940e96e2cbe4bd90d68aa` | Two-person TLS resolution, requested-branch priority, precise HTTP/integrity/paused outcomes and private-decision GC tests. External snapshot preserved. |
| `971bc2dd531549094811adcac8f3b4dbb0aca369` | fix(cli): recover recorded resolution choices without source files |
| `2fe8b32e2014ee8f29d36ee2baafbc93d7176553` | fix(share): update changes after accepted revision reconciliation |

Rollback review order is the reverse of this exact table, also stored as the
receipt's `rollback_order`: start with
`2fe8b32e2014ee8f29d36ee2baafbc93d7176553`,
`971bc2dd531549094811adcac8f3b4dbb0aca369`, then review
`c1f8032523069d4007f940e96e2cbe4bd90d68aa` and earlier dependencies. Use reviewed
`git revert` operations only if rollback is separately requested. External
snapshots and dependent changes can require hunk-level handling/conflict resolution;
a blind range revert is not a current-data recovery procedure. No rollback was run.

Registry codes 44/45/46/47, metadata pages/receipts, operation/recovery/outbound/
clone wrappers and private-plan schema 2 are current durable data. Older binaries
may refuse them, including authenticated R47 records. Preserve a matching reader,
current roots, history, safety/displaced contents, operation journals, proposal
aliases and restore proofs. Reverting source does not undo materialized files,
accepted history, a remote courier, transfer acknowledgements or published data.
Do not delete roots or replay/roll back over unexpected edits to make an older
binary appear usable. D10 does not waive those current-data requirements.

The report/ledger are committed separately from implementation. Obtain that
handoff hash with `git log -1 --format=%H -- docs/implementation/reports/P03-attempt-01.md`;
the final response supplies it without amending the report.

## Design and interface notes

[INTERFACES.md](../INTERFACES.md) documents actual signatures and ordered schemas.
One envelope registry remains authoritative: P1 signed kinds 41–43 are unchanged;
44 is exact edit scope, 45 metadata pages, 46 private integration plan and 47
signed resolution revision. R47 reuses bounded canonical envelope/signature/trust
machinery and binds all exact superseded variants, accepted/chosen context,
comparison, scope and replacement. Acceptance recomputes its actual result.

Plan 46 schema 1 remains byte-stable when no private choices exist; schema 2
adds canonical private workspace decisions. Those choices are not public R47
records. Native package/courier/outbound/clone consumers extend the existing
store/root/transport boundaries rather than creating a competing state system.
Private publication witnesses prove only selected correspondence and do not pin
an old unselected private blob forever. Independent operation/proposal/proof
roots protect required replacement contents across GC and resume, then retire
appropriately after completion/release.

`Graph.reconciled_base` is the common proof for a successor after accepted fork
reconciliation. It verifies exact recorded base bytes and every predecessor;
private publication receipts use the same rule. Stored `resolution:ID` choices
recover plan retention without rereading an unavailable external input. Neither
operation invents a winner, new acceptance or new signing identity on retry.

There is no new policy waiver. This pilot rejects unsupported required policy,
review evidence and adoption. Ambiguous common bases remain explicit decisions;
sorting stabilizes sets rather than selecting a winner. Automatic repair of an
already incomplete/corrupt admitted store is unsupported: read-only metadata
inspection is available, and all writers require complete validation. Public
missing/corrupt targets report unavailable/integrity; private-control loaders
without typed distinctions conservatively report unverified/integrity.

## Scope and worktree audit

- The receipt lists all 128 changed paths across P3, including this handoff.
  They cover Core/composition/pages/plan/store/GC/services/package/transport/sync,
  CLI/rendering/spec, focused tests/vectors/generators and current guides/ledger.
- README changes: none. Accepted G01 measurements/reports and P1/P2 handoffs are
  preserved; all 12 recorded preservation hashes match.
- Initial P3 worktree was clean on main. Externally committed in-scope snapshots
  were inspected/preserved; no reset, amend, rebase, stash, branch/worktree,
  agent delegation, push, release or deployment was issued by this agent.
- At implementation commit `2fe8b32` the worktree was clean. The separate handoff
  contains only the explicitly staged documentation/report/receipt paths; final
  worktree status is checked after its commit.
- Disposable repositories, signing directories, replacement files and full logs
  remain external to Git under temporary directories/the external evidence cache.
  No live user repository was used for destructive fault/GC experiments.
- Scope excludes P4, full review/account/archive/backup/services, managed scheduling,
  compression/packs, independent history/index replacement, Git carryover and GUI/AI.

## Remaining work and next handoff

No P3 criterion remains open. P0/P1/P2/P3 pilot slices are complete; the original
full-design completion count remains **1/20 (G01)**. P3 coverage does not complete
any entire G02/G03/G04/G08/G13/G14 phase or bypass its real prerequisites.

| Original criteria | Delivered pilot coverage | Remaining original-phase scope |
| --- | --- | --- |
| G02 C1-C5 | Core revision/accepted/branch/resolution records, scope/page/plan contracts and vectors; durable pilot identities/consumers. | Request/principal/member/policy/review/account/settings/archive families, principal proof and remaining consumer contracts/vectors; original phase stays partial. |
| G03 C1 | Existing enrolled-device trust and current authority reused. | Principal-key proof and stable independent-reviewer binding. |
| G03 C2 | Causal branch/accepted heads, explicit all-head reconciliation, equal-content histories and current admission. | Full policy-fork evaluation, authority reconciliation/adoption workflows. |
| G03 C3-C5 | Unsupported required policy/evidence/adoption refuses; unknown/revoked authority and receipt permutations tested. | Independent approval defaults, exact coverage/preferences, reviewer supersession/withdrawals/blocks/dismissals and full matrix. |
| G04 C1-C5 | TC06 profile, actual graph/base/scope/dependency proof, exact plans, separate D/E, ambiguity decisions, golden/property/side-effect/stale tests. | Full G03 policy/review evidence evaluator and original predecessor/phase acceptance. |
| G08 C1 | Core revisions/branches/accepted/resolutions and verified closure through real bounded HTTPS ranges. | Full policy/review record families and original-phase dependencies. |
| G08 C2-C3 | Durable frozen outgoing/ack and exact retries; requested version prioritized before all other advertised shared branches/history. | Configured narrower scopes and full-scale qualification. |
| G08 C4-C5 | Current trust, preserved incomparable heads/private cursor/files, actual received-branch offline selection and availability/fault/receipt tests. | Full adoption/policy behavior, repair of already incomplete local state and wider qualification. |
| G13 C1-C6 | Native no-review pilot acceptance/private preservation, actual safe journal phases and root publication, offline/idempotent recovery and native conflict/operation CLI; no mandatory deliver. | Full G12 required/advisory review integration, broader platform/fault qualification and original prerequisite/phase acceptance. |
| G14 C1-C6 | P2 local journeys plus native shared clone/share/update/exchange/integrate/conflicts/recovery; domain JSON/plain/confirmation/actions/exits; honest service/backup state. | Archive/preferences/full-review vocabulary, managed services and native custody/human qualification; original phase remains pending. |

P4 is next eligible and unstarted. It requires a separately invoked task selecting
an actual native pilot host/project and participant journey, native custody/setup
verification, representative responsiveness/fault/handoff work and real feedback.
The task source is the P4 row in [PILOT_PLAN.md](../../PILOT_PLAN.md), not an
independent full-phase prompt. No next goal prompt was generated or executed.
The next agent must verify this report/receipt, implementation `2fe8b32`, the
separate handoff commit, preserved prerequisites and actual worktree/data state.
