# Instructions for Coding Agents

## Mission

Implement Yeokcham incrementally as a correctness-first Git-compatible storage and remote system.

Do not reinterpret the project as:

- A new Git CLI.
- A GitHub clone.
- A cloud-sync wrapper around `.git`.
- A benchmark demo with no recovery path.
- A from-scratch rewrite of every Git primitive.

## Required reading order

Before changing code, read:

1. `README.md`
2. `PROJECT_CONTEXT.md`
3. `PRD.md`
4. `ARCHITECTURE.md`
5. `DECISIONS.md`
6. `SECURITY_AND_RECOVERY.md`
7. `TESTING_AND_BENCHMARKS.md`
8. `TODO.md`

## Working rules

### 1. Work one milestone at a time

Do not implement Drive, GitHub, a daemon, or a web UI before local import/export and remote-helper correctness.

### 2. Update the plan

Before coding:

- State the current milestone.
- Identify the smallest vertical slice.
- List affected crates and files.
- State tests to add.
- State assumptions.

After coding:

- Mark completed TODO items.
- Record deferred work.
- Add or update ADRs for architectural changes.
- Report commands run and results.

### 3. Preserve invariants

Important invariants include:

- A Git object ID maps to exact reconstructable bytes.
- Reconstructed objects are verified before trust.
- Refs never point to unavailable acknowledged data.
- Immutable remote objects never change in place.
- Cache contents are disposable.
- Recovery does not depend on a hosted Yeokcham service.
- No silent force-push or last-writer-wins loss.

### 4. Prefer simple formats first

Use straightforward versioned encodings before optimising.

Do not add:

- Custom bit packing.
- Unsafe memory mapping.
- Lock-free data structures.
- Novel compression.
- A complex distributed consensus protocol.

unless a benchmark or correctness need is recorded.

### 5. No invented performance claims

Every performance claim must link to a benchmark fixture and result.

It is acceptable to report that Yeokcham is slower.

### 6. Security discipline

- Do not invent cryptography.
- Do not log plaintext source or keys.
- Treat Git packs and remote records as hostile.
- Bound allocations and decompression.
- Keep listeners on loopback by default.
- Add tests for tampering and wrong keys.

### 7. Git compatibility strategy

Use mature Git libraries when possible.

Wrap external libraries behind Yeokcham interfaces so that:

- Tests can inject failures.
- Dependency behaviour is isolated.
- Pack and object assumptions are documented.

### 8. Commit discipline

Commits should be small and explain:

- The invariant introduced or preserved.
- The test proving it.
- Any format change.
- Any migration implication.

Avoid mixing refactors, format changes, and new features in one commit.

## Suggested initial command set

```bash
yeokcham init --from-git <path>
yeokcham verify <yeokcham-repo>
yeokcham export-git <yeokcham-repo> <destination>
yeokcham inspect object <git-object-id>
yeokcham inspect storage
git clone yeokcham::<yeokcham-repo-path>
```

## Definition of done for a task

A task is done only when:

- Code compiles.
- Tests cover normal and failure cases.
- Documentation matches behaviour.
- Persistent format changes are versioned.
- TODO is updated.
- No unrelated warnings are introduced.
- Relevant benchmark or correctness evidence is recorded.

## First vertical slice

Implement:

1. Import one loose or packed Git blob.
2. Verify its Git object ID.
3. Store it as one Yeokcham record.
4. Reconstruct it.
5. Export it as a valid Git object.
6. Add corruption and round-trip tests.

Then extend from one blob to a reachable repository graph.
