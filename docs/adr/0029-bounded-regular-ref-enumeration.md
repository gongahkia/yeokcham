# ADR-0029: Enumerate bounded regular Git refs by exact byte name

- Status: Accepted
- Date: 2026-07-29
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Milestone 1 needs import roots before it can traverse reachable objects. Git ref names are arbitrary validated bytes, may be stored loose or packed, and pseudo-refs such as `HEAD` are not import roots. Hostile repositories must not cause unbounded allocation or let malformed references become trusted metadata.

## Decision drivers

- Preserve exact valid Git refname bytes.
- Use the existing isolated Git adapter rather than parse ref storage directly.
- Give callers deterministic names without resolving targets yet.
- Bound memory consumed by a single enumeration.
- Fail before malformed source state becomes an import root.

## Considered options

### Return all names without a bound

This is simple but permits a hostile repository to allocate memory proportional to an unbounded number of refs.

### Enumerate only conventional branch and tag namespaces

This would omit valid custom, remote-tracking, notes, and replacement namespaces that later reachability policy must decide about explicitly.

### Enumerate all regular refs with a fixed bound

This preserves all regular namespaces while providing a clear failure before memory use becomes unbounded.

## Decision

`GitRepository::ref_names` iterates the adapter's regular-reference API, which excludes pseudo-refs. It retains only `refs/` names, validates every name through `RefName`, sorts exact bytes lexicographically, and rejects duplicates.

The API returns at most 1,000,000 names. A larger repository fails with `unsupported`; malformed ref storage or invalid names fails with `corrupt_data`. It does not resolve direct or symbolic ref targets and does not claim a transactionally consistent ref snapshot.

## Consequences

Loose and packed refs, including valid non-UTF-8 names and symbolic regular refs, are visible through one Yeokcham-owned type. Repositories above the cap need a future streaming or configured-limit design before import. Target verification and reachability remain separate tasks.

## Invariants

- Returned names are exact validated `RefName` bytes in deterministic order.
- Pseudo-refs do not become import roots.
- Malformed references are not ignored or normalized.
- Enumeration cannot return more than 1,000,000 names.

## Compatibility and migration

This introduces no persistent format. The limit is an adapter admission rule; existing repositories are not modified.

## Security and recovery

The count limit bounds result allocation. Ref storage remains untrusted until later target and object-ID verification. Ref names are not formatted in default error messages. Recovery does not depend on this live enumeration after Yeokcham stores verified import state.

## Verification

Tests use C Git to create packed and loose refs, a symbolic regular ref, and a raw non-UTF-8 loose ref. They verify byte-sorted output, pseudo-ref exclusion, and rejection of malformed `packed-refs` input. CI runs these tests on macOS and Linux.
