# paengi

paengi is an experimental, intent-first version-control system.

Its central thesis is:

> Recovery history, collaborative intent history, and release history serve different purposes and should not be forced into one commit graph.

paengi deliberately explores a new model rather than preserving Git's internal concepts.

## The three histories

### Scratch history

Automatic, high-frequency, local checkpoints used for undo, recovery, and experimentation.

### Intent history

Human-curated **change capsules** representing logical work such as a feature, bug fix, refactor, or dependency update.

### Release history

Immutable, signed, reproducible snapshots assembled from approved change capsules.

## Primary experience

A user should be able to:

- Work without manually deciding when to make safety commits.
- Recover recent filesystem states.
- Group messy scratch work into a coherent change capsule.
- Enable several change capsules in one workspace.
- Retarget a capsule onto a changed base.
- Keep conflicts as explicit values while continuing unrelated work.
- Publish a selected sequence as an ordinary Git branch when interoperability is needed.

## Recommended implementation language

OCaml.

OCaml is selected because paengi's core is an algebraic model of immutable state, operations, conflicts, composition, and compaction. The project should make extensive use of algebraic data types, pure transition functions, property testing, and explicit state-machine modelling.

The supported compiler is OCaml 5.5.0. The exact constraint is recorded in `dune-project`.

## Status

Design and implementation handoff package. paengi is a portfolio and research prototype first, not a production Git replacement.

See `CONTRIBUTING.md` for development rules. Paengi is licensed under the MIT License.

## Non-goals for the initial prototype

- Full Git command compatibility.
- Git wire protocol compatibility.
- A hosted forge.
- A virtual filesystem.
- Semantic understanding of every language.
- Automatically proving that a merge is behaviourally correct.
- Multi-user production security.
- Replacing Git for ordinary teams immediately.
- Sharing code directly with Relay before either design stabilises.

## Read order for an implementation agent

1. `PROJECT_CONTEXT.md`
2. `PRD.md`
3. `FORMAL_MODEL.md`
4. `ARCHITECTURE.md`
5. `DECISIONS.md`
6. `RESEARCH_QUESTIONS.md`
7. `TESTING_AND_EXPERIMENTS.md`
8. `TODO.md`
9. `AGENTS.md`
10. `CODEX_PROMPT.md`

## First implementation target

The first end-to-end milestone is:

> Observe a directory, create automatic scratch checkpoints, restore any checkpoint exactly, compact an unpinned checkpoint sequence without changing retained states, and prove those properties with generated tests.

Do not start with semantic merging, Git import, distributed sync, a graphical UI, or multiple languages.
