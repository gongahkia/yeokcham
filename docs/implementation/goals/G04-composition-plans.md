/goal Complete G04: Implement deterministic composition and exact integration plans.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: TC01/TC02; TC06 line-hunks-v1 and private-work correspondence.

Scope and ownership: Own a pure composition/plan module and golden cases, using G02 records and G03 policy evaluation. Start with model/projection/proposal interfaces; keep filesystem application out of this phase.

Acceptance criteria:

1. Implement exact whole-path and line-hunks-v1 rules, deterministic alignment tie-breaking, size/cell limits, byte-preserving line endings, and explicit opaque-file decisions.
2. Resolve dependencies and common bases without order-dependent conflict winners; reject mismatched declared edit scope/base/result and ambiguous merge bases.
3. Produce a canonical plan binding exact shared inputs, policy/review evidence, workspace observation/basis/cursor, accepted result, private workspace result, and composition profile.
4. Implement the shared-D/private-E preservation case without double-replaying shared work or including E in acceptance. Missing/ambiguous correspondence is a decision, not a guess.
5. Demonstrate that preparation has no filesystem/head/publication side effects. Golden/property tests cover repeat lines, CRLF, deletions, insert boundaries, opaque replacements, independent changes, private overlap, and stale inputs.

Verification: Run composition and plan golden/property tests, existing affected model/proposal regressions, and common checks.

Scope exclusions: No file writes, journal execution, transfer-triggered integration, or AI merge dependency.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
