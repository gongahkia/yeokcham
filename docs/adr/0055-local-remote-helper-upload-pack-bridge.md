# ADR-0055: Serve local clone and unchanged fetch through an upload-pack bridge

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The local store can verify and export every object and ref, but C Git had no transport path to clone it. Native pack synthesis would introduce a large pack-format implementation before proving remote-helper correctness.

## Decision

Provide `git-remote-yeokcham`. It parses bounded newline-delimited commands, advertises only the mandatory `connect` capability, and accepts only `connect git-upload-pack`. For that request it opens and verifies the supplied local Yeokcham repository, exports it into a private temporary bare Git repository, sends the required empty connection response, and delegates the smart protocol and pack stream to `git upload-pack`.

The helper deliberately does not advertise `fetch`, `push`, `import`, `export`, `option`, or `connect git-receive-pack`. C Git performs ref discovery through the connected upload-pack service. Unsupported or oversized protocol commands fail with classified, source-redacted errors.

## Consequences

Ordinary Git can list refs, clone, retrieve annotated tags, and repeat an unchanged fetch from an immutable local Yeokcham store. Each connection regenerates a temporary loose-object export, so this is correctness-first and may be slow or disk-intensive. It does not implement mutable ref updates, shallow handling, push, native pack caching, or native pack synthesis.

## Invariants

- The helper sends a connection acknowledgment only after the local store has verified and exported successfully.
- Every served object is reconstructed and Git-ID verified by existing export logic before C Git writes a pack.
- The helper executes only the fixed `git upload-pack` subcommand with a helper-created path.
- Protocol command allocation is bounded to 8 KiB.
- Source paths, object bytes, and temporary paths are absent from normal and debug helper telemetry.

## Compatibility and migration

This adds an executable and no persisted Yeokcham format. The temporary export is disposable and deleted when the helper process exits. Native pack synthesis can replace this bridge only through a new ADR while preserving the Git-visible protocol.

## Security and recovery

The helper creates its temporary parent with owner-only permissions on Unix, does not trust cache state, fully verifies storage before acknowledgment, and uses a fixed child command without shell interpolation. Cleanup is best effort; an interrupted process can leave a private disposable export. Recovery of the source Yeokcham store does not depend on the temporary export.

## Verification

Unit and fuzz-smoke tests cover accepted, unsupported, truncated, oversized, and arbitrary protocol commands plus capability output. Integration tests exercise `git ls-remote`, clone, branch and tag visibility, object-ID and checkout equivalence, `git fsck --full --strict`, unchanged fetch, and debug-log source-location redaction.
