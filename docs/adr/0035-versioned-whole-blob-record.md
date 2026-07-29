# ADR-0035: Store verified small-slice blobs as canonical whole-blob records

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Milestone 1 needs the simplest storage representation before aggregation, content-defined chunking, compression, segments, and manifests. A whole-blob record must preserve exact Git blob bytes, bind those bytes to the original Git object ID, carry a plaintext content identity for future indexing, and remain unambiguous when later record types are introduced.

## Decision drivers

- Preserve exact bytes and independently verify both Git and storage identities.
- Follow the global canonical binary policy with explicit version and feature fields.
- Keep decoding bounded before it allocates a blob body.
- Avoid inventing compression, encryption, chunking, or key lifecycle ahead of their milestones.
- Implement ADR-0020's early unkeyed SHA-256 write policy without reinterpreting future tags.

## Considered options

### Store raw blob bytes alone

This preserves bytes but loses type/version information and allows substituted content to be accepted until a later manifest check.

### Serialize a generic object wrapper

This would mix blob policy with commit/tree/tag storage before their different reconstruction needs are designed.

### Whole-blob-specific canonical record

A narrow blob record gives an independently testable baseline and leaves aggregation, chunking, compression, segment framing, and manifests as explicit later layers.

## Decision

Introduce `WholeBlobRecord`, encoded as the `YKWB` version-1 record documented in [`serialization.md`](../serialization.md). It has zero required/optional feature bits, record type `1`, compression method `0` (`none`), a one-byte content-hash tag, raw 20-byte Git SHA-1 blob ID, raw 32-byte plaintext content digest, and a canonical length-delimited exact body.

`WholeBlobRecord::from_verified_blob` accepts only a Git object of type `blob` and independently verifies its canonical Git SHA-1 ID before creating the record. It computes an unkeyed SHA-256 plaintext content ID. Binary algorithm tags reserve `1` for HMAC-SHA-256, `2` for keyed BLAKE3, `3` for SHA-256, and `4` for BLAKE3; version 1 writes and decodes only tag `3`.

`WholeBlobRecord::decode` receives both an already bounded encoded slice and a maximum body length. It validates every field, makes no body allocation until the decoded length is within the supplied bound, then recomputes the Git blob ID and SHA-256 content ID before returning data.

## Consequences

Small blobs can enter a versioned byte-preserving record representation immediately. The record is not yet a sealed segment, manifest, or remote object and therefore does not claim crash-safe persistence or recovery by itself. Callers must use later segment/manifests before acknowledging imported storage. SHA-256 is a direct dependency; BLAKE3 and keyed algorithms remain deliberately unavailable in this record version.

## Invariants

- A record body is exactly one verified Git blob body, never a commit, tree, or tag body.
- The Git ID is exactly the SHA-1 canonical `blob <length>\0<body>` identity.
- The version-1 content ID is exactly unkeyed SHA-256 over the raw body.
- Feature bits are zero; nonzero bits are not silently ignored.
- Unknown/future content tags, compression, versions, and malformed records fail closed.
- A decode cannot allocate more body bytes than its caller-supplied limit.
- Default `Debug` and error output do not disclose blob bytes or IDs.

## Compatibility and migration

`YKWB` version 1 is immutable once written. Later compression, encryption, keyed identities, BLAKE3, segment framing, or feature semantics require a new version or explicit feature/migration contract. Reserved content-tag values never change. This does not alter the V1 repository bootstrap or SQLite schema.

## Security and recovery

The record verifies two independent identities before data is trusted: the Git compatibility ID and the configured early storage content ID. SHA-256 content IDs are unkeyed and therefore expose equality if disclosed; ADR-0020 defers keyed modes until recoverable keys exist. The record contains plaintext and must not be uploaded to an untrusted backend before the later encryption layer. It is only recoverable when a later manifest/segment design references durable bytes.

## Verification

Tests assert the complete canonical encoding for Git's empty blob, round-trip binary body bytes, validate stable tag mapping, redact debug output, reject non-blob and unverified inputs, reject each header/body identity corruption path, reject unsupported version/features/compression/content tags, reject trailing/truncated records, and enforce body limits. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
