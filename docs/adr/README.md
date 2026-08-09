# Architecture Decision Record Process

Use an ADR for decisions that constrain the model, persistent format, component boundaries, dependencies, security, compatibility, or irreversible implementation direction. Routine implementation details do not require one.

## Lifecycle

1. Copy `TEMPLATE.md` to `NNNN-kebab-case-title.md` using the next unused ID.
2. Set status to `Proposed` and complete every required section before implementation.
3. Link the proposal from `DECISIONS.md` and the governing GitHub issue.
4. Resolve material objections and record rejected alternatives.
5. Set status to `Accepted` when maintainer review approves the decision.
6. Implement only after acceptance, then add verification and migration evidence.

Allowed statuses are `Proposed`, `Accepted`, `Rejected`, and `Superseded by ADR-NNN`.

Accepted and rejected ADRs are immutable except for status links, factual corrections, and verification evidence. Replace a decision with a new ADR; mark the old record `Superseded by ADR-NNN` and link back from the replacement. Never delete or reuse an ADR ID.

## Numbering and index

- ADR IDs are repository-wide, monotonic, and zero-padded to three digits in headings.
- ADR-001 through ADR-015 are accepted legacy records in `DECISIONS.md`.
- File-backed ADRs begin at ADR-016.
- `DECISIONS.md` is the canonical index and must link every file-backed ADR.
- The current highest file-backed ADR is ADR-057; its status and policy are
  listed in `DECISIONS.md`.

## Required analysis

Every proposal states:

- Context and problem.
- Decision drivers and considered options.
- Decision outcome and consequences.
- Effects on algebraic types and invariants.
- Persistent-format versioning, compatibility, and migration effects.
- Required unit, property, failure, golden-fixture, and benchmark evidence.
- CLI or user-visible effects.

Use `Not applicable` with a reason when a required area has no impact.
