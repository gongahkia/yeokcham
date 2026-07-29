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
