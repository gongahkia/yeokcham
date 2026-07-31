# ADR-0098: Render redacted local GitHub mirror policy state

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

Milestone 9 requires a mirror-state UI. The canonical `YKGM` record is token-free but contains a GitHub target, selected references, object IDs, and timestamps. Existing CLI inspection deliberately omits target and reference names by default. The V1 server neither owns a GitHub credential nor has authority to contact a provider when an operator browses local state.

## Decision drivers

- Provide useful local policy state without disclosing target/ref/object metadata.
- Reuse checked bounded `YKGM` decoding.
- Avoid GitHub network traffic and all credential sources.
- Keep the page static, authenticated, loopback-only, and read-only.

## Considered options

### Show the full local mirror record

This conflicts with the existing default inspection privacy policy and exposes target/reference metadata unnecessarily.

### Query GitHub for live state

This requires credentials, outbound-network policy, rate-limit handling, and a definition of provider health unavailable to V1.

### Show redacted local policy summary

This communicates configuration state and policy strength without expanding disclosure or authority.

## Decision

Add authenticated `GET /mirror`. If no checked GitHub configuration exists, it renders that absence. If one exists, it renders only `direction`, `force-update policy`, publication-rule count, and confirmed-checkpoint count. The page omits GitHub target, selected/remote references, Git object IDs, observation times, and credentials.

The route calls only `LocalRepository::github_mirror_configuration`. A corrupt or unavailable local policy returns generic `500 mirror_state_unavailable`; the page makes no GitHub request and cannot publish, fetch, resolve divergence, update a ref, or alter a checkpoint.

## Consequences

The UI describes persisted policy rather than remote health or current GitHub state. An operator must use the explicit CLI transport commands for publication, fetch, and conflict resolution. A target-aware view needs an explicit later disclosure and authorization decision.

## Invariants

- Dynamic target/reference/object/timestamp data never enters the HTML response.
- The policy is decoded and repository-ID-checked before any configured summary is rendered.
- Missing configuration is a normal state; corruption yields no partial summary.
- The route is authenticated, static, read-only, and loopback-only.
- It never opens a credential source or outbound provider connection.

## Compatibility and migration

No repository, storage, recovery, or wire-format change. This is an additive authenticated V1 browser route documented in [`native-http-v1.md`](../native-http-v1.md).

## Security and recovery

The page exposes only bounded non-secret local policy categories to an already-authorized local reader. Redaction preserves the project's default mirror-inspection privacy boundary. Server failure cannot change the canonical `YKGM` record, Git refs, or remote state.

## Verification

The V1 TCP integration test configures a local policy, authenticates the page, checks direction and rule count, and proves the target does not appear. A direct unit test covers unconfigured state and corrupt-policy `500 mirror_state_unavailable`. Workspace CI runs fixtures, formatting, Clippy, tests, and documentation builds.
