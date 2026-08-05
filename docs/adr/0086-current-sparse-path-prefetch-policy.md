# ADR-0086: Prefetch only current sparse paths within explicit byte budgets

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The daemon needs one initial target workload that is bounded, explainable, and recoverable. The current helper performs full snapshot reconstruction before C Git filtering, so a prefetch policy must not imply that native path-aware hydration already exists.

## Decision

`SparsePrefetchSelection` accepts only exact current relative sparse paths, deduplicates and orders them, and states that current `HEAD` is included without history prediction. The defaults reserve at most 64 MiB for one repository and 256 MiB for one daemon process. Absolute, parent, empty, and oversized paths fail before work is scheduled.

## Consequences

This policy is deterministic and auditable. It deliberately does not use file-access history, branch prediction, speculative historical blobs, or user-source content. It is a contract for the later native path-aware hydration bridge, not a claim that the existing C-Git snapshot helper becomes faster.

## Invariants

- Prefetch selection is bounded by path count, path bytes, per-repository bytes, and process bytes.
- Only current sparse paths and `HEAD` are eligible.
- Selection debug output redacts paths.
- The policy never changes source, Git, or Yeokcham repository data.

## Compatibility and migration

No persistent data format changes. Disabling the daemon or discarding a selection changes no repository state.

## Security and recovery

No selection reads file body bytes or follows a caller path. Paths remain local request metadata. Recovery uses a normal cold path and does not depend on prefetch completion.

## Verification

Tests cover deterministic deduplication, unsafe paths, budget limits, redacted debug output, and thread-safety. Native hydration and workload improvement require separate end-to-end benchmarks before the roadmap item is closed.
