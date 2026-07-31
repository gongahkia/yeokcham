# ADR-0079: Resolve GitHub refs only through explicit expected-state updates

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

ADR-0078 imports selected remote objects but intentionally does not update canonical refs. Operators need a narrow, auditable way to accept one remote ref after inspecting a remote-only or divergent state.

## Decision drivers

- Require a deliberate local-to-remote choice.
- Reconfirm the remote object at resolution time.
- Preserve current local changes made during network I/O.
- Keep durable ref events and checkpoints internally consistent or explicitly repairable.

## Considered options

### Option 1: Automatically fast-forward or force-update after fetch

Automatic state selection can hide a concurrent local update or treat a changed remote history as authoritative without an operator decision.

### Option 2: Accept a caller-supplied object ID without a remote read

The object may be locally available but no longer name the current selected remote ref.

### Option 3: Explicit selected mapping with fresh refetch and expected-state append

Require an apply switch plus local/remote refs, validate the mapping against current selection, refetch the remote ref, then conditionally append one local state transition.

## Decision

Use Option 3. `yeokcham github resolve <repo> --accept-remote <local-ref> --remote <remote-ref> --apply [--transport https|ssh]` first lists selected remote refs and accepts only the requested current mapping. It refetches that one remote ref to a disposable bare repository, verifies/imports its immutable objects, builds a successor state with the local ref at the confirmed remote ID, and invokes `append_ref_state_if_expected` using the ref state captured before fetch.

The final checkpoint is written after the durable ref event and records equal local/remote IDs. A checkpoint failure returns an error without rolling back the accepted journal event; retrying the explicit resolution repairs the checkpoint while preserving the canonical ref.

## Consequences

Resolution is an explicit one-ref operation, including for remote-only branches that the configured rules select. It does not merge, rebase, or create a pull request. An operator can inspect mapping details through `github fetch --show-refs` before accepting a remote ref.

## Invariants

- Resolution requires `--apply`, one selected local ref, and one selected current remote ref.
- The confirmed remote object is fetched and reconstructed before it becomes a canonical target.
- A local ref-state change during fetch prevents the journal append.
- No conflict resolution silently force-updates a ref.
- A successful event is durable and independently recoverable even if the subsequent checkpoint update fails.

## Compatibility and migration

No format migration. Resolution appends an existing V1 checked ref event and updates the existing `YKGM` checkpoint encoding. Existing repository readers retain the same event and checkpoint semantics.

## Security and recovery

The command uses the established standard Git credential-helper/SSH-agent boundary and no token storage. Local and remote ref names plus the accepted object ID appear only after an explicit successful resolution. A crash or final checkpoint-write failure cannot erase the durable ref event; recovery material retains both the journal and checkpoint configuration.

## Verification

The local-bare fetch fixture force-rewrites selected main, verifies fetch imports it without ref mutation, then resolves it and proves one ref event, exact canonical remote ID, and equal-ID checkpoint. Parser tests require `--apply` and validate selected standard refs. Core tests cover `append_ref_state_if_expected` through the same expected-state transition. Full workspace CI runs without GitHub credentials or network contact.
