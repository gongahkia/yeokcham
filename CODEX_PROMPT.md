# Bootstrap Prompt for a Local Codex Agent

You are implementing Yeokcham, a Git-compatible, local-first, encrypted repository accelerator and sovereign remote written in Rust.

Read every root document in this order:

1. README.md
2. PROJECT_CONTEXT.md
3. PRD.md
4. ARCHITECTURE.md
5. DECISIONS.md
6. SECURITY_AND_RECOVERY.md
7. TESTING_AND_BENCHMARKS.md
8. TODO.md
9. AGENTS.md

Do not begin by implementing Google Drive, GitHub mirroring, a daemon, a server, or a UI.

Start at Milestone 0 and then the smallest vertical slice of Milestone 1:

- Initialise the Rust workspace.
- Define the core object identifiers and repository format version.
- Import and verify one Git blob.
- Store it in a simple immutable Yeokcham record.
- Reconstruct the exact bytes.
- Recompute and verify the original Git object ID.
- Export it as a valid Git object.
- Add round-trip and corruption tests.

Before editing code, produce a concise implementation plan containing:

- Files and crates to create.
- Public types and invariants.
- External crates you propose to use and why.
- Tests to add.
- Any architectural decision that requires an ADR.

Constraints:

- Use stable Rust.
- Prefer mature Git libraries for Git primitives.
- Avoid unsafe code.
- Avoid custom cryptography.
- Do not make performance claims without benchmark evidence.
- Keep persistent encodings versioned.
- Treat all external bytes as hostile.
- Update TODO.md as work is completed.
- Record any deviation from the documents in DECISIONS.md or a new ADR.

The first success criterion is not speed. It is a verified, byte-exact Git object round trip with a clean architecture that can grow into the full storage engine.
