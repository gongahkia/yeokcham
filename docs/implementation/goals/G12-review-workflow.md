/goal Complete G12: Implement native optional and required review workflows.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: REVIEW_WORKFLOW_DESIGN.md; TC06 evaluator; CLI_DESIGN.md review commands.

Scope and ownership: Own request/version/comment/review services, signed persistence/transport integration, and user-facing review/policy commands; reuse G03 evaluation and G08 transfer.

Acceptance criteria:

1. Implement open/update/show/list/comment/approve/request-changes/withdraw/close flows, with selected publication plus review opening in one action and immutable version-bound events.
2. Expose direct integration as the default policy and opt-in required approval with one independent member, renewed-approval opt-out, exact policy history, and warned administrator changes.
3. Bind interactive approval to the displayed version/context and require explicit version identity for noninteractive approval; never sign a floating latest replacement.
4. Preserve blocking feedback across updates and enforce withdrawal/concurrent-review/dismissal rules through the shared evaluator rather than duplicating policy logic in CLI handlers.
5. Test optional versus required review, both safeguards, stale coverage, another device of the author, offline queued reviews, and concurrent request versions. Provide clear next actions for missing review.

Verification: Run request/event/service/CLI/transport journeys and common checks. Offline tests must distinguish locally prepared from remotely observed records.

Scope exclusions: No mandatory web UI, code-owner/CI/merge-queue features, or bypass through direct integration flags.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
