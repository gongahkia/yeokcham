# Instructions for Coding Agents

## Mission

Implement Paengi as a model-first, local-first experimental VCS.

The primary contribution is not a new command spelling or a faster Git clone. It is the separation of scratch, intent, and release history.

## Required reading order

1. `README.md`
2. `PROJECT_CONTEXT.md`
3. `PRD.md`
4. `FORMAL_MODEL.md`
5. `ARCHITECTURE.md`
6. `DECISIONS.md`
7. `RESEARCH_QUESTIONS.md`
8. `TESTING_AND_EXPERIMENTS.md`
9. `TODO.md`

## Working rules

### 1. Protect the model

Do not collapse:

- Checkpoint into capsule.
- Capsule into revision.
- Revision into release.
- Conflict into process error.
- Semantic sidecar into canonical source.

### 2. Implement the functional core first

For each feature:

1. Define algebraic types.
2. Define invariants.
3. Implement pure transition.
4. Add property tests.
5. Add persistent adapter.
6. Add CLI.

### 3. Work one milestone at a time

Do not start:

- Semantic parsing.
- Git import/export.
- Networking.
- Signing.
- UI.

before exact snapshots, scratch restore, and compaction work.

### 4. Avoid fake intelligence

Paengi may propose capsule grouping or semantic operations, but it must not claim to know user intent automatically.

Ambiguity becomes:

- A proposal.
- A confidence value.
- A conflict.
- A request for explicit user choice.

### 5. No semantic-only storage

Every source operation needs a byte-correct representation or fallback.

### 6. Update documents

Before coding:

- State current milestone.
- State vertical slice.
- List types and invariants.
- List tests.
- Identify ADR changes.

After coding:

- Update TODO.
- Update formal model if semantics changed.
- Add golden fixtures for persistent format.
- Record experiment results separately from claims.

### 7. Testing standard

Every core transition should have:

- Unit tests.
- Generated tests.
- Failure tests where persistence is involved.
- A clear invariant.

### 8. Persistent format discipline

- No OCaml `Marshal`.
- Version every record.
- Canonical ordering.
- Reject unknown mandatory features.
- Keep old-format fixtures.
- Never mutate the only copy in place.

### 9. Commit discipline

Small commits should identify:

- Model change.
- Invariant.
- Test.
- Persistent format impact.

Do not mix model changes with unrelated CLI redesign.

## Suggested initial commands

```bash
paengi init
paengi scan
paengi timeline
paengi restore <checkpoint>
paengi pin <checkpoint>
paengi compact --dry-run --explain
paengi verify
paengi storage stats
```

Capsule commands come after scratch compaction is correct.

## First vertical slice

Implement an in-memory model that:

1. Represents a simple directory snapshot.
2. Applies create, modify, delete, move, and mode-change operations.
3. Produces checkpoint identities.
4. Restores any checkpoint model.
5. Generates random operation sequences.
6. Proves replay reaches the expected snapshot.

Only then persist one snapshot and materialise it to disk.

## Definition of done

A task is done when:

- The algebraic model is explicit.
- Invariants are documented.
- Tests cover generated and edge cases.
- Persistent bytes are versioned.
- CLI behaviour is inspectable.
- TODO is updated.
- No capability is overstated.
