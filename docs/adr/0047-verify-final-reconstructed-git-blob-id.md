# ADR-0047: Verify final reconstructed Git blob identity

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Exact-body reconstruction is necessary but not a final Git compatibility proof. Storage representations can evolve to chunk lists, compression, encryption, or streaming, so the exported body must be bound to the manifest Git object ID at the final reconstruction boundary.

## Decision drivers

- Verify canonical Git SHA-1 over the exact body returned to callers.
- Preserve a clear distinction between bytes and a trusted Git object.
- Keep representation-local checks as defence in depth, not the only final proof.
- Return no object after an identity mismatch.

## Considered options

### Trust record-level Git ID checks

Current whole and tiny records do this, but it would make future representation changes silently weaken final reconstruction verification.

### Recompute only in export code

Recovery and other callers could bypass it, producing divergent trust boundaries.

### Construct and verify a Git blob in the repository API

The common reconstruction API can recompute the canonical `blob <size>\0<body>` SHA-1 before returning a `GitObject`.

## Decision

`LocalRepository::reconstruct_blob` first obtains exact bytes with `reconstruct_blob_bytes`. It constructs a blob `GitObject` using the manifest Git ID, then calls `GitObject::verify_id`. The method returns the object only when its recomputed canonical Git SHA-1 equals that ID; mismatch is `CorruptData` and does not disclose the body.

This adds no persistent bytes or implicit cache. The raw-byte method remains available for callers that explicitly need bytes, while callers requiring a trusted Git object use this final verification boundary.

## Consequences

Export, verification, and later remote-helper code have one representation-independent verified blob constructor. Version-1 storage performs duplicate identity checks, which is intentional defence in depth. Future formats must route their final bytes through this method or provide an equivalent documented verified boundary.

## Invariants

- A returned reconstructed `GitObject` has kind `Blob`.
- Its ID exactly equals the manifest Git blob ID.
- Its canonical Git SHA-1 exactly equals that ID.
- Its body equals the exact selected reconstructed body.
- An identity mismatch returns no object and discloses no body bytes.

## Compatibility and migration

No persistent format changes. Git SHA-256 repositories remain unsupported under the existing repository policy. A future Git hash-format migration requires a versioned object-ID and final-verification contract.

## Security and recovery

Final verification detects corruption or representation-selection mistakes that survive earlier boundaries. SHA-1 is used solely for Git compatibility identity; it does not authenticate remote storage. Authentication and encryption remain later format work.

## Verification

Tests reconstruct and verify a binary blob through the public API, exercise the final mismatch helper, and check redacted failure text. Full formatting, lint, tests, docs, and macOS/Linux Rust 1.85 CI run before acceptance.
