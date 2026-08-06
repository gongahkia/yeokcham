# Project Context

## Why yeokcham exists

Git combines several different human needs into a commit graph:

- Temporary safety and undo.
- Communicating logical changes.
- Producing release and deployment history.
- Sharing work.
- Reviewing work.
- Integrating concurrent edits.

This creates pressure to use one object, the commit, for incompatible purposes.

Developers often create low-value safety commits, squash them later, rebase them into a reviewable stack, and then merge them into a release history. The workflow works, but the system requires users to manage the boundaries manually.

Modern tools have improved parts of this experience:

- Jujutsu provides a more fluid change model, stable change identity, and an operation log.
- Pijul treats changes and conflicts as first-class graph concepts.
- GitButler allows multiple virtual branches in one workspace.
- Sapling and stacked-change tools improve large-repository and review workflows.
- Unison demonstrates how content-addressed semantic code can change programming workflows.
- Irmin demonstrates branchable and mergeable persistent data structures in OCaml.

yeokcham must not claim that stable change identities, operation logs, virtual branches, graph-based changes, or content-addressing are individually new.

Its differentiated thesis is the deliberate separation of:

1. Bounded, automatic recovery history.
2. Human-curated intent history.
3. Immutable release history.

## Core problem statement

A developer should not need to decide, during every edit, whether a state deserves permanent collaborative history.

The VCS should:

- Save local work automatically.
- Let the developer recover and inspect prior states.
- Let the developer later define the logical change.
- Preserve stable change identity while its implementation is revised.
- Compose several logical changes in one workspace.
- Keep unresolved conflicts explicit without globally blocking work.
- Produce reproducible releases and conventional Git exports.

## Product thesis

yeokcham is:

> A local-first VCS where automatic scratch checkpoints are compactable, change capsules represent human intent, workspaces are compositions of capsules, and releases are immutable snapshots.

## Primary user

Initially:

- A technically sophisticated individual developer.
- Comfortable trying a new CLI.
- Interested in local-first workflows and version-control research.
- Working in repositories where TypeScript or Rust semantic experiments are useful.
- Willing to use Git export for external collaboration.

The long-term aspiration is ordinary software development, but the prototype must not pretend broad adoption exists.

## Core concepts

### Scratch checkpoint

An automatic recoverable state. It may be short-lived and compacted under retention rules.

### Change capsule

A durable logical unit of work with stable identity, description, dependencies, tests, and one or more immutable revisions.

### Capsule revision

An immutable representation of a capsule at one point in its development.

### Workspace

A base release plus an ordered composition of selected capsule revisions.

### Conflict value

A persistent object representing an application ambiguity or incompatibility.

### Release

An immutable, signed, reproducible snapshot with a declared capsule composition.

### Semantic sidecar

Structured metadata that helps replay or inspect a change while exact bytes remain authoritative.

## Product principles

### Exact bytes remain authoritative

yeokcham may understand syntax and symbols, but must preserve arbitrary files, comments, formatting, generated output, invalid intermediate source, and unknown formats.

### Automatic history is bounded

The system should preserve useful recovery states without making every transient state permanent forever.

### Intent is curated after the fact

Users can work messily and later define the logical capsule.

### Conflicts are data

A conflict should be inspectable, shareable, and localised rather than a global exceptional mode.

### Change identity survives revision

A capsule has a stable logical ID. Each materialisation or retargeting produces a new immutable revision ID.

### Release history is immutable

A release records exactly which capsule revisions and content snapshot produced it.

### Uncertainty must be visible

Semantic replay may be wrong. yeokcham should expose confidence and require validation rather than silently claiming correctness.

### Git is an interchange format

Git import and export are valuable, but yeokcham should not redesign itself around Git's internal graph.

## Project relationship to Relay

Relay is the Git-compatible, production-oriented project.

yeokcham is the experimental model.

They may eventually share:

- Research on chunking.
- Benchmark fixtures.
- General storage lessons.
- Cryptographic and segment-format concepts.

They should not share a codebase initially because:

- Relay is Rust and compatibility constrained.
- yeokcham is OCaml and model constrained.
- Premature shared formats would weaken both projects.
