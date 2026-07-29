# ADR-0020: Use tagged, configurable content identities

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Yeokcham deduplicates plaintext content before encryption and must verify reconstructed records before trust. A single implicit hash algorithm would make algorithm changes ambiguous. Keyed hashing reduces equality disclosure outside a repository but makes verification and recovery depend on key material. The existing milestone order does not provide recoverable repository keys until Milestone 5.

## Decision drivers

- Every content identity must state how its digest was produced.
- Readers must distinguish mixed algorithms without repository-global reinterpretation.
- Keyed identities must be scoped to one repository by default.
- Early storage work must not invent an unsafe temporary key lifecycle.
- Algorithms must use maintained implementations of published constructions.

## Considered options

### One implicit algorithm

This keeps IDs short but makes algorithm changes repository-wide migrations and allows configuration loss to reinterpret stored digests.

### One tagged algorithm per repository

Tagging removes ambiguity, but forcing one algorithm forever prevents incremental policy changes and requires full migrations.

### Tagged identities with a write policy

Each identity carries its algorithm. Repository configuration selects the algorithm for new content while readers continue to accept recognized existing tags.

## Decision

`YeokchamContentId` contains a `ContentHashAlgorithm` and a 32-byte digest. Supported tags are `hmac-sha256`, `blake3-keyed`, `sha256`, and `blake3`. HMAC follows [RFC 2104](https://www.rfc-editor.org/rfc/rfc2104); SHA-256 follows [FIPS 180-4](https://csrc.nist.gov/pubs/fips/180-4/upd1/final); BLAKE3 uses its published [specification](https://github.com/BLAKE3-team/BLAKE3-specs/blob/master/blake3.pdf).

Canonical text is `<algorithm>:<64-lowercase-hex>`. The algorithm is part of equality and ordering. Configuration selects only the algorithm for new writes; changing it does not reinterpret or rewrite existing IDs.

Before the recoverable key lifecycle exists, early repositories default to `sha256`, and keyed algorithms cannot be activated. At Milestone 5, new repositories default to `hmac-sha256`; `blake3-keyed`, `sha256`, and `blake3` remain selectable. Existing repository defaults do not change automatically.

Keyed algorithms use repository-scoped content-identity key material. Their algorithm-specific keys must be domain-separated when the key hierarchy is implemented. Content identity key loss prevents recomputation and full verification of keyed IDs.

## Consequences

Mixed algorithms remain unambiguous and can coexist. The same plaintext under different algorithms has different identities and may be stored more than once. Keyed modes reduce repository-external equality disclosure but add key recovery requirements. Every index and manifest carrying a content ID must preserve its algorithm tag.

## Invariants

- A content ID always combines one recognized algorithm with exactly 32 digest bytes.
- Reconstructed content is rehashed using the tagged algorithm before trust.
- Keyed content IDs are never computed without the repository-scoped key.
- Changing the write policy never changes an existing content ID.
- Content identity is distinct from Git object, segment, and manifest identity.

## Compatibility and migration

This defines the type before a persistent repository format exists. The later serialization-policy ADR must assign stable binary algorithm tags and encode the digest without ambiguity. Algorithm-policy changes require no immediate rewrite because existing IDs are self-describing. A future full migration may rehash and rewrite reachable content explicitly.

## Security and recovery

Content IDs are metadata and must not appear in default diagnostics. Unkeyed modes expose equality and permit confirmation attacks for predictable content if IDs are disclosed. Keyed modes depend on export and recovery of repository key material; they are unavailable until that lifecycle exists. Neither mode replaces authenticated encryption or final Git object verification.

## Verification

Core tests cover canonical names, keyed classification, all textual round trips, malformed and unsupported input, mixed-algorithm inequality, fixed digest length, and redacted diagnostics. Hash implementations require published known-answer tests when introduced. CI verifies the type on the MSRV and stable Rust.
