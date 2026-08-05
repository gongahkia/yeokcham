# ADR-0034: Reject unsupported Git object hash formats during repository opening

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The initial Yeokcham Git identity type is exactly a 20-byte SHA-1 object ID, and the verified-read path computes only the SHA-1 canonical object identity. `gix` can open SHA-256 repositories because the adapter enables both Git hash implementations. Deferring the format check until reference traversal or object reads makes an apparently valid repository handle unusable later and can expose unsupported identifiers through lower-level paths.

## Decision drivers

- Reject unsupported formats before returning a usable repository adapter.
- Keep the public Git identity and verification model internally consistent.
- Do not silently truncate or reinterpret 32-byte SHA-256 object IDs.
- Preserve ordinary SHA-1 repository behavior.
- Keep an explicit extension point for a later versioned SHA-256 identity model.

## Considered options

### Accept all formats and reject individual operations

This permits callers to enumerate refs from a repository whose object identities cannot be represented or verified by the current API. It produces late, inconsistent failures.

### Convert SHA-256 IDs into SHA-1 IDs

SHA-256 object names and object contents use a different hash-sized representation. Any local conversion would need Git's compatibility mapping and an explicit format contract; it cannot be inferred by truncating or rehashing an ID.

### Reject non-SHA-1 formats at adapter opening

This makes the current compatibility boundary explicit before a handle can expose refs or objects.

## Decision

After isolated `gix` opening succeeds, `GitRepository::open` inspects the configured object hash. Only `gix::hash::Kind::Sha1` is accepted. Any other configured hash fails with the stable `unsupported` error `Git repository uses an unsupported object hash` without disclosing the supplied path or repository configuration.

The later traversal and object-read checks remain defensive checks around 20-byte object IDs and object storage. They are not the primary policy boundary.

## Consequences

Callers get one early, machine-classified failure for a SHA-256 repository. No returned `GitRepository` can represent an object ID that violates the current `GitObjectId` invariant. SHA-256 Git import, verification, export, and compatible metadata must arrive together in a future versioned compatibility slice.

## Invariants

- Every returned `GitRepository` uses Git SHA-1 object names.
- A 32-byte Git object ID is never parsed, truncated, or persisted as a `GitObjectId`.
- Unsupported hash format is an error, never a warning or fallback.
- Default diagnostics disclose neither input paths nor object IDs.
- SHA-1 detection happens before ref enumeration, graph traversal, or object-body reads.

## Compatibility and migration

This does not change Yeokcham's persisted repository format. It formalizes the existing 20-byte `GitObjectId` and SHA-1 verified-read limitations at adapter open. Supporting SHA-256 requires a new versioned object-identity abstraction, canonical SHA-256 verification, SQLite schema compatibility review, object/pack export policy, and migration tests; this ADR does not prescribe that representation.

## Security and recovery

Failing early prevents unsupported object IDs from entering local metadata or later storage paths. The policy does not claim SHA-1 collision resistance; SHA-1 remains only the required compatibility identifier for supported Git repositories. No recovery state changes because unsupported repositories are not imported.

## Verification

C Git fixtures create SHA-256 bare and worktree repositories with `git init --object-format=sha256`; both fail at `GitRepository::open` as `unsupported` without path disclosure. Existing C Git SHA-1 bare/worktree, ref, traversal, bounded-read, and canonical-verification tests continue to pass. Full formatting, lint, test, documentation, and macOS/Linux Rust 1.85 CI run before acceptance.
