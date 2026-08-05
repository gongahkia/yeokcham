# ADR-0078: Import selected GitHub objects without ref mutation

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

GitHub ingestion must discover remote-only and divergent selected refs, retain remote objects for review, and avoid treating an observed remote ref as an authorised local ref update.

## Decision drivers

- Verify exact remote object IDs before canonical import.
- Retain imported remote history without silent data loss.
- Preserve the selected-ref and credential boundaries from ADR-0075 and ADR-0076.
- Keep ref adoption an explicit subsequent operation.

## Considered options

### Option 1: Fetch directly into canonical refs

This makes C Git's local ref update part of canonical state before Yeokcham verifies the remote object graph or records an explicit resolution decision.

### Option 2: List only and require an external Git clone

This detects a remote state but leaves Yeokcham unable to retain verified remote-only objects for later resolution.

### Option 3: Fetch into a disposable bare repository, then import objects only

Preflight remote refs, fetch explicit refspecs to private temporary refs, verify their IDs, and import only verified immutable objects into Yeokcham.

## Decision

Use Option 3. `yeokcham github fetch <repo> [--show-refs] [--transport https|ssh]` lists bounded standard refs, selects configured rules plus explicit checkpoint mappings, then fetches only selected existing remote refs into a disposable bare repository. It requests atomic local temporary-ref updates, disables automatic tag following and refmaps, verifies every temporary ref equals the preflight remote object ID, and calls `LocalRepository::import_git_objects`.

Object-only import verifies each Git object and existing-object identity, then publishes immutable records without creating a ref snapshot or journal event. Existing selected local refs receive a checkpoint recording the observed remote ID only after imports verify and their local ID remains current. The fetch summary reports remote-only, local-only, and divergent mappings; names and IDs require `--show-refs`.

## Consequences

Remote-only and divergent commits become locally recoverable immutable data, but no canonical ref changes. Operators need a separate explicit resolution command to adopt any remote ref. The remote must be read twice in effect: first by `ls-remote`, then through fetched temporary targets; a moving remote fails rather than importing an unverified observation.

## Invariants

- Only configured selected standard branch/tag refs or explicit selected checkpoint mappings are fetched.
- Every fetched temporary ref equals its preflight remote ID before import.
- Imported objects reconstruct and verify before trust.
- Fetch never creates a canonical ref snapshot or journal event.
- Remote-only and unequal local/remote ref IDs remain visible rather than silently selected.
- Observed checkpoints cannot replace a checkpoint after the local ref changes.

## Compatibility and migration

No persistent-format change. `import_git_objects` creates existing immutable record formats but no ref data. Existing `YKGM` checkpoints record the observed remote ID with their established encoding. Rollback leaves valid unreachable immutable objects and checkpoints, neither of which changes canonical refs.

## Security and recovery

GitHub credentials remain outside Yeokcham. Temporary bare repositories contain ordinary Git objects during fetch and are removed on normal completion; interrupted-process remnants are disposable operating-system temporary data. Default output omits target and ref metadata. No remote response, object body, or credential is logged.

## Verification

Core tests import a later Git graph without ref mutation, prove the new commit reconstructs, and prove repeated import deduplicates. A local-bare CLI fixture force-rewrites selected main, adds a selected remote-only branch, fetches/imports both graphs, records an unequal checkpoint, and proves canonical refs are unchanged. Parser tests cover HTTPS/SSH and explicit ref disclosure. Full workspace CI verifies the implementation without contacting GitHub or a credential helper/agent.
