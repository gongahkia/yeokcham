/goal Complete P3: Implement the shared-workflow pilot.

Work in /home/gongahkia/coding/projects/yeokcham. Complete P3 from docs/PILOT_PLAN.md. This does not authorize P4 or completion of all G02-G20.

Read applicable AGENTS.md, then:
- docs/PILOT_PLAN.md
- docs/IMPLEMENTATION_WORKFLOW.md
- docs/IMPLEMENTATION_PROGRESS.md
- docs/implementation/INTERFACES.md
- docs/implementation/reports/P02-attempt-01.md
- docs/implementation/results/P02-acceptance.json
- P1's report/receipt where needed for canonical records and trust boundaries
- docs/CLI_DESIGN.md
- docs/COLLABORATION.md
- docs/LOCAL_UNDO.md
- Relevant policy requirements in docs/REVIEW_WORKFLOW_DESIGN.md
- TC01/TC02, relevant TC03 identity boundaries, and TC05-TC08 in docs/TECHNICAL_CONTRACTS.md
- Relevant criteria in G02/G03/G04/G08/G13/G14 goal files, without executing those full phases independently.

Verify branch, worktree status, HEAD and prerequisite ancestry before editing. Last inspected HEAD is 2c7329d3ee930a38d5e8654346fab5d28853c707 on clean main. Verify these are ancestors:
- P2 handoff: 2c7329d3ee930a38d5e8654346fab5d28853c707
- Final P2 implementation: e181ff9ec863740ceb511fb888b23472056ebd15
- Selection intent/journals: c9c8f2509db2768279287a02724b69367777c9aa
- Recovery copy integration: 822066fbf1f842c42d57a8586c78dfc2e399fd77
- P1 handoff: 56eb13d271421720299d7e3f0dcd589d80b4d153

Inspect newer changes and preserve unrelated work. Save this scoped task under docs/implementation/goals/P03-shared-workflow.md and record P3's starting revision/session in the ledger.

Objective: two separately enrolled members can share selected work, obtain a usable verified workspace through a native remote, exchange updates, preview and integrate exact shared work, resolve conflicts, and recover interruptions without exposing private work or duplicating acceptance. Deliver supported CLI journeys backed by actual durable domain behavior.

Inspect and reuse the existing model/Core, record/Core, trust, projection/proposal, package, transfer, transport/HTTP, bootstrap, workspace, store, local-service, CLI and P2 safe-application boundaries. Verify committed behavior rather than treating existing code or journal names as acceptance evidence. Maintain one authoritative registry and mutable state-root system.

Acceptance criteria:

1. Implement exact selected publication.
   Support share [PATH...], generated change/revision identities and useful default titles, --title, --preview and explicit --update CHANGE according to the scoped CLI design. Capture current disk contents without requiring a manual save.
   Construct the public result from the declared shared base and selected changes. Validate scope/base/result correspondence, dependencies, deletions, directory/type/mode/symlink changes and native exclusions.
   Export only declared public records and their verified dependency closure. Never copy the whole private store or include unrelated private contents, undo ancestry, credentials or recovery material.
   Persist publication-to-local-history correspondence for subsequent private-work preservation. Retrying a recorded publication must reuse its logical identity; another explicit update creates a new immutable revision.

2. Deliver one real native clone/exchange path.
   Implement clone URL [DIRECTORY] through the existing native relay/transport stack, with documented trust, enrollment and credential prerequisites. Clone must verify repository identity, authority, selected branch/version and complete target closure before supported materialization into a new/empty destination.
   Clone is not authority to enroll a member or bypass identity verification. Ordinary users must not construct internal record IDs or manifests manually.
   Wire explicit publication transfer and receipt/retry through actual CLI commands. Offline packages may remain useful, but package-only demonstrations do not satisfy native clone/exchange.
   Reuse bounded streaming, missing-object inventory and resumable transfer mechanisms. Default shared coverage follows TC05: prioritize the selected version and account honestly for other shared branches/history.
   Report verified local closure, missing contents, pending outgoing work and remaining coverage separately. Receiving records may update known shared metadata/head sets, but must not integrate, rewrite working files, move a private cursor or execute project commands.
   No fabricated background download/service success: foreground transfers and explicit resume are acceptable while managed scheduling remains outside P3.

3. Implement deterministic composition and an exact integration plan.
   Follow TC06 line-hunks-v1 exactly: whole-path rules, deletion-first LCS tie-breaking, byte-preserving line endings, deterministic bounds, insertion/replacement boundary conflicts and explicit opaque-file decisions.
   Resolve dependencies and recorded common bases without arrival-order winners. Reject scope/base/result mismatches; ambiguous correspondence or merge bases require a decision.
   Bind repository, target branch/accepted heads, chosen exact revisions/resolutions, relevant authority/policy/evidence, workspace identity/cursor/basis/observation, accepted result, private workspace result and composition profile into a canonical plan identity.
   Preparation may stage immutable objects but must not advance accepted history, publish acceptance or rewrite ordinary files.
   Support the shared-D/private-E case: accept D while retaining compatible later private E, without accepting E or replaying D twice. Incompatible private edits must produce explicit workspace conflicts before replacement.

