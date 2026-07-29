# ADR-020 — Stored-object identity and immutable publication

- Status: Accepted
- Date: 2026-07-30
- Deciders: maintainer (approved 2026-07-30)
- Supersedes: None
- Superseded by: None

## Context and problem statement

ADR-018 deliberately leaves stored-object identity and publication unspecified. Milestone 1 needs a local immutable object store without equating an Envelope checksum with an object identity or permitting an atomic rename to replace an existing object.

## Decision drivers

- Keep stored-object IDs distinct from semantic snapshot, checkpoint, capsule, and release IDs.
- Address only canonical, verified Envelope 1 bytes.
- Publish a complete object without an overwrite race.
- Make restart and concurrent publication deterministic.
- Keep format evolution explicit.

## Considered options

### Hash the envelope checksum

- Reuses a digest already in the envelope.
- The checksum has a different preimage and does not bind the complete object representation.

### Hash exact Envelope 1 bytes with a domain prefix

- Binds the full typed, versioned envelope and separates this format-specific identity from other SHA-256 uses.
- Requires a distinct stored-object ID type and an explicit migration at an Envelope-version transition.

### Temporary write followed by overwriting rename

- Is a common atomic-replace pattern.
- Can silently replace an immutable final object when concurrent writers race.

### Temporary write followed by hard-link publication

- Creates the final name only when absent and lets an existing final object be verified idempotently.
- Requires hard-link support and directory fsync support for strongest local durability.

## Decision outcome

`Stored_object_id` is:

```text
SHA-256("paengi:object:v1\\000" || exact canonical Envelope-1 bytes)
```

It is a 32-byte abstract type, rendered as exactly 64 lowercase hexadecimal characters. It is not interchangeable with Paengi semantic IDs.

The path is built only from a validated typed ID:

```text
.paengi/objects/<hex[0:2]>/<hex[2:4]>/<hex[4:64]>
```

The repository `format` record is exact, versioned text recording repository format `1`, `sha256`, Envelope version `1`, and object-format version `1`. Readers fail closed on a different record.

Publication is:

1. Create checked directory shards.
2. Exclusively create a unique regular temporary file in the final shard.
3. Write the complete Envelope-1 bytes, fsync it, and close it.
4. Hard-link the temporary file to the final path.
5. Fsync the shard directory after successful link publication.
6. Remove the temporary name and fsync the shard directory again where supported.

If the final path exists, read it, verify its envelope and stored-object identity, and compare its exact bytes with the proposed bytes. Equal bytes make `put` idempotent; a mismatch is a structured collision-or-corruption error. The store never overwrites or repairs an object. It never falls back to overwriting rename when hard links are unavailable.

## Consequences

- The object checksum and stored-object ID have different preimages and purposes.
- Incomplete temporary files are never addressable as final objects. Stale temporary files can remain after a crash and are ignored on reopen.
- A crash after link publication but before temporary cleanup leaves a valid final object.
- The initial adapter requires a local filesystem that supports hard links within a shard directory. Unsupported link publication returns a structured error.
- Directory fsync is attempted after publication and cleanup. Filesystems that report directory fsync unsupported have weaker crash-durability guarantees; this is surfaced as a documented platform limitation, not replaced by an unsafe overwrite.

## Model and invariant impact

The store owns an abstract `Stored_object_id` and a repository handle. Its invariants are:

- A successful `put` names exactly the domain-separated SHA-256 of its exact Envelope-1 bytes.
- A successful `get` verifies both the object ID and Envelope integrity before returning a payload.
- A typed ID is the only input accepted for object-path construction.
- Final object paths are immutable and idempotent only for byte-identical objects.
- Snapshot, checkpoint, capsule, revision, release, and conflict identities remain separate model types.

## Persistent-format and migration impact

This introduces repository-format `1`; no prior object store exists, so no data migration is required. Existing Envelope-1 and model golden fixtures remain unchanged.

An Envelope version or stored-object preimage change deliberately produces different IDs. It requires a new ADR, retained readers and fixtures, and either coexistence of object namespaces or an atomically published migration generation. Existing objects are never rewritten in place.

## Verification

- Unit tests for repository-format rejection, exact typed-ID rendering, paths, init/reopen, idempotent put, and exact round trip.
- Deterministic generated properties for independent `put`/reopen/get round trips and idempotent identity.
- Failure tests for malformed IDs, non-directory repository paths, corrupted final bytes, and divergent existing final paths.
- Restart coverage with stale temporary files and a final object retained after reopening.
- No golden stored-object fixture is added in this slice because the store preserves existing Envelope-1 bytes unchanged; content/tree/snapshot schemas add their own golden fixtures.
- Hard-link and directory-fsync behavior is tested on the local supported filesystem; no cross-filesystem durability claim follows.

## CLI and user impact

No CLI command is introduced. Future `paengi verify` and storage inspection report stored-object IDs separately from semantic identities and return structured format, integrity, collision, and unsupported-publication errors.
