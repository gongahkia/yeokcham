# Architecture Decision Records

Yeokcham records architecturally significant choices as version-controlled ADRs. The initial ADR-001 through ADR-015 remain in [`DECISIONS.md`](../../DECISIONS.md). New records use this directory and continue at ADR-0016.

## When to write an ADR

Write one before implementing a decision that changes persistent formats, security or cryptographic design, compatibility boundaries, crate or service architecture, public interfaces, durability semantics, or major dependencies. Routine implementation details do not need an ADR.

## Process

1. Copy [`0000-template.md`](0000-template.md) to `NNNN-kebab-case-title.md` using the next unused four-digit number.
2. Set the status to `Proposed` and document context, considered options, the decision, consequences, invariants, compatibility, migration, security, recovery, and verification.
3. Submit the ADR with or before its implementation. Review must resolve correctness, recovery, format-version, and migration effects.
4. Change the status to `Accepted` or `Rejected` when the decision is resolved.
5. Do not rewrite an accepted or rejected decision. Later changes require a new ADR; mark the old record `Superseded by ADR-NNNN` and link both records.

Valid statuses are `Proposed`, `Accepted`, `Rejected`, `Deprecated`, and `Superseded by ADR-NNNN`. Numbers are never reused, including for rejected or superseded records.

## Index

| ADR | Status | Decision |
| --- | --- | --- |
| [ADR-001–ADR-015](../../DECISIONS.md) | Accepted | Initial architecture decisions |
| [ADR-0016](0016-structured-error-contract.md) | Accepted | Use an opaque structured core error contract |
| [ADR-0017](0017-allowlisted-structured-tracing.md) | Accepted | Use allowlisted structured tracing |
| [ADR-0018](0018-versioned-benchmark-result-schema.md) | Accepted | Use a versioned JSON Schema for benchmark results |
| [ADR-0019](0019-repository-id-as-uuid-v4.md) | Accepted | Represent repository IDs as UUIDv4 bytes |
| [ADR-0020](0020-tagged-content-identities.md) | Accepted | Use tagged, configurable content identities |
| [ADR-0021](0021-segment-id-as-uuid-v4.md) | Accepted | Represent segment IDs as UUIDv4 bytes |
| [ADR-0022](0022-manifest-id-as-uuid-v4.md) | Accepted | Represent manifest IDs as UUIDv4 bytes |
| [ADR-0023](0023-device-id-as-uuid-v4.md) | Accepted | Represent device IDs as UUIDv4 bytes |
| [ADR-0024](0024-byte-preserving-git-refnames.md) | Accepted | Preserve validated Git refname bytes |
| [ADR-0025](0025-repository-format-compatibility.md) | Accepted | Version repository formats with required and optional flags |
| [ADR-0026](0026-canonical-binary-serialization.md) | Accepted | Use fixed-width canonical binary serialization |
| [ADR-0027](0027-local-repository-bootstrap.md) | Accepted | Store the V1 repository bootstrap as canonical binary |
| [ADR-0028](0028-gitoxide-repository-adapter.md) | Accepted | Open Git repositories through a minimal gitoxide adapter |
| [ADR-0029](0029-bounded-regular-ref-enumeration.md) | Accepted | Enumerate bounded regular Git refs by raw bytes |
| [ADR-0030](0030-bounded-reachable-git-object-traversal.md) | Accepted | Traverse bounded reachable SHA-1 Git objects |
| [ADR-0031](0031-bounded-git-object-body-reads.md) | Accepted | Read bounded Git object bodies before trust |
| [ADR-0032](0032-canonical-sha1-git-object-verification.md) | Accepted | Verify SHA-1 Git objects from canonical header and body bytes |
| [ADR-0033](0033-local-sqlite-object-metadata.md) | Accepted | Store verified Git object metadata in a local versioned SQLite database |
| [ADR-0034](0034-reject-unsupported-git-object-hashes-at-open.md) | Accepted | Reject unsupported Git object hash formats during repository opening |
