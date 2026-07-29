# ADR-0051: Publish one immutable local ref snapshot before journals

- Status: Accepted
- Date: 2026-07-30
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Published local objects can be reconstructed and exported, but current storage retained no portable regular-ref targets or `HEAD`. SQLite is disposable and a ref journal belongs to the later push and reconciliation milestone. Conventional recovery needs named roots now without treating mutable ref state as a filesystem overwrite.

## Decision drivers

- Preserve regular ref targets and `HEAD` in a portable versioned record.
- Refuse ambiguity, unavailable targets, and partial publication.
- Keep the temporary bridge separate from Milestone-3 journal semantics.
- Preserve raw refname bytes on macOS and Linux.

## Considered options

### Defer refs until journal implementation

This leaves every current export ref-less and cannot satisfy the local round-trip path.

### Store refs only in SQLite

SQLite deletion would remove recovery-critical state and violates the portable recovery requirement.

### Publish one immutable checked snapshot

This records the import-time state without defining mutable update, reconciliation, or signature semantics.

## Decision

Use one immutable `YKRF` V1 snapshot at `manifests/refs/<snapshot-uuid>.ykrf`. It binds the repository ID, snapshot UUIDv4, sorted direct targets for all regular `refs/*` names, and a symbolic or detached `HEAD`. Symbolic regular refs are flattened to their direct object target; `HEAD` retains its Git-visible symbolic or detached form. A symbolic `HEAD` may name an unborn branch.

Before publication, every direct target is reconstructed and has its Git ID verified under caller-provided limits. Publication uses a synchronized same-directory staging file and a no-replacement hard link. Exactly one final snapshot is accepted; duplicate snapshots are a conflict. Existing repositories remain valid with no snapshot.

Loose-object export restores the snapshot only after every direct target has been exported. Regular refs are create-new files; `HEAD` replaces the bare repository's initialization value only inside the newly created export destination.

## Consequences

Local import/export can retain named roots before journal work. Current V1 allows no ref mutation, deletion, concurrent reconciliation, signatures, or multi-device state. A failed export can retain an incomplete destination, which the caller must discard.

## Invariants

- Snapshot refnames are validated raw `refs/*` bytes and strictly sorted.
- Every regular and detached `HEAD` target is reconstructable before the snapshot is acknowledged.
- A successful export writes no ref whose target was not exported.
- Snapshot files are immutable and no reader selects between multiple snapshots.
- SQLite is not used to publish, resolve, verify, or restore refs.

## Compatibility and migration

`YKRF` V1 adds an optional `manifests/refs/` directory and leaves `YKRB`, `YKSG`, `YKIX`, `YKMF`, and `YKOM` unchanged. Existing repositories without this directory open and export objects as before. Journal introduction must use new immutable journal records and a documented reader precedence/migration path; it must not overwrite the snapshot.

## Security and recovery

Snapshots are hostile input: directory, file, entry, byte, and allocation bounds apply before trust; symlinks, malformed names, foreign IDs, invalid order, bad checksums, and duplicate finals fail closed. SHA-256 detects accidental corruption but does not authenticate a remote backend. Diagnostics redact ref names and object IDs by default. The record is plaintext local metadata until the later encryption layer.

## Verification

Tests cover canonical symbolic and detached encodings, checksums and limits, Git-adapter extraction, unavailable-target rejection, idempotent/conflicting publication, full local verification, symbolic and detached bare-export restoration, and C Git reopening of restored refs. Full formatting, lint, tests, docs, and Linux Rust 1.85 CI run before acceptance.
