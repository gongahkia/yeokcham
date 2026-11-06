/goal Complete G05: Implement native ignore rules and reliable portable capture.

Work in the Yeokcham repository directly on main. Read docs/IMPLEMENTATION_WORKFLOW.md and docs/IMPLEMENTATION_PROGRESS.md first and follow their shared constraints. Verify predecessor reports/commits and claim only this phase. Read applicable AGENTS.md and the relevant agreed design documents. Do not start another phase automatically.

Design context: TC07; D20/D22; CLI_DESIGN.md ignore explanations.

Scope and ownership: Own lib/yeokcham_snapshot/, scanner/ignore helpers, filesystem preflight contracts, relevant CLI ignore inspection, and tests. Coordinate type use with G02; preserve supported byte/metadata fidelity.

Acceptance criteria:

1. Implement root/nested .yeokchamignore matching, glob/negation/escaping/precedence semantics, mandatory exclusions, and an actionable ignore explain path. Never consult Git ignore configuration.
2. Implement bounded retries for files changing during capture, directory membership rechecks, incomplete-capture reporting, and reuse of verified staging without publishing a partial pass as saved.
3. Stream large files and preserve exact bytes, symlink targets, executable distinction, and empty directories. Report unsupported special files explicitly.
4. Add destination preflight for representability, case/normalization collisions, symlink/executable support, ignored paths, and untracked obstructions. Leave ignored live files and previous history intact.
5. Test text, document, binary, changing-file, nested-ignore, re-inclusion, and portability cases. Record native OS evidence separately from simulated boundary tests; remaining OS-native validation belongs to G20.

Verification: Run snapshot/materialization/ignore and CLI inspection tests plus common checks; no large-file test may silently skip failed fidelity.

Scope exclusions: No Git carryover, extension-based exclusions, extra metadata-fidelity promises, or silent filename conversion.

Make small, coherent, buildable git commits on main. Preserve unrelated work. README.md changes are limited to accurate additions or corrections of demonstrably outdated/wrong material. Do not create branches/worktrees, push, deploy, or start additional implementation agents.

Keep docs/IMPLEMENTATION_PROGRESS.md current. Before finishing, audit every criterion, save an evidence-backed report using docs/implementation/REPORT_TEMPLATE.md, and commit the report/tracker update separately from implementation commits. Return the full report in a copyable Markdown block and the next eligible /goal prompt in a separate text block, including predecessor evidence. If incomplete or blocked, report the exact remainder and return a continuation of this same phase instead of advancing. Do not claim unavailable tests passed, and do not execute the printed next prompt.
