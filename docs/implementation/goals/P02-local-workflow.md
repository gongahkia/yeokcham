/goal Complete P2: Implement the usable local-workflow pilot.

Work in /home/gongahkia/coding/projects/yeokcham. Complete P2 from docs/PILOT_PLAN.md. This does not authorize P3/P4 or completion of all G02-G20.

Read applicable AGENTS.md, then:
- docs/PILOT_PLAN.md
- docs/IMPLEMENTATION_WORKFLOW.md
- docs/IMPLEMENTATION_PROGRESS.md
- docs/implementation/INTERFACES.md
- docs/implementation/reports/P01-attempt-01.md
- docs/implementation/results/P01-acceptance.json
- docs/CLI_DESIGN.md
- docs/LOCAL_UNDO.md
- Relevant TC01/TC02 and TC05-TC08 in docs/TECHNICAL_CONTRACTS.md
- Relevant criteria in G03, G05, G06 and G14 goal files, without executing those full phases.

Verify current branch, worktree, HEAD and prerequisite ancestry before editing. Last inspected HEAD is 56eb13d271421720299d7e3f0dcd589d80b4d153 on clean main. Verify that P1's handoff and these implementation commits are ancestors:
- 51c374f499372349b235e68b32e7bf3e748d2718
- f900fbc3432e1d7134a547eda4f2ec7366d6c991
- 06b662a8bab5c783117e5fcf45e36b7d942cfc64

Inspect newer changes and preserve unrelated work. Save this scoped task under docs/implementation/goals/P02-local-workflow.md and record P2's starting revision/session in the ledger.

Objective: a person can initialize mixed text/binary work, understand changes, inspect exact history, create/select named branches, and recover earlier alternatives through supported CLI commands. Connect real domain behavior and durable state; command aliases or in-memory demonstrations do not satisfy this goal.

Start from the existing snapshot, undo, store, workspace, local-service, CLI specification/data/rendering and P1 Core modules. Reuse their boundaries and registry.

Acceptance criteria:

1. Implement useful status, history and diff.
   Show actual changed paths, readable text differences, opaque-file/type/mode changes, local branch/cursor and capture state. Support exact saved-state comparisons and working-tree comparison without publishing or advancing history. History must expose alternate continuations and unavailable contents truthfully. Structured output must contain domain data, stable identifiers and actionable outcomes rather than only a completion envelope.

2. Implement native exclusions and reliable capture.
   Follow TC07's root/nested .yeokchamignore glob, negation, escaping, precedence and parent re-inclusion rules, with ignore explain PATH. Never consult Git ignore configuration. Preserve mandatory metadata exclusions. Malformed rules and unsupported special files must produce actionable incomplete-capture results while retaining the last complete state. Implement necessary bounded instability retries and directory/file identity checks. Stream large files and preserve bytes, executable distinction, empty directories and symlink targets.

3. Wire P1 identities into durable local state.
   Generate workspace/branch/change identities and useful default names where these local workflows require them; ordinary users must not invent IDs. Persist workspace namespaces and monotonic history allocation atomically with history/cursor updates under the existing writer boundary. Handle restart, collision, exhaustion and identical retries. Preserve content identity versus history-position identity. Extend one authoritative state/history system rather than adding a competing parallel store. Full incremental paging/index replacement is not automatically required by P2; profile before replacing storage.

4. Implement actual branch list, branch create NAME and switch NAME.
   Use P1 branch identity and authenticated branch/accepted-version records, including the minimum causal-head handling and empty accepted genesis required by these operations. Initialization captures existing files privately; it must not implicitly accept or publish them. Shared branches must remain distinct from drafts and local undo continuations. Persist selection across restart. Switching must preserve private work and alternatives, or explain the exact conflict before replacement. Never silently choose a divergent head, retarget duplicate names, or label local undo nodes as shared branches.

5. Complete safe local selection and recovery.
   Reuse and harden verified materialization, safety roots, journals and restore proofs as needed for switch/undo/redo/restore. Preflight complete target contents, destination representability, ignored paths and untracked obstructions. Preserve noncolliding ignored files; refuse collisions explicitly. Missing/corrupt/unavailable targets must fail before replacement. Preview/cancellation must not move history or rewrite files. Interrupted application must resume the same operation without duplicate navigation or capturing a partial tree. Preserve unexpected external edits rather than blindly replaying or rolling back over them. Existing journal names alone are not evidence that these guarantees hold.

6. Deliver coherent CLI journeys and meaningful tests.
   Follow the scoped CLI design for help, generated names/IDs, preview and noninteractive behavior, structured outcomes and exit codes. Report watcher/service/backup state honestly; no managed-service or private-backup success claims.
   Exercise mixed text/binary work, A-B-C/return-B-D history, unsaved disk edits, equal contents at different nodes, branch creation/selection across fresh processes, ignored obstructions, unavailable targets, malformed rules, capture races and interruption at actual mutation/metadata boundaries. Include JSON and plain-text journeys. Reuse existing capture/undo behavior and resolve regressions.

7. Document exact delivered scope and remaining dependencies.
   Update actual APIs in INTERFACES.md and affected current-behavior guides. Track P2 coverage against original G03/G05/G06/G14 criteria without marking those whole phases complete prematurely. Explicitly distinguish local branch support from P3's shared exchange and integration loop.

P2 excludes remote clone/exchange, selected-publication redesign, shared-work integration/composition, review/account/archive services, managed background scheduling, compression/packs, Git carryover, GUI and AI features. Implement prerequisites genuinely needed for the local workflow, but do not start independent P3 features or fabricate unsupported-policy success.

Preserve accepted G01 measurements; do not rerun them. Reuse the existing toolchain if present. P1's environment was documented at /home/gongahkia/.cache/yeokcham-p1-20261114/environment.sh; verify availability before relying on it. Run focused affected tests, then make build, make lint and make ci. Record exact revisions, commands, exits, cached results and unavailable checks. Missing required P2 verification means incomplete.

Keep one writer on main. Make small coherent buildable commits using explicitly staged owned files. No agents, branches/worktrees, push, release or deployment. Preserve current work and recovery roots. D10 removes obsolete-format migration requirements, not current-data safety. Limit README edits to accurate additions or corrections of demonstrably outdated content.

Keep the ledger current. At closeout, audit every acceptance criterion, write docs/implementation/reports/P02-attempt-01.md using the report template, save compact acceptance evidence, and commit the report/ledger separately from implementation. Include exact commits, verification, rollback/data implications and remaining original-phase scope.

Stop after P2. Return its completion report, or a precise P2 continuation if incomplete. Do not start P3/P4 or generate the next /goal prompt; I will request it separately.
