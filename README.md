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
`docs/COMPACTION_RETENTION_BENCHMARK.md` records host-specific evidence for
the implemented retention policies; its companion
`docs/COMPACTION_RETENTION_RESULTS.md` publishes those measurements without a
performance claim.
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

M9-01/M9-02/M9-03 add a separate optional Rust syntax sidecar. Its locally built,
lockfile-pinned Tree-sitter helper receives only verified-snapshot virtual
`.rs` files and returns bounded syntax evidence with UTF-8 byte spans. M9-02
can also resolve caller-selected virtual roots through standard `foo.rs` and
`foo/mod.rs` candidates, with explicit incomplete results for ambiguity,
attributes, damage, and unreachability. It does not read a live source tree,
infer Cargo roots, run Cargo/rustc/macro expansion, persist results, resolve
symbols/types, or enable rewrites. Helper absence, invalid UTF-8, parser
damage, or process failure remains a structured semantic-unavailable/incomplete
result; byte/text operations stay available. See
[ADR-035](docs/adr/035-optional-rust-parser-sidecar.md),
[ADR-036](docs/adr/036-snapshot-local-rust-module-paths.md), and the
[ADR-037](docs/adr/037-rust-macro-textual-fallback.md). M9-03 adds a separate
snapshot-local fallback assessment: macro definitions/invocations, outer
attributes, and parser damage return bounded canonical
`textual-fallback-required` facts only; no fact expands code or authorizes a
semantic operation. M9-04 adds bounded Rust rename/move fixture maps with
exact textual byte oracles and explicit ambiguity/macro/parser fallback cases;
they do not implement Rust rename or move inference. See the
[helper contract](tools/paengi-rust-adapter/README.md).

Milestone 8 imports one Git tree/commit/tag through bounded direct argv and
exports one Paengi release as a deterministic root Git commit. Imports preserve
supported `100644`, `100755`, and `120000` content/modes and opaque commit/tag
provenance without fabricating a capsule or revision. ADR-032 export uses the
release snapshot, fixed export metadata, a create-only release ref, and an
ADR-028 mapping; it rejects nested empty directories. It makes no general Git
compatibility promise.

M10-01 provides a bounded, transport-neutral local immutable-object exchange
core. It verifies canonical frames, compatible repository formats, budgets,
Envelope-1 bytes, and ADR-020 object IDs before create-only publication. It
does not implement a network transport, CLI, ref transfer, reconciliation,
identity, signing, or persistent resume; exchange leaves every mutable ref
unchanged.

M10-02 adds immutable Ed25519-signed ref-transition proposals. A proposal is
verified only against a caller-supplied public-key map; an absent key is
untrusted. Storage, transfer, verification, replay/order checks, and divergence
reporting do not apply or reconcile a ref. Key lifecycle, device identity,
transport, trust configuration, and user-facing ref application are deferred.

M10-03 adds immutable public device declarations. Each binds a random opaque
device ID to one Ed25519 public key; generated private capability remains
caller-owned and is never stored. An explicit bounded registry may resolve an
already verified event to one declaration, unmapped, or ambiguous; it does not
make a key trusted, update a ref, rotate/revoke a key, or identify a person.

M10 local synchronisation requires no central service: two local repositories
can exchange caller-declared immutable objects directly, or carry caller-keyed
ADR-042 bundles through a local shared directory. These paths do not establish
peer identity, availability, authorisation, key recovery, ref synchronisation,
or replay protection; callers retain explicit trust and reconciliation choices.

M10-04 adds bounded local HTTP/1.1 transfer for ADR-038 frames. It validates
one exact frame per POST, reoffers immutable IDs after interruption, and
publishes only verified objects; HTTP transfer leaves refs, trust, device
resolution, and divergence unchanged. It has no CLI, authentication, or
persistent session state.

M10-05 adds immutable divergent ref-head sets. A set holds 2–4,096 exact,
verified `Ref_event` object links for one ref and observed state; publication
unions candidates through a checksummed `refs/sync-divergence/<ref>` binding.
Malformed, untrusted, missing, wrong-type, stale-context, and corrupt binding
inputs reject explicitly. The binding records candidates only: it neither reads
nor changes the application ref, selects a head, or reconciles a target.

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
dune exec bin/paengi.exe -- git import commit --repository <absolute-git-directory> --commit <full-git-commit-id>
dune exec bin/paengi.exe -- git import tag --repository <absolute-git-directory> --tag <name>
dune exec bin/paengi.exe -- git export release --repository <absolute-git-directory> --release <release-id> [--author-name <name> --author-email <email> --committer-name <name> --committer-email <email> --message <message>]
dune exec bin/paengi.exe -- git export revisions --repository <absolute-git-directory> --revision <capsule-id>:<revision-id>:<stored-object-id> [--revision <capsule-id>:<revision-id>:<stored-object-id> ...]
```

`work explain-order` is read-only. It resolves each enabled capsule's current
immutable revision, validates the selected graph, and prints canonical order
and precedence edges. `--order` must name every enabled revision exactly once.

`git export release` uses the fixed M8-08 Git identity and release message by
default. Supplying all five metadata flags selects exact caller-provided Git
author, committer, and message bytes for that export only; partial or duplicate
metadata flags reject. Configured metadata does not change the Paengi release
or snapshot. Its Git ref is metadata-qualified, so it neither overwrites the
default export nor a different configured export of the same release.

[Git interchange contract](docs/GIT_INTERCHANGE.md) distinguishes supported
byte preservation, opaque provenance, rejected representations, and semantics
that Git cannot recover.

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

`git import commit` has the same root and repository requirements. It accepts a
full SHA-1 or SHA-256 commit ID, verifies the exact declared tree and direct
parent object types, and prints an opaque transition, snapshot, mapping, commit,
ordered parent IDs, hex-safe author/committer bytes, and a message Content ID.
It retains source metadata as opaque bytes, does not normalize identity or time,
recursively import parents, or advance any Paengi history ref.

`git import tag` has the same root and repository requirements. It resolves one
bounded `refs/tags/<name>` ref, retains a lightweight target or raw annotated
tag bytes as opaque provenance, and prints the imported-tag and mapping IDs. It
does not create a Paengi release, capsule, or history ref, and does not verify
tag signatures.

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

`--storage-budget-bytes` is a deterministic selection bound over source
Checkpoint/Event object-file bytes, not a total repository quota. Pins and the
logical scratch head remain retained; `--explain` reports retained/protected
budget bytes, `budget-excluded` checkpoints, and any protected-only overrun.
Shared snapshot/content objects remain outside this M3 budget until a complete
cross-domain root mark exists.

Compaction also composes source-event operations between retained checkpoints
and removes only proven adjacent inverse pairs. Both original and reduced
chains must replay to the same retained snapshot; `--explain` reports
`inverse-pairs-eliminated`. This does not remove a retained logical checkpoint
or infer semantic intent.

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
