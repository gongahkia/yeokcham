# ADR-0031: Read bounded Git object bodies separately from ID verification

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

After traversal identifies a reachable object ID, import must obtain its exact Git type and decompressed body. Git object storage is hostile: a loose object or packed delta can claim a large decoded size. The current compatibility identity supports SHA-1 only, and the next task must independently recompute the canonical Git object ID before trusting bytes.

## Decision drivers

- Preserve the exact body bytes required for later canonical ID verification.
- Retain the Git object type without exposing `gix` types publicly.
- Check the decoded object size before body allocation.
- Give each caller an explicit memory bound.
- Keep reading distinct from the following verification task.

## Considered options

### Return library object handles

This exposes dependency lifetimes and types at Yeokcham's public boundary and makes controlled ownership difficult.

### Return canonical loose-object bytes including the header

This conflates reading with canonical-ID construction and makes raw body access less direct for storage policies.

### Return a typed decompressed body after a header size check

This preserves exact input for later verification while making the allocation bound explicit.

## Decision

`GitRepository::read_object` accepts a SHA-1 `GitObjectId` and caller-supplied maximum body size. It reads the object header first, rejects a larger body before decompression, then returns a Yeokcham-owned `GitObject` containing the requested ID, `GitObjectKind`, and exact decompressed body. It compares the post-read type and body length with the inspected header.

The method does not include the canonical `"<type> <size>\\0"` header in `GitObject::data` and does not recompute the ID. Missing objects fail with `not_found`; malformed read state fails with `corrupt_data`; over-limit objects and non-SHA-1 repositories fail with `unsupported`.

## Consequences

Storage policy code receives the original Git object body and type without `gix` ownership or lifetime coupling. Import callers must choose a size budget. A later verification step must hash the canonical header plus body before any object is acknowledged or persisted.

## Invariants

- `GitObject::data` is the exact decompressed body, never a textual rendering.
- `GitObject::kind` is one of Git's four object types.
- Header size must not exceed the caller's supplied bound.
- The post-read type and length must match the inspected header.
- The requested ID is metadata until independent recomputation succeeds.
- Default `Debug` and errors do not disclose object body bytes or IDs.

## Compatibility and migration

This introduces no persistent format. It is available only for SHA-1 repositories represented by the current `GitObjectId` type. SHA-256 support requires a separately versioned compatibility extension.

## Security and recovery

The header check bounds ordinary decompression requests according to the caller's memory budget. A concurrently modified hostile repository can still race the header and body reads; the type/size consistency check rejects changed data, and later ID verification remains mandatory. No Yeokcham recovery state depends on an unverified source read.

## Verification

Tests create a binary blob, tree, commit, and annotated tag with C Git, pack them with `git gc`, and compare every returned body byte and type to `git cat-file <type> <id>`. Tests reject a configured size limit and a missing ID without default disclosure. Unit tests cover body accessors, redacted `Debug`, and thread-safety. CI runs these tests on macOS and Linux.
