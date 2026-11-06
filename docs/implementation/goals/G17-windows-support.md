/goal Complete G17: Implement Windows support immediately after macOS/Linux service work.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: D11/D20; TC03-TC07; CLI_DESIGN.md.

Scope and ownership: Own Windows watcher/filesystem/materialization/custody/login-service adapters and portable build/runtime changes, maintaining the same domain contracts.

Acceptance criteria:

1. Implement the Windows paths needed for capture, restore/journal preservation, exact filename/symlink/executable fidelity checks, secret custody, and per-user background startup.
2. Keep shared record/content identities platform-independent; unsupported materialization must fail explicitly before writes rather than silently converting files.
3. Add real adapter interfaces and tests for handle/rename/delete semantics, path collision/reserved names, restart, locked credentials, pause/resume, and interrupted transfers.
4. Run native Windows checks when a Windows host is available; otherwise provide reproducible native validation and record the outstanding Windows gate owned by G20. Cross-compilation or mocks are not native evidence.
5. Keep macOS/Linux build/test paths working and document platform limitations accurately. This phase is implementation readiness; final supported-platform claims wait for native evidence.

Verification: Run portable/core tests and available platform adapter checks plus common checks; record exact Windows build/native outcomes or their absence.

Scope exclusions: No broad fidelity weakening for all platforms, silent symlink-as-file conversion, permanent Windows deferral, or claimed tests on an unavailable host.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
