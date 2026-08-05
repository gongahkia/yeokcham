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

Immutable, reproducible snapshots assembled from approved change capsules, with
separate optional attestations.

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

Milestone 6 is complete. It has bounded direct-argv validation against exact
immutable snapshots; immutable evidence; create-only, reproducible releases;
and test-only separate attestations. `Requires_release` has a pure exact
ancestry predicate but remains unavailable to durable `Workspace_revision_v1`:
ADR-026 stores no declared base release, so ADR-027 requires an additive v2
schema rather than inferring ancestry from snapshot equality. Production signing
is deferred; the included deterministic test signer is not cryptographic.
Milestone 5 has persistent immutable workspace selection, deterministic
composition attempts, persistent conflicts, explicit skip-operation resolutions,
and guarded workspace materialisation. Workspace revisions/current refs and
attempts survive reopen; unresolved application remains explicitly partial.
Milestone 4 has durable capsules: immutable Capsule and complete revision
objects, CAS-protected current refs, exact replay validation, pinned scratch
boundaries, and split/combine replay checks. Milestone 3 has retained-ID scratch
compaction: immutable compacted generations shorten retained replay chains and
quarantine superseded scratch records.
`compact --prune` is irreversible. paengi remains a portfolio and research
prototype, not a production Git replacement.

Milestone 7 is complete as a bounded, non-persistent TypeScript-sidecar
experiment. It compares an independent byte-only contextual textual baseline
with deterministic semantic evidence stages against one shared 40-case fixture
dataset and checked v1 results. The optional full-parser capability uses the
locally pinned TypeScript Compiler API (`5.9.3`; Node `>=14.17.0`) through a
versioned stdin/stdout protocol and verified-snapshot virtual file map. It
does not persist semantic data, alter canonical file bytes or prior formats, or
participate in restore, materialisation, export, or verification. Helper
absence, invalid output, timeout, or incomplete analysis returns
semantic-unavailable and preserves the textual operation.

Milestone 8 has its first durable vertical slice: bounded direct-argv import
of one Git tree into an exact Paengi snapshot. It preserves `100644`, `100755`,
and `120000` bytes/modes, rejects unsafe names and unsupported modes, and writes
an immutable ADR-028 mapping binding. It neither imports Git commits/topology
nor exports Git data, and makes no general Git compatibility promise.

See `CONTRIBUTING.md` for development rules. Paengi is licensed under the MIT License.

## Development

Install the host tools on macOS, create the repository-local OCaml 5.5.0 switch, and run every gate:

```bash
brew install opam actionlint
make setup
make ci
```

