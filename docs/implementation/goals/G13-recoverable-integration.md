/goal Complete G13: Implement exact recoverable integration and remove delivery friction.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: TC01/TC02; TC06 composition, authority, and journal; D05/D06/D18/D21.

Scope and ownership: Own local integration service, journal/materialization adapters, accepted-history publication, and integrate/resolve CLI paths. Use G04 plans, G05 fidelity, G06 roots, G08 outbox, and G12 review services.

Acceptance criteria:

1. Apply one exact validated plan with separate accepted and private-workspace results; preserve the shared-D/private-E case and block incompatible private work before ordinary application.
2. Implement Prepared/Applying/Materialized/Committed/Completed/Paused states, stable plan-to-operation identity, displaced-entry preservation, and atomic accepted/history/outbox metadata publication.
3. Handle stale preview/policy, external writes, interruptions, disk failure, and retry without duplicate acceptance, blind rollback, or loss of private data.
4. Integrate offline using verified local records, retain competing heads, and require explicit reconciliation under current review/confirmation policy.
5. Replace the mandatory deliver transition with integration while accounting for baseline, included revisions, draft bookkeeping, decisions, and provenance. Successful integration needs no further delivery action.
6. Wire useful text/JSON plan, conflict, operation-resume/recovery, and acceptance outcomes. Remove obsolete paths/fixtures as appropriate without building old-artifact compatibility.

Verification: Run plan/service/restore-proof/journal/CLI fault tests at every transition and receipt-order/offline scenarios plus common checks.

Scope exclusions: No acceptance of live worktree bytes without composition proof, automatic remote-triggered application, or unprotected concurrent overwrite.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
