# ADR-0071: Delegate partial-clone filtering to C Git upload-pack

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

The local remote helper already delegates native pack negotiation to C Git `upload-pack` over its `connect` capability. Partial clone requires the server to advertise `filter`, the client to record promisor state, and later object-ID requests to be served for omitted reachable objects. Implementing another filter grammar or promisor-object tracker inside Yeokcham would duplicate mature C Git behavior before remote-side partial reconstruction exists.

## Decision drivers

- Preserve standard `git clone --filter` behavior.
- Keep canonical Yeokcham reconstruction and object verification unchanged.
- Limit lazy object requests to reachable repository objects.
- Avoid custom partial-pack and promisor formats.

## Considered options

### Implement filtering in Yeokcham

This would require a new pack selection protocol, a promisor representation, and lazy object handling before the existing compatibility bridge is proven.

### Enable arbitrary object-ID wants

This would make lazy hydration easy but expands a client from advertised history to any object retained in the exported snapshot.

### Configure only disposable C Git upload-pack

The helper can enable the standard filter capability and C Git's existing promisor behavior only after constructing a verified complete temporary/cache snapshot.

## Decision

For `connect git-upload-pack`, invoke C Git with command-scoped `uploadpack.allowFilter=true` and `uploadpack.allowReachableSHA1InWant=true`. Do not set `uploadpack.allowAnySHA1InWant`. C Git serves `blob:none` and `blob:limit=<bytes>` using its native pack protocol, writes normal promisor state in the client, and reconnects through the helper when a checkout needs an omitted reachable blob.

## Consequences

Filtered clients transfer fewer blob bytes, but Yeokcham still verifies and reconstructs the complete disposable snapshot before C Git constructs the filtered outgoing pack. No performance or remote-backend-read reduction is claimed. The existing snapshot cache remains complete, disposable, and ref-state keyed.

## Invariants

- Canonical Yeokcham records remain complete and independently verifiable.
- Filtered output comes only from a verified helper-created snapshot.
- Lazy hydration accepts only objects reachable from advertised repository refs.
- Omitted blobs remain explicit C Git promisor objects until hydration.
- No helper request enables arbitrary object-ID access.

## Compatibility and migration

No Yeokcham persistent format changes. Clients need a C Git version supporting partial clone. Unfiltered clone and fetch behavior is unchanged. Existing full snapshot-cache entries remain valid.

## Security and recovery

The upload-pack settings are command scoped and apply only to the helper's verified export. The user-supplied source Git repository configuration is not trusted for this decision. A filtered client needs its promisor remote to hydrate missing blobs; the canonical Yeokcham repository remains complete for recovery and conventional export.

## Verification

Integration tests run `git clone --filter=blob:none --no-checkout` and `git clone --filter=blob:limit=1 --no-checkout` through the helper, assert C Git promisor configuration and a missing promised blob, then checkout to trigger hydration and run `git fsck --full --strict`. The maintained C Git matrix runs the same tests.
