/goal Complete G14: Complete native workspace and ordinary CLI journeys.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: CLI_DESIGN.md; TC01/TC02/TC05-TC07; D26.

Scope and ownership: Own init/clone/status/history/diff/share/branch/switch/undo/redo/restore command integration, CLI spec/data/rendering, and workspace services, consuming the already implemented domain APIs.

Acceptance criteria:

1. Implement the agreed small command vocabulary and normal help path, with status distinctions for local capture/private backup/publication/acceptance/offline coverage.
2. Make init capture existing files privately from an empty accepted genesis; make native clone verify/materialize the selected version and report remaining background coverage.
3. Implement explicit selected publication, exact-version update, branch/switch/private-work preservation, and useful local/archived branching history navigation.
4. Apply the documented confirmation, --preview, --yes, --plan, noninteractive selection, JSON schema, pagination, and exit-code rules consistently. Do not turn a success envelope into a substitute for domain data.
5. Test complete text/opaque-file normal and recovery journeys, untracked/ignored obstructions, unavailable offline versions, safe cancellation, and meaningful next actions.
6. Mark service-dependent scheduling truthfully until G15/G16 land; no fake running service or backup success. Feature-specific CLI behavior from earlier phases must continue to work.

Verification: Run CLI spec/data/golden and end-to-end workspace journeys plus common checks; use semantic assertions rather than freezing every sentence.

Scope exclusions: No GUI, Git import, redundant delivery command, speculative README claims, or source-code-only assumptions.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
