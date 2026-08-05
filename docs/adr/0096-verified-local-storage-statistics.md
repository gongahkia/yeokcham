# ADR-0096: Report verified local storage and zero remote attachments

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Milestone 9 requires storage and backend statistics in the authenticated self-hosted service. The V1 server owns only a `LocalRepository`: it has no remote `Backend` instance, no persistent cloud credential, and no authorization to infer a Drive or GitHub provider's health from local metadata. A filesystem scan that does not validate records could report corrupted or untrusted inventory.

## Decision drivers

- Report only counts backed by the repository's existing bounded verification path.
- Avoid provider network calls, credential reads, remote discovery, and health claims.
- Keep one static authenticated browser route with no query, form, script, or state.
- Distinguish local canonical storage from a remote backend attachment.

## Considered options

### Scan local directories without verification

This is cheaper but can count staging, malformed, or hostile records as storage.

### Probe configured remote providers

V1 has no provider client, token, or authorization lifecycle. Probing would expand credentials, network, rate-limit, and privacy scope before the separate backend UI work.

### Reuse complete bounded local verification

This returns counts only after canonical immutable storage passes its existing integrity checks and needs no new persistent format.

## Decision

Add authenticated `GET /storage`. It calls `LocalRepository::verify` with the initial bounded verification limits and renders the resulting segment, index, blob-manifest, tiny-blob-group-manifest, metadata-object-manifest, and ref-snapshot counts. A verification failure returns generic `500 storage_unavailable` rather than partial counts or filesystem detail.

The page states the V1 topology explicitly: one local canonical storage provider and zero attached remote backends. It does not inspect a remote backup, GitHub target, Drive folder, environment variable, key export, or credential store, and makes no provider network request.

## Consequences

The storage page can be slower than ordinary metadata browsing because it deliberately performs complete verification. Its values are verified count statistics rather than byte accounting, cache statistics, remote usage, provider latency, or remote health. A later remote backend or mirror page requires an explicit authorized connection design.

## Invariants

- Counts are rendered only after bounded canonical verification succeeds.
- A failed verification returns no partial inventory.
- V1 does not infer remote attachment or health from local configuration.
- The route remains authenticated, loopback-only, static, read-only, and under the existing response bound.
- No provider credential, key, token, remote identifier, or source body is rendered.

## Compatibility and migration

No repository, storage, recovery, or wire-format change. The additive V1 browser route is documented in [`native-http-v1.md`](../native-http-v1.md).

## Security and recovery

Verification consumes only the opened local repository and preserves all existing read bounds. The page does not broaden the local credential boundary or make network traffic. Server failure cannot affect canonical storage or remote recovery data.

## Verification

The V1 TCP integration test imports a real Git fixture, authenticates `GET /storage`, checks the verified-count and zero-remote-backend sections, and confirms the repository browser links to it. Workspace CI runs fixtures, formatting, Clippy, tests, and documentation builds.