4. Implement actual recoverable integration and accepted-history publication.
   Support integrate CHANGE..., contextual selection when omitted, --all, preview/default cancellation, --yes and --plan ID. Revalidate relevant inputs after confirmation; changed inputs require a fresh plan. Unrelated receipts must not automatically invalidate the plan or be erased by publication.
   Replace P2's empty/fork-only accepted-result restriction only through real composition, scope, dependency and authority validation. A valid signature alone is not proof of a valid accepted result.
   Persist plan-to-operation identity before the first ordinary-file mutation. Implement TC06's Prepared/Applying/Materialized/Committed/Completed/Paused facts, using P2's verified staging, identity checks, displaced-entry preservation and recovery roots.
   Atomically publish the accepted-version record, branch/basis/history updates, operation token and durable outbound work through the existing state root. Remote availability must not be required for the local commit.
   Resume the same operation after interruption or lost acknowledgement without another acceptance, navigation step or partial-tree capture. Already accepted work must produce an honest no-op.
   Preserve unexpected external edits, including edits after materialization. Never blindly replay or roll back over them. Do not hold writer locks across network requests or human confirmation.
   Successful integration must require no separate deliver action.

5. Make conflicts, authority and concurrent offline work explicit.
   Provide useful conflicts/resolve and operation inspection/resume/recovery commands following CLI_DESIGN.md. Users must be able to inspect named versions, defer, choose exact contents or supply a replacement, then prepare a fresh integration.
   Resolution alone must not silently integrate or publish unrelated private work.
   Preserve incomparable accepted/branch heads, including equal-content histories, across opposite receipt orders. Explicit reconciliation must name all heads it reconciles; --yes must not choose a divergent head.
   Enforce the authority/policy subset genuinely needed for this pilot. Keep required review opt-in and advisory behavior honest. Unsupported required policy, missing approval, unknown/revoked authority or unsupported adoption must refuse explicitly; never silently default them away or fabricate approval.
   Implement necessary prerequisites rather than weakening contracts, but do not start independent full review/account services.

6. Deliver coherent CLI journeys and meaningful verification.
   Use actual domain JSON, stable identifiers, exact plan/operation IDs, actionable next actions, documented exit codes and appropriate coverage/status distinctions. Update ordinary help for the delivered workflow while preserving P2 local journeys.
   Test separate Alice/Bob workspaces and fresh CLI processes through a controlled local native relay: selected share, verified clone, edit/update, transfer, receipt without file mutation, preview, integration and subsequent exchange.
   Include:
   - unselected private sentinel contents absent from exported closure;
   - D shared / E private preservation and overlapping private conflicts;
   - repeated lines, CRLF, final newlines, ambiguous bases and composition limits;
   - mixed text/binary, executable, symlink, directory and large streamed contents;
   - explicit text/opaque conflict resolution and safe deferral;
   - stale plans, cancellation, ignored/untracked obstructions and unavailable targets;
   - offline integration, divergent heads and receipt permutations;
   - interrupted transfers and lost acknowledgements;
   - interruption at actual file, journal, metadata-root and outbound-publication boundaries;
   - external edits, restart, duplicate requests and protected recovery/GC roots.
   Use disposable explicit signers only where appropriate for automated tests and report that limitation. They do not prove native custody onboarding or human usability.

7. Document delivered scope and remaining dependencies.
   Update actual APIs, ordered schemas, registry entries, invariants and consumers in INTERFACES.md. Update affected collaboration/current-behavior guides and reconcile stale handoff text.
   Record exact P3 coverage against original G02/G03/G04/G08/G13/G14 criteria without marking whole phases complete prematurely.
   Distinguish completed local acceptance, transfer acknowledgement, known shared heads and current working contents. Preserve the distinction between library support, automated journeys and later native/human product qualification.

P3 excludes P4's representative human evaluation and broad performance qualification, private account/archive/backup services, full review UI/services, managed scheduling, compression/packs, independent history/index replacement, Git carryover, GUI and AI features. A controlled disposable local relay is authorized for testing; hosted deployment is not.

Preserve accepted G01 measurements; do not rerun them or recreate missing benchmark artifacts. Reuse the existing toolchain after checking availability:
  /home/gongahkia/.cache/yeokcham-p1-20261114/environment.sh
Invoke repository-local tools through opam exec as documented. P2 had no Docker socket access; inspect the current environment, use real local relay processes where sufficient, and record unavailable optional container checks truthfully.

Run focused affected model/composition/record/trust/transfer/package/workspace/service/journal/CLI tests, then make build, make lint and make ci with documented test dependencies. Record exact revisions, commands, exits, cached results and unavailable checks. Missing required P3 verification means incomplete.

Keep one writer on main. Make small coherent buildable commits using explicitly staged owned files. No agents, branches/worktrees, push, release or deployment. Preserve existing work and recovery roots. D10 removes obsolete-format migration requirements, not current-data safety. Limit README edits to accurate additions or corrections of demonstrably outdated content.

Keep the ledger current. At closeout, audit every criterion, write docs/implementation/reports/P03-attempt-01.md using the report template, save docs/implementation/results/P03-acceptance.json, and commit report/ledger separately from implementation. Include exact commits, verification, rollback/data implications, remaining original-phase scope and any actual blocker.

Stop after P3. Return its completion report, or a precise P3 continuation if incomplete. Do not start P4 or generate the next /goal prompt; I will request it separately.
