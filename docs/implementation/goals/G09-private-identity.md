/goal Complete G09: Implement private account identity, device enrollment, and recovery custody.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: TC03 setup/enrollment/encryption; TC06 account epochs; D16/D17.

Scope and ownership: Own private-account/key-provider modules and minimal account/device CLI paths, extending existing trust/custody/recovery primitives through G02 interfaces. Keep private identity independent of project authority.

Acceptance criteria:

1. Integrate the specified established crypto provider with explicit key/nonce/domain boundaries and known-answer/negative tests; do not invent cryptographic primitives.
2. Implement account genesis/identity, a separate 24-word recovery secret, single-use enrollment invitations/pairing, owner-device approval, revocation/key epochs, and recovery authentication.
3. Use OS/external credential-provider interfaces outside repository data, with locked/unavailable outcomes and no daemon prompt or plaintext fallback. Implement available native providers and record other-OS evidence for G16/G17/G20.
4. Ensure server credentials or project membership cannot enroll a decryption device or recover private keys; account pairing cannot silently grant repository signing authority.
5. Wire truthful account/device/recovery CLI ceremonies without leaking secrets through argv, JSON, logs, or ordinary config. Test wrong phrases, replay/expired requests, account forks, revoked devices, and recovery without an old device.

Verification: Run crypto vectors, custody/account lifecycle tests, CLI redaction tests, and common checks. Do not call an unreviewed provider stub a working recovery feature.

Scope exclusions: No managed signup/billing, server escrow, reuse of project recovery seeds, or private data on the public relay path.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
