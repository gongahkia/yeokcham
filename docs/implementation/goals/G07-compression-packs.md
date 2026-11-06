/goal Complete G07: Implement lossless compression, indexed packs, and safe collection.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: TC05; D04/D13-D15; BENCHMARK_DESIGN.md.

Scope and ownership: Own physical object-store wrappers, pack indexes, compaction/collection, and storage reporting. Start from lib/yeokcham_store/, lib/yeokcham_chunking/, and lib/yeokcham_v1_gc/ using G06 roots.

Acceptance criteria:

1. Preserve canonical uncompressed SHA-256 identities and existing Buzhash defaults while adding Zstandard level 3 with both savings thresholds.
2. Implement immutable approximately 64-MiB indexed packs with independently retrievable/decompressible objects and bounded buffers; verify decoded type/length/hash.
3. Publish verified new pack/index roots atomically before reclaiming old storage, protecting readers, pending roots, and interrupted maintenance.
4. Account separately for private, shared/protected, working-tree, and maintenance storage. Collection must recheck a fixed root generation without deleting new roots.
5. Fault-test packing/repacking/collection interruptions and corruption; restore exact source and opaque bytes. Compare representative source and incompressible cases to G01's preserved baseline.

Verification: Run store/chunk/GC and fault tests plus common checks and affected benchmark samples; preserve full-scope G19 evidence gate.

Scope exclusions: No custom compression codec, inter-version delta chains, cross-account deduplication, or implicit history expiration.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
