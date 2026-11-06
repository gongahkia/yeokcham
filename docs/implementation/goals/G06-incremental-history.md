/goal Complete G06: Persist history and indexes incrementally with atomic roots.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: TC01; TC05 incremental persistence/roots; TC06 IDs.

Scope and ownership: Own local undo/history/store indexes and state-root updates, starting from lib/yeokcham_v1_undo/, lib/yeokcham_v1_store/, lib/yeokcham_store/, and local service adapters.

Acceptance criteria:

1. Replace whole-history rewrites with bounded immutable history/index pages and a rebuildable on-disk lookup index. Append cost must not require re-encoding all prior nodes.
2. Persist workspace IDs, monotonic sequence allocation, ancestry, alternate continuations, current basis/cursor, and explicit correspondence to published work.
3. Keep the sole mutable root atomic across history/current-state updates; concurrent append/retry must be idempotent and cannot erase independent received records.
4. Recover/rebuild indexes from durable canonical data and protect current/pinned/pending/recovery roots. A corrupted derived index cannot invent or delete ancestry.
5. Test restart, branching A-B-C/return-B-D, identity collision/exhaustion, interrupted page/root publication, and index rebuild. Measure append bytes/work as depth increases using G01's harness.

Verification: Run undo/store/local-service/GC-relevant tests and incremental persistence measurements plus common checks.

Scope exclusions: No legacy artifact migration, remote expiry, compaction that drops protected data, or claims of measured whole-product speedup.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
