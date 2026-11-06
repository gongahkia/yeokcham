/goal Complete G15: Implement the durable per-user background scheduler.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: TC04; TC03/TC05 transfer/retention; CLI_DESIGN.md pause/status.

Scope and ownership: Own scheduler/registry/durable queue/health/runtime interfaces and foreground service run, starting from bin/v1_watch_runner.ml, watcher/runtime modules, and the completed capture/archive/sync services.

Acceptance criteria:

1. Run one per-user manager with fair per-repository scheduling and serialized writers, using the chosen debounce, rescan, retry, concurrency, and buffer defaults.
2. Persist registration, transfer/outbox state, pauses, and recovery across process restart; integrate capture/private backup/shared prefetch/retention without exposing partial journal application as ordinary capture.
3. Prioritize foreground work and local capture, handle metered/battery settings, and defer optional maintenance under pressure without silently narrowing shared offline promises.
4. Implement pause network versus pause --all, resume, sync pass, and truthful paused/offline/locked/retrying/blocked health states.
5. Fault-test lost watcher events, wake/restart, disconnection/backlogs, missing credentials, full disk, concurrent foreground operations, and bounded resource behavior.

Verification: Run scheduler fake-clock/property tests, foreground service end-to-end journeys, and restart/fault tests plus common checks. OS-manager installation follows G16/G17.

Scope exclusions: No root daemon, unexpected project-command execution on receipt, hidden polling prompts, or automatic integration.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
