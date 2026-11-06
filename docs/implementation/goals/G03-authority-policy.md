/goal Complete G03: Implement causal authority, member identity, and review-policy evaluation.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: TC06 branch/policy concurrency and review evaluator; REVIEW_WORKFLOW_DESIGN.md; D18/D23-D27.

Scope and ownership: Own pure membership/principal binding, policy/event evaluation, branch-head reduction, and their tests. Extend G02 interfaces and existing lib/yeokcham_v1_trust/ and model modules; keep transport/UI adapters separate.

Acceptance criteria:

1. Implement stable principal/device binding with proof of the principal key and administrator authority, so additional devices do not count as independent reviewers.
2. Implement causal branch/policy head sets and conservative policy-fork evaluation, with explicit authority reconciliation and exact late-arrival adoption. Arrival order and timestamps cannot select a winner.
3. Implement one-independent-approver default, exact review context, preserved approval across unrelated changes, changed-content invalidation, and the authorized renewed-approval opt-out without fabricating review.
4. Implement reviewer-event supersession, concurrent reviewer decisions, withdrawals, persistent blocking requests, and explicit administrator dismissal reasons.
5. Test all combinations of optional/required review, confirmation preferences, renewed approval, missing/revoked authority, author identity, and permutation of receipt order. Authority adoption must never waive effective review policy.

Verification: Run pure model/trust/policy tests and permutation/property cases plus common checks. Publish evaluator APIs for G12/G13.

Scope exclusions: No interactive review UI, HTTP endpoints, hidden CI gates, code-owner hierarchy, or automatic acceptance.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
