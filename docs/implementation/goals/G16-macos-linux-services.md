/goal Complete G16: Integrate managed macOS and Linux services.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: TC04 platform lifecycle; TC03 credential custody; D11/D26.

Scope and ownership: Own launchd/systemd user adapters, installer/registration/startup behavior, platform credential/watcher glue, service diagnostics, and reproducible platform test scripts.

Acceptance criteria:

1. Implement idempotent per-user registration/start/stop/pause/unregister for macOS LaunchAgent and Linux systemd user service, plus explicit foreground fallback.
2. Connect init/clone registration to real readiness checks; terminal exit/restart must not silently disable a successfully configured manager.
3. Handle login/wake, stale paths, missing managers/providers, upgrades, clean shutdown, and permissions without requiring a root daemon or modifying unrelated user services.
4. Exercise native lifecycle on the available host and unit/contract tests for both adapters. Provide executable instructions/fixtures for the other host.
5. Record unexecuted macOS/Linux native runs in G20's coverage gates. Completion here means implemented adapters plus available-host evidence, never a claim that an unavailable OS was tested.
6. Provide clear service-health and recovery messages and update detailed platform docs with minimal README additions/corrections only if needed.

Verification: Run platform-specific watcher/runtime/service tests, available-host lifecycle integration, and common checks. Leave the final native matrix explicitly outstanding when necessary.

Scope exclusions: No machine-wide launch daemon, public deployment, or assumption that Linux adapter tests prove native systemd behavior.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
