/goal Complete G01: Build the measurement harness and capture the local baseline.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: TC08; BENCHMARK_DESIGN.md; current Makefile and CI configuration.

Scope and ownership: Own benchmark generators/runners, small result manifests, and environment diagnostics under tools/, test/, and docs/implementation/. Preserve product runtime behavior for the baseline. Use commit d03ac1e095af7c896eede2334c5a1f5fc50c4e74 as the pre-implementation source reference.

Acceptance criteria:

1. Inspect and establish the documented build/test environment. Run make build, make lint, and make ci, recording actual outcomes. Resolve environment setup issues within authorized scope; do not hide baseline failures or weaken tests.
2. Implement deterministic, configurable fixture generation and a benchmark runner supporting source, monorepo, asset, and history-depth tiers. Keep large fixtures outside Git and verify generated/restored contents before accepting timings.
3. Run a disclosed local ordinary-source baseline for 10-MiB/1,000-file and 100-MiB/10,000-file fixtures, initially with 10 history nodes, for capture/no-op/small-edit/undo-restore operations that exist today. Use the selected cold/warm sample counts; record machine, commit, commands, bytes, latency, and limitations.
4. Persist a small machine-readable result summary plus reproducible commands and fixture hashes. Record which future operations do not exist yet; their absence is not a passing benchmark.
5. Provide a way to benchmark an unmodified export of the pinned baseline later, using the same runner/fixtures without switching main. Full 1-GiB/deep-history/monorepo/asset sessions and cross-platform comparisons belong to G19/G20 and remain visible coverage gates.

Verification: Run generator determinism/fidelity checks and focused runner checks; execute and save the stated local baseline. Do not claim full benchmark completion from this initial profile.

Scope exclusions: No storage/daemon/integration optimization, private archive, migration, or README rewrite.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
