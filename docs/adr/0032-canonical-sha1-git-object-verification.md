# ADR-0032: Verify SHA-1 Git objects from canonical header and body bytes

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Reading an object by a filesystem or pack index key does not make its bytes trustworthy. Yeokcham's SHA-1 compatibility boundary must independently prove that the returned type and decompressed body name the requested Git object before any import path can acknowledge it.

## Decision drivers

- Match ordinary Git's SHA-1 object identity exactly.
- Avoid reusing storage-path or library lookup success as verification.
- Stream canonical components into the hash without creating an additional combined buffer.
- Keep object-body access separate from verified-import admission.
- Preserve redacted diagnostics on mismatches.

## Considered options

### Trust the object database lookup key

This accepts a malformed, substituted, or incorrectly indexed body without independent evidence that it matches the requested ID.

### Hash only the decompressed body

This collides across Git object types and does not match Git object IDs.

### Hash Git's canonical header and body

This matches Git's defined SHA-1 object naming input and permits independent verification for every object type.

## Decision

`GitObject::recompute_id` computes SHA-1 over the byte sequence `"<type> <decimal-size>\\0"` followed by the exact decompressed body. `GitObject::verify_id` compares that result with the requested `GitObjectId` and fails with `corrupt_data` on mismatch.

`GitRepository::read_verified_object` composes the prior bounded-read API with this verification. Callers that will import or persist source objects use the verified method; the unverified read API remains available only where explicitly needed for diagnostics or controlled repair flows.

## Consequences

Git object type and exact body are cryptographically bound to the SHA-1 compatibility ID before later storage code consumes them. The implementation adds a direct SHA-1 dependency whose version is locked with the workspace. SHA-256 remains unsupported until the Git identity model is extended, rather than being silently misverified.

## Invariants

- The canonical header uses exactly `blob`, `tree`, `commit`, or `tag`; one ASCII space; decimal byte length; and one NUL byte.
- The hash input contains the unmodified decompressed body exactly once.
- A verified object’s requested ID equals its recomputed SHA-1 ID.
- A mismatch is never downgraded to a warning or accepted for persistence.
- Default verification errors do not disclose IDs or object bodies.

## Compatibility and migration

This adds no persistent format. It verifies only existing 20-byte SHA-1 `GitObjectId` values. SHA-256 verification will require a future versioned identity extension and explicit migration policy.

## Security and recovery

Independent recomputation detects substituted loose-object bytes and incorrect object-database mappings before trust. It is not a collision-resistance upgrade: SHA-1 is retained solely for Git compatibility. Yeokcham content identities and remote integrity use separately selected algorithms. Recovery can re-verify any exported or imported SHA-1 object from its canonical bytes.

## Verification

Unit tests verify Git's known empty-blob ID and reject altered body bytes. Adapter integration tests read packed blob, tree, commit, and annotated-tag bodies produced by C Git through `read_verified_object`, then overwrite a loose object at another object's path and verify rejection. CI runs lint, tests, and docs on macOS and Linux Rust 1.85.
