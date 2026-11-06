/goal Complete G02: Implement canonical records, identities, and shared interfaces.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: TC01, TC03 identity boundaries, TC06 canonical records, TC08 S0.

Scope and ownership: Own canonical record/pure-type modules, the envelope/type registry, golden vectors, and docs/implementation/INTERFACES.md. Start from lib/yeokcham_encoding/, lib/yeokcham_envelope/, lib/yeokcham_v1_record/, lib/yeokcham_v1_model/, and lib/yeokcham_v1_trust/; introduce cohesive new modules where appropriate.

Acceptance criteria:

1. Implement the specified typed record bodies, canonical payload field order, domain-separated signing bytes, immutable IDs, scope checks, and bounded decoding. Allocate new schema/type codes once and document the registry.
2. Define stable workspace/change/branch/request/member identities and workspace-plus-sequence history IDs, with idempotent repeats and collision rejection. Do not conflate content identity with history position.
3. Define the pure interfaces consumed by composition, policy, archive, journal, and CLI results; record actual module names and function signatures in INTERFACES.md so later agents extend one contract.
4. Add golden encoding/signature-input/identity fixtures and negative tests for noncanonical input, wrong scope, unknown mandatory versions, oversize records, malformed references, and identity collisions.
5. Keep the repository buildable while adding the new foundation. Update development fixtures where formats change; do not create legacy artifact readers or report unconnected record types as a working feature.

Verification: Run focused record/encoding/trust tests and meaningful malformed-input/property tests, then the common build/lint/CI checks.

Scope exclusions: No full daemon, private-server deployment, CLI overhaul, or wholesale replacement of runtime workflows in this phase.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
