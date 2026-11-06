/goal Complete G11: Implement automatic private retention and inherited settings.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: TC03 retention/settings; TC04 disk pressure; TC05 accounting; D13-D15.

Scope and ownership: Own personal settings/causal conflict reduction, retention selection, pin state, quota reporting, and safe archive-backed local cleanup integrated with G06/G07/G10.

Acceptance criteria:

1. Implement the 30-day preference, 5-GiB per-repository target, and 20-GiB per-account-per-device target with built-in/account/repository inheritance and effective-source inspection.
2. Implement causal per-key settings and conservative same-key conflict behavior, keeping team policy and device-local credentials separate.
3. Evict only verified archived unprotected contents, respecting oldest-use ordering, shared coverage, current work, pins, pending uploads, active readers, and recovery roots.
4. Synchronize owner pins and expose pending downloads; preserve history index/ancestry for archived contents and fetch/verify before restoring.
5. Test conflicting settings, aggregate quota enforcement, unavailable/full remotes, smaller budgets, current/pinned overages, local disk exhaustion, and retention/recovery races. Report inability to meet a target truthfully.

Verification: Run settings/retention/GC/archive integration tests with controlled time/capacity and common checks; do not replace production defaults with tiny test values.

Scope exclusions: No sole-copy deletion, automatic remote expiry, silent shared-history eviction, or unsafe user-specific config from shared files.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
