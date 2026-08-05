# ADR-0100: Deliver HTTP V1 as a standalone loopback binary

- Status: Accepted
- Date: 2026-07-31
- Deciders: Yeokcham maintainers
- Supersedes: None
- Superseded by: None

## Context

HTTP V1 is deliberately bound only to loopback. The self-hosted-service milestone requires an operator to run it without a hosted control plane. Docker image publication is a separate unchecked roadmap item, and no registry namespace or container network policy has been approved.

## Decision drivers

- Preserve the loopback-only network boundary.
- Provide a reproducible release-binary build path.
- Avoid implying that Docker port publication can expose V1 safely.
- Keep registry ownership, image provenance, and container networking explicit.

## Considered options

### Publish a Docker image with normal port mapping

Docker port publishing routes to the container address, but V1 accepts only its own loopback address. Changing V1 to bind all interfaces would break its documented threat model.

### Publish a host-network Docker image

Host networking shares the host network namespace and ignores published-port options. Docker supports it on Linux and as an opt-in Docker Desktop feature, but it changes isolation assumptions and needs an explicit operator policy. [Docker host networking](https://docs.docker.com/engine/network/drivers/host/)

### Deliver a standalone release binary

The operator retains loopback binding, repository ownership, token-file ownership, and supervisor choice without a control plane or container-network exception.

## Decision

Add `make server-release`, which runs `cargo build --release -p yeokcham-server --locked` and produces `target/release/yeokcham-server`. Document this as the supported V1 deployment path.

Do not publish a Docker image. Docker publication remains deferred until an operator approves a host-network policy and registry/image namespace. V1's bind policy does not change.

## Consequences

An operator can deploy V1 using the release binary, a local canonical repository, a mode-0600 token file, and an operator-selected local supervisor. There is no runtime dependency on a Yeokcham control plane, hosted service, backend client, GitHub client, or credential store.

Docker users must either use the standalone binary or make a later explicit container-network decision. This is not a public-network deployment path; reverse proxies, tunnels, and port forwarding remain prohibited.

## Invariants

- The server accepts only loopback numeric bind addresses.
- Release delivery creates no hosted control-plane dependency.
- A Docker image is not claimed as available or supported.
- No registry upload occurs without explicit operator authority.

## Compatibility and migration

This adds one Make target, documentation, and a binary-startup integration test. It changes no repository, storage, authentication-token, recovery, or wire format.

## Security and recovery

Standalone delivery retains V1's private-token and local-path ownership model. Server termination cannot mutate canonical storage, and recovery continues through the local export and encrypted snapshot workflows. Deferring Docker avoids a misleading port-publication configuration that could cause an operator to widen the listener.

## Verification

The standalone-binary integration test creates a local repository and token using the built executable, launches it at a selected loopback address, sends an authenticated health request, and validates the exact successful response. The release target builds the binary with the locked dependency graph. Workspace CI covers formatting, lint, server tests, and documentation builds.
