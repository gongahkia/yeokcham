# Project Context

## Why Relay exists

Git remains the compatibility standard for source control, but its default repository and hosting workflows create several practical concerns:

- Developers commonly make a central forge the canonical location of their work.
- A hosted forge can change policies, suspend service, discontinue features, or become unavailable.
- Publishing source to a forge necessarily gives that forge access to the published source.
- Long histories, giant monorepos, and large binary assets can make ordinary clone and storage workflows expensive.
- Git has accumulated partial clone, sparse checkout, commit graphs, multi-pack indexes, filesystem monitoring, maintenance tasks, and Git LFS, but these capabilities are fragmented and not presented as one simple sovereign-storage product.
- Putting a live `.git` directory inside a generic cloud-sync folder is unsafe because such services do not provide Git-aware transactions.

Relay should let developers treat GitHub as a disposable publication and collaboration surface while keeping the canonical repository under their own control.

## Core problem statement

Ordinary developers need a repository system that:

- Works with existing Git clients, CI, IDEs, and GitHub workflows.
- Stores versioned content more efficiently, especially large and repeatedly modified files.
- Avoids downloading irrelevant historical blobs before a repository becomes usable.
- Can use inexpensive or user-controlled storage without assuming the backend understands Git.
- Encrypts content before it leaves the local machine.
- Has a clear, tested path back to a normal Git repository.

## Product thesis

Relay is not "Git on Google Drive" and not "Git rewritten in Rust."

Relay is:

> A Git object gateway that preserves Git identities and protocol compatibility while storing content in an encrypted, chunk-addressed, backend-independent representation.

## Competitive context

Relay should explicitly learn from, and avoid duplicating without differentiation, the following classes of tools:

- Git and gitoxide: Git object and protocol implementations.
- Git LFS: external storage for selected large files.
- Xet-style systems: content-defined chunking and cross-version deduplication.
- Scalar and Sapling: large-repository and monorepo acceleration.
- git-annex and remote helpers: content stored outside ordinary Git object storage.
- Radicle: local-first and decentralised Git collaboration.
- Fossil and Gitea-class tools: self-hosted repository browsing and collaboration.
- Encrypted Git remote tools: client-side encrypted repository transport.

Relay's differentiated combination is:

- No mandatory pointer-file migration.
- Existing Git histories remain valid.
- Git object IDs remain canonical at the compatibility boundary.
- Internal chunk deduplication is invisible to Git clients.
- The remote backend may be a dumb file store.
- Encryption happens before upload.
- Partial retrieval is a default product behaviour rather than expert configuration.
- GitHub is an optional mirror.
- Full conventional Git export is a release requirement.

## Primary user

An ordinary software developer who:

- Uses Git daily.
- Wants a self-controlled canonical remote.
- May have large repositories, binaries, generated assets, or long histories.
- Does not want to learn a new version-control model.
- Expects `git clone`, `git fetch`, and `git push` to continue working.
- Will not tolerate repository corruption or opaque lock-in.

## Initial target workloads

Relay should be designed for, and benchmarked against:

1. Hundreds of thousands to millions of small source files.
2. Hundreds of thousands of commits.
3. Repositories with large binary files modified repeatedly.
4. Monorepos where only a subset of paths is needed locally.
5. Frequent branching, rebasing, and ref movement.
6. Cold remote storage with a warm local cache.
7. Interrupted uploads and multi-device access.

## Product principles

### Compatibility is a boundary contract

Relay may use a different internal representation, but imported and exported Git histories must remain verifiable.

### The backend is untrusted and dumb

A backend stores and retrieves opaque immutable objects. It should not be required to understand refs, commits, locks, Git, or Relay internals.

### Immutable data, explicit mutable state

Large data segments should be immutable. Mutable refs should be represented by small, journaled, signed state transitions.

### Recovery is a first-class feature

A user must be able to inspect, verify, repair, and export a repository without relying on a Relay-hosted service.

### Benchmarks must include modern Git

Relay must not compare itself only with naive Git defaults. Baselines should include partial clone, sparse checkout, maintenance, Git LFS, and other relevant configurations.

### Correctness outranks speed

A faster remote that can corrupt repositories is not useful.

## Product split

Relay is the adoption-oriented project.

A separate project, Loom, explores a new VCS model and deliberately does not inherit Relay's compatibility constraints. Do not merge the two codebases or product narratives early. Shared research is acceptable; shared production code should occur only after stable interfaces exist.
