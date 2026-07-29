# Bootstrap Prompt for a Local Codex Agent

You are implementing paengi, an experimental intent-first VCS written in OCaml.

paengi separates:

1. Automatic bounded scratch history.
2. Human-curated intent history made of stable change capsules and immutable revisions.
3. Immutable reproducible release history.

Read every root document in this order:

1. README.md
2. PROJECT_CONTEXT.md
3. PRD.md
4. FORMAL_MODEL.md
5. ARCHITECTURE.md
6. DECISIONS.md
7. RESEARCH_QUESTIONS.md
8. TESTING_AND_EXPERIMENTS.md
9. TODO.md
10. AGENTS.md

Do not begin with semantic parsing, Git interoperability, networking, signing, a UI, or a daemon.

Start at Milestone 0 with the smallest vertical slice:

- Initialise the Dune project.
- Define typed identities and an in-memory filesystem model.
- Define create, modify, delete, move, and mode-change scratch operations.
- Implement a pure operation-application function.
- Create checkpoint values over immutable snapshots.
- Generate random valid operation sequences.
- Prove that replay yields the expected snapshot.
- Select a portable canonical persistent encoding through an ADR, but do not use OCaml `Marshal`.

Before editing code, produce a concise implementation plan containing:

- Modules and files to create.
- Algebraic data types.
- Invariants.
- External libraries proposed and why.
- Unit and property tests.
- Any decision that changes the supplied model.

Constraints:

- Use OCaml and Dune.
- Keep a functional core and imperative shell.
- Exact bytes are canonical.
- Semantic information is always a sidecar.
- Conflicts will become persistent values, not exceptions.
- Stable capsule identity must remain distinct from immutable revision identity.
- Persistent formats must be portable and versioned.
- Update TODO.md as work is completed.
- Record model changes in FORMAL_MODEL.md and DECISIONS.md.

The first success criterion is a rigorously tested in-memory scratch-history model, not a polished CLI.
