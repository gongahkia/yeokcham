/goal Complete G20: Verify the complete design and close the implementation ledger.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: D01-D29; TC01-TC08; all five design documents and implementation reports.

Scope and ownership: Own final requirement-to-evidence audit, cross-platform/packaging/self-hosted journeys, unresolved regression fixes, and current-behavior documentation. No publishing/deployment is authorized.

Acceptance criteria:

1. Audit every agreed requirement/default against actual implementation and all phase reports. Resolve missing integration paths, stale claims, TODO stubs, and unjustified design drift.
2. Run required build/lint/test/doc/workflow checks and relevant package/container/self-hosted smoke checks using documented targets and disposable services.
3. Obtain native macOS, Linux, and Windows evidence on the identified candidate revision, plus genuine nontechnical comprehension evidence. If a required host/participant is unavailable, report the precise remaining gate and keep the overall project incomplete.
4. Reconcile G19 performance evidence with any later fixes; revalidate affected claims rather than reusing results for changed code. Distinguish source-only/doc-only follow-ups from runtime changes when recording tested revisions.
5. Ensure private recovery after all-device loss, complete backup before eviction, concurrent offline integration, required-review/opt-out boundaries, and source/document/binary fidelity all have reproducible evidence.
6. Close tracker and coverage gates only when substantiated, list all atomic commits and rollback dependencies, and provide a final implementation report. If gaps remain, return a scoped continuation of G20 or the defective earlier phase.

Verification: Use make ci and the applicable Makefile platform/package/container targets; verify actual native runs and reports. No synthetic success counts or unexecuted test claims.

Scope exclusions: No push, release publication, production deployment, broad README rewrite, or marking the project complete because every agent returned a report.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
