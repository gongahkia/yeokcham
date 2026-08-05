# ADR-0097: Render a bounded read-only integrity result

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The V1 storage page reports verified record counts, but Milestone 9 also requires a distinct integrity-check UI. An integrity check must not turn the browser into a repair or recovery control plane, and reporting detailed failure paths or partial inventory can disclose storage internals.

## Decision drivers

- Use the existing complete bounded local verification path.
- Render an explicit success result only after verification completes.
- Keep failure output generic and read-only.
- Avoid remote provider access, credentials, repair, export, or persistence.

## Considered options

### Reuse only the storage-statistics page

This does not give the operator a distinct integrity result or make its read-only scope clear.

### Add browser-triggered repair or export

This expands destructive-operation authority and recovery scope beyond the documented V1 service.

### Add a dedicated verified GET result

This provides a simple authenticated result while retaining one-request, static, loopback-only behavior.

## Decision

Add authenticated `GET /integrity`. It calls `LocalRepository::verify` with the initial bounded verification limits. On success, it returns static HTML that states every bounded canonical record passed and lists the verified record counts. On any verification failure, it returns the existing generic JSON error envelope with `500 integrity_check_failed` and no partial count, pathname, object ID, source bytes, or underlying cause.

The route is a read-only observation. It has no query parameters, request body, repair, export, backend call, credential lookup, session state, or mutation.

## Consequences

The page may take as long as complete local verification. An operator learns a generic pass/fail result and must use the existing CLI recovery paths for a failed repository. The V1 service still cannot repair, restore, or export a repository.

## Invariants

- A success page appears only after bounded local verification succeeds.
- A failure yields no partial inventory or internal storage detail.
- The check cannot mutate canonical records, caches, refs, tokens, or remote state.
- No backend provider, credential, or recovery key is contacted or displayed.
- Authentication, loopback binding, parser bounds, and response bounds remain unchanged.

## Compatibility and migration

No repository, storage, recovery, or wire-format change. This is an additive authenticated V1 browser route documented in [`native-http-v1.md`](../native-http-v1.md).

## Security and recovery

The route reads only the opened local repository under the same verification bounds as the CLI. Generic failure avoids leaking record locations or object identities to an authenticated local browser. It deliberately offers no repair action, so failed verification cannot make loss worse; existing encrypted recovery and export procedures remain authoritative.

## Verification

The V1 TCP test authenticates a healthy integrity page, asserts its success text, then corrupts a published segment and checks `500 integrity_check_failed` contains no partial page. It also checks the browser link. Workspace CI runs fixtures, formatting, Clippy, tests, and documentation builds.
