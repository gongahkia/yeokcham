/goal Complete G19: Collect full benchmark evidence and resolve measured regressions.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: BENCHMARK_DESIGN.md; TC04/TC05/TC08; D04/D19/D20.

Scope and ownership: Own benchmark execution/results and targeted performance fixes supported by measurements. Reuse G01 runners and pinned baseline exports; preserve all correctness contracts.

Acceptance criteria:

1. Run the selected ordinary source tiers and history-depth variations first, then monorepo and binary/asset tiers, including incompressible/already-compressed data.
2. Measure selected cold/warm samples, foreground/background interference, idle/session behavior, allocated storage, memory, transfer, and exact restore correctness with stated hardware and settings.
3. Compare equivalent retained histories/availability against the pinned baseline and relevant native Git operations with explicit commands. Unsupported operation comparisons are labeled, not invented.
4. Investigate reproducible regressions using the chosen thresholds; make targeted atomic fixes and rerun affected correctness/workload cases. Record any deliberate, evidence-backed tradeoff.
5. Commit small machine-readable summaries/manifests and a readable report; keep bulk fixtures/raw logs outside Git with locations/checksums.
6. Required full-tier runs cannot be replaced silently by smoke cases. If resources or a necessary runner are unavailable, keep this phase incomplete and return a concrete continuation/resource requirement.

Verification: Run fidelity/fault gates before interpreting timings and common checks after code fixes. Do not infer another OS's performance from the current machine.

Scope exclusions: No custom delta algorithm merely for novelty, discarded failing samples, shallower-history comparisons presented as equivalent, or unmeasured speedup claims.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