`make build`, `make test`, `make property-test`, `make semantic-experiment`, `make lint`, and `make format` expose the individual steps. `make check` runs build, format verification, lint, package validation, tests, the persistent-format audit, and static experiment-schema validation without the GitHub Actions linter.

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
dune exec bin/paengi.exe -- capsule edit <capsule-id>
dune exec bin/paengi.exe -- capsule fold <capsule-id> --from <editing-anchor> --to <checkpoint>
dune exec bin/paengi.exe -- capsule split <capsule-id> --left-id <capsule-id> --left-title <title> --left-description <description> --right-id <capsule-id> --right-title <title> --right-description <description> --left-indices <indices> --confirm
dune exec bin/paengi.exe -- capsule combine --id <capsule-id> --title <title> --description <description> --source <capsule-id> --source <capsule-id> --confirm
dune exec bin/paengi.exe -- capsule show <capsule-id>
dune exec bin/paengi.exe -- capsule current-diff <capsule-id>
dune exec bin/paengi.exe -- capsule history <capsule-id>
dune exec bin/paengi.exe -- work explain-order --enable <capsule-id> --enable <capsule-id> [--order <revision-id>,<revision-id>]
dune exec bin/paengi.exe -- work create --id <workspace-id> --base <snapshot-id> [--name <name>] [--description <description>]
dune exec bin/paengi.exe -- work show <workspace-id>
dune exec bin/paengi.exe -- work enable <workspace-id> <capsule-revision-id>
dune exec bin/paengi.exe -- work disable <workspace-id> <capsule-id>
dune exec bin/paengi.exe -- work reorder <workspace-id> --order <revision-id>,<revision-id>
dune exec bin/paengi.exe -- work explain-order <workspace-id>
dune exec bin/paengi.exe -- work materialise <workspace-id> [--dry-run]
dune exec bin/paengi.exe -- conflict list <workspace-id>
dune exec bin/paengi.exe -- conflict show <conflict-id>
dune exec bin/paengi.exe -- conflict resolve <workspace-id> <conflict-id> --action skip
dune exec bin/paengi.exe -- validation run --snapshot <snapshot-id> --exec <program> [--arg <argument>] [--cwd <relative-path>] [--timeout-ms <milliseconds>] [--max-stdout-bytes <bytes>] [--max-stderr-bytes <bytes>] [--env <name=value>] [--inherit-env] [--retain-output]
dune exec bin/paengi.exe -- release create --workspace <workspace-id> [--parent <release-id>] [--message <text>] [--validation-exec <program> [--validation-arg <argument>] [--validation-cwd <relative-path>] [--validation-timeout-ms <milliseconds>] [--validation-max-stdout-bytes <bytes>] [--validation-max-stderr-bytes <bytes>] [--validation-env <name=value>] [--validation-inherit-env] [--validation-retain-output]]
dune exec bin/paengi.exe -- release show <release-id>
dune exec bin/paengi.exe -- release verify <release-id>
dune exec bin/paengi.exe -- release list
dune exec bin/paengi.exe -- git import tree --repository <absolute-git-directory> --tree <full-git-tree-id>
```

`work explain-order` is read-only. It resolves each enabled capsule's current
immutable revision, validates the selected graph, and prints canonical order
and precedence edges. `--order` must name every enabled revision exactly once.

Durable workspaces select an explicit immutable capsule revision; its verified
physical revision object is stored in every workspace revision.
`work materialise` applies the current workspace against its declared base,
records a partial attempt when conflicts exist, and uses guarded scratch
materialisation. `conflict resolve --action skip` is deliberately the only v1
resolution action; no content, mode, or path is guessed or rewritten.

`validation run` resolves and materialises only the supplied immutable snapshot
to a fresh temporary directory before direct argv execution. It never validates
the live working directory or moves any canonical ref. Output capture is
bounded; full-stream digests, truncation, outcome, and optional bounded Content
objects are immutable evidence.

`release create` reads the current immutable workspace revision and its verified
complete attempt, rejects unresolved conflicts, replays it, runs every supplied
required validation against the resulting snapshot, then publishes an immutable
release through a create-only binding. `release verify` replays durable inputs;
it does not trust a workspace cache or current workspace selection.

`git import tree` requires an initialized Paengi root and an absolute local Git
repository directory. It accepts only a full SHA-1 or SHA-256 tree ID, prints
the imported snapshot and immutable mapping IDs, and does not advance any
scratch, capsule, workspace, or release ref.

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

`capsule edit <capsule-id>` resolves and directly replays the immutable current
revision, safety-checkpoints divergent working state through guarded restore,
then materialises and verifies the revision result. It prints a scratch editing
anchor; if both the working directory and scratch head already equal that result,
the existing checkpoint is reused. `capsule fold` requires that explicit anchor
and a later checkpoint, then uses the existing CAS-protected range fold path.

`capsule split` and `capsule combine` always print a deterministic read-only
plan. The plan identifies source capsule/revision/object IDs, operation indices
or ordered sources, output bases/results, operation/dependency counts,
provenance, composition order, and boundary pins. Publication requires
`--confirm`; without it the command exits non-zero after printing its plan.
Confirmed execution re-resolves and revalidates immutable sources before it
publishes any output.

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
8. `docs/ISSUE_TRACKING.md` and the linked open GitHub issue
9. `AGENTS.md`
10. `CODEX_PROMPT.md`

## First implementation target

The first end-to-end milestone is:

> Observe a directory, create automatic scratch checkpoints, restore any checkpoint exactly, compact an unpinned checkpoint sequence without changing retained states, and prove those properties with generated tests.

Do not start with semantic merging, Git import, distributed sync, a graphical UI, or multiple languages.
