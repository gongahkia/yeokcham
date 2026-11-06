/goal Complete G10: Implement complete encrypted backup and exact private-history restoration.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: TC03 archive/encryption/completion; TC05 transfer; D13/D16/D17.

Scope and ownership: Own private archive client/server APIs, encrypted manifests/index pages/key envelopes, completion receipts, and archive restoration. Use G07/G08 storage/transfer and G09 identity/custody.

Acceptance criteria:

1. Encrypt private content/index/ancestry under the chosen per-repository epochs; maintain ciphertext-ID indexes without exposing filenames or private history through shared packages.
2. Implement missing-object inventory, resumable upload, durable manifest commit, duplicate-safe receipts, readback verification, and persisted dependency-completeness evidence.
3. Block local eviction eligibility until the complete manifest, contents, ancestry, and required recovery envelopes are verified; partial uploads and quota errors remain pending.
4. Restore exact snapshot bytes and undo ancestry on a fresh device from archive data plus recovery capability, without relying on the lost device's database.
5. Test interrupted upload/commit/acknowledgement, corruption/missing data, server rollback relative to known roots, inaccessible old epochs, revoked devices, and opaque-file fidelity. Document reproducible self-hosted setup under docs/.

Verification: Run private archive client/server integration, recovery, idempotence, and fault tests using disposable local services plus common checks.

Scope exclusions: No public deployment, administrator decryption, automatic remote expiry, or claimed global freshness after fresh-device recovery.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
