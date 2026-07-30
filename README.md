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

Milestone 4 has durable capsules: immutable Capsule and complete revision
objects, CAS-protected current refs, exact replay validation, pinned scratch
boundaries, and split/combine replay checks. Milestone 3 has retained-ID scratch
compaction: immutable compacted generations shorten retained replay chains and
quarantine superseded scratch records.
`compact --prune` is irreversible. paengi remains a portfolio and research
prototype, not a production Git replacement.

See `CONTRIBUTING.md` for development rules. Paengi is licensed under the MIT License.

## Development

Install the host tools on macOS, create the repository-local OCaml 5.5.0 switch, and run every gate:

```bash
brew install opam actionlint
make setup
make ci
```

`make build`, `make test`, `make property-test`, `make lint`, and `make format` expose the individual steps. `make check` runs build, format verification, lint, package validation, and tests without the GitHub Actions linter.

## Current local CLI

```bash
dune exec bin/paengi.exe -- init
dune exec bin/paengi.exe -- checkpoint
dune exec bin/paengi.exe -- timeline --limit 32
dune exec bin/paengi.exe -- restore --dry-run <checkpoint>
dune exec bin/paengi.exe -- restore <checkpoint>
dune exec bin/paengi.exe -- pin <checkpoint>
dune exec bin/paengi.exe -- unpin <checkpoint>
dune exec bin/paengi.exe -- compact --dry-run --explain
dune exec bin/paengi.exe -- compact --explain
dune exec bin/paengi.exe -- compact --resume
dune exec bin/paengi.exe -- compact --prune
dune exec bin/paengi.exe -- watch --interval-ms 500 --debounce-ms 500
dune exec bin/paengi.exe -- capsule create --current --id <capsule-id> --title <title> --description <description>
dune exec bin/paengi.exe -- capsule show <capsule-id>
dune exec bin/paengi.exe -- capsule current-diff <capsule-id>
dune exec bin/paengi.exe -- capsule history <capsule-id>
```

`restore` creates a durable safety checkpoint for divergent work, validates its
plan immediately before applying, and moves `scratch-head` only after exact
result verification. It is not crash-atomic for a populated working directory;
on a reported partial failure, restore the reported safety checkpoint.

Compaction keeps CLI checkpoint IDs logical. An activated generation resolves
retained logical IDs to verified physical checkpoints; unretained IDs become
unavailable only after their objects move to `.paengi/trash/<generation-id>/`.
Quarantine can be inspected or resumed. Permanent prune cannot restore the
previous generation's quarantined history. `compact --dry-run --explain`
reports the exact canonical cleanup IDs, expected types, count, and stored
object-file bytes; these exclude payload-only and filesystem-allocation
estimates and are checked again during activation.

Capsule read commands report logical capsule and revision IDs. They resolve the
checksummed current ref, exact immutable object types, logical/physical links,
parent chain, and direct replay before displaying data; corrupt or stale state
returns an error rather than a best-effort result.

`capsule create --current` takes a caller-supplied 32-byte hexadecimal capsule
ID, scans the working directory twice while holding the repository writer lock,
and creates a normal scratch checkpoint only for a verified difference from the
scratch head. Equal snapshots print `no-changes` and publish neither a capsule
ref nor a checkpoint. A changed state is checkpointed before the immutable
capsule objects and current ref are published; an interrupted pre-ref attempt
is safely checkpointed, remains invisible as a capsule, and can be retried
with the same inputs through its retained boundaries.

## Testing scope

Paengi is a local VCS and persistent-data-model project. Its tests cover repository correctness, deterministic generated inputs, and checked-in local fixtures. External security analysis is outside scope. Bounds checks, corruption detection, atomic writes, and malformed-input handling remain required storage-system behavior.

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
