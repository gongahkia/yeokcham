/goal Complete G08: Synchronize immutable shared history with verified offline coverage.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: TC02 offline results; TC04/TC05 transfer; TC06 branch/authority admission.

Scope and ownership: Own shared package/transport/bootstrap/workspace-availability interfaces and durable outbox handling. Start from lib/yeokcham_v1_package/, lib/yeokcham_v1_transport/, lib/yeokcham_v1_transfer/, sync/HTTP/bootstrap modules, and G02/G03 records.

Acceptance criteria:

1. Transfer and verify new revision/branch/accepted/policy/review record types and their dependencies with duplicate-safe receipts and resumable 1-MiB ranges.
2. Persist outgoing work and acknowledgements; retry lost network responses without creating new logical publications or acceptances.
3. Download all shared history/branches by default while supporting configured narrower scopes. Prioritize the selected working version and distinguish verified local closure from metadata-only receipt.
4. Preserve concurrent heads and apply G03 admission rules for stale/revoked authority. Receiving data must never write working files, move a private cursor, execute project commands, or silently accept a reconciliation.
5. Provide usable coverage/status data for CLI consumers and test offline selection of previously unvisited downloaded versions, missing dependencies, interrupted transfers, and receipt permutations.

Verification: Run transfer/package/transport/sync/bootstrap/workspace tests and controlled local native-relay integration tests plus common checks.

Scope exclusions: No private-history upload through team packages, automatic integration, Git interoperability, or public service deployment.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
