# ADR-102 — development relay packaging and operation

- Status: Accepted
- Date: 2026-09-04
- Deciders: maintainers
- Implements: RELAY-OPS-001

## Context

The V4 relay is an untrusted, repository-scoped immutable-byte courier. Its
existing HTTP listener deliberately has no TLS, source-tree, model, authority,
or materialisation capability. TRANSPORT-002 adds relay-local resumable V2
sessions, so a small self-hosted team also needs an operator boundary for
durable storage, health, configuration, backup, and image provenance.

This is not a hosted service design. A relay image must not become a native
client image, authority coordinator, source materialiser, generic file server,
or a claim of high availability or end-to-end payload privacy.

## Current milestone and vertical slice

RELAY-OPS-001 adds these non-model values and transitions:

```text
relay_config = {
  storage_root; listen; health_listen; project_quota_bytes;
  session_expiry_seconds; credential_registry_root; log_level
}

parse_config(environment, config_file) -> relay_config | config_refusal
readiness(relay_config, storage) -> ready | unavailable
metrics(counters) -> bounded_aggregate_snapshot
backup(storage) -> checksum_verified_archive | operator_refusal
```

`relay_config`, counters, health results, OCI image metadata, SBOMs,
provenance, signatures, and backup archives are operator artifacts. None is a
V4 object, package, feed entry, checkpoint, capsule, revision, release,
authority record, semantic sidecar, or receipt transition. Parsing and
readiness have no source-tree dependency; the only normal relay writes remain
immutable relay objects and quota-bound V2 session files beneath the named
storage volume.

## Decision

### Image and runtime boundary

The image contains one relay-serving entrypoint, equivalent to
`yeokcham relay serve`; it does not run the local VCS workflow, daemon, sync,
bootstrap, source scanner, or materialiser. A multi-stage Containerfile builds
with a pinned Debian/OCaml/Dune toolchain input and copies only the relay
executable plus its declared runtime shared libraries into a pinned
`debian:12-slim` runtime image. The exact base reference is always a `sha256:`
digest in a checked-in build-input lock and the published image is recorded and
deployed by immutable manifest digest, never a mutable tag.

The image uses a fixed unprivileged UID/GID and exposes only the configured
plain HTTP listener. Operators must mount `/var/lib/yeokcham-relay` as the
named writable data volume; the image deliberately does not declare Docker
`VOLUME`, which would silently create an anonymous writable volume when a mount
is missing. They run it with a read-only root filesystem, dropped ambient
privileges, no published host port for the plain listener, and a writable
volume whose ownership is explicitly compatible with the image UID. The
container may use a bounded `/tmp` tmpfs for process-local files; session data
must stay in the data volume so restart recovery remains possible.

TLS termination belongs to a separately operated Nginx or Caddy reverse proxy.
The relay's normal listener defaults to loopback in direct local runs; a
container listener may bind its private Compose network only. Direct public
HTTP, TLS termination inside the relay, automatic certificate acquisition,
managed hosting, replication, or multi-node failover are unsupported.

### Configuration, health, and metrics

`relay-config-v1` is an explicit small configuration file with optional
documented environment overrides for the same named fields. Unknown keys,
duplicate keys, missing required values, invalid addresses, non-positive or
over-limit quotas/expiry, inaccessible storage, and an invalid credential
registry are startup refusals. There is no token, bearer secret, private key,
or raw request payload setting. Configuration is never written back, imported
into a V4 repository, or emitted in unredacted logs.

The storage root, credential-registry root, quota, and session expiry are
passed explicitly into the existing relay/session adapters rather than silently
changing persistent-object semantics. Log levels are `error`, `warn`, `info`,
and `debug`; every emitted operator record is bounded and excludes bearer
secrets, authorization headers, raw object bytes, repository identifiers, and
object identifiers.

`/healthz` is liveness only. `/readyz` verifies that the configured storage and
credential-registry paths are usable without creating ordinary source files or
changing V4 state. Storage readiness creates then removes a zero-byte probe
only in the named relay volume, so a mode-writable but read-only mount is not
reported ready. A separately bound local metrics listener reports only bounded
aggregate request/status/object/session/quota/expiry/failure counters; it
contains no repository names, object IDs, credentials, payload sizes per
object, or source paths. These endpoints do not confer access, selection, or
receipt authority.

### Backup and artifact provenance

The backup runbook requires an operator to quiesce the single relay or take a
filesystem-consistent volume snapshot, record a SHA-256 checksum, restore it
to a disposable relay volume, run read-only verification, then perform an
explicit client receive/bootstrap smoke journey. It specifies retention and a
regular restore drill. Backup remains a byte-level operator procedure: it does
not repair, merge, replace divergent bytes, or materialise a source tree.

The development image pipeline produces an OCI SBOM and provenance attestation
for the immutable image digest, including the checked-in build context in the
SBOM scan. It signs only that digest with Sigstore Cosign keyless GitHub OIDC;
verification pins
`https://github.com/gongahkia/yeokcham/.github/workflows/relay-artifact.yml@refs/heads/main`
and issuer `https://token.actions.githubusercontent.com`, then checks the image
digest before use. The workflow identity and issuer are the development trust
root; no long-lived signing key is stored. It must not use build arguments for
credentials because provenance can expose build inputs. No image is presented
as a public/stable release merely because it has an attestation or signature.

## Invariants and verification

- image/runtime configuration has no path to ordinary source files, model
  transitions, authority selection, package receipt, or materialisation;
- the process runs non-root and persists all durable relay/session data only on
  the named writable volume;
- every generated/published artifact is addressed and deployed by digest;
- configuration and metrics fail closed/bounded and never expose bearer
  secrets, repository contents, or identifiers;
- readiness failure does not create relay objects or sessions; and
- backup verification and smoke receipt keep ordinary worktrees unchanged.

Container integration must start an empty mounted volume as the unprivileged
user, reach readiness through the proxy, perform a scoped transfer/receipt,
restart, and observe the same relay state. Negative cases cover unwritable
volume, malformed/unknown configuration, secret redaction, quota/expiry,
health failure, and corrupt backup restore. CI publishes no image until its
SBOM, provenance, signature, and digest verification all succeed.

## Consequences

This milestone deliberately adds operational configuration and evidence, not
any V4 history, source, identity, or compatibility feature. A team operating
the image accepts responsibility for reverse-proxy TLS, volume ownership,
backup confidentiality, availability, and the documented development signing
trust root. A production support promise, end-to-end encryption, HA,
replication, or a hosted control plane requires a separate product decision and
ADR.

## References

- [OCI image configuration and immutable image IDs](https://github.com/opencontainers/image-spec/blob/main/config.md)
- [OCI descriptor digests](https://github.com/opencontainers/image-spec/blob/main/descriptor.md)
- [Podman read-only root filesystem semantics](https://docs.podman.io/en/latest/markdown/podman-run.1.html)
- [Prometheus text exposition format](https://prometheus.io/docs/instrumenting/exposition_formats/)
- [Prometheus metric naming guidance](https://prometheus.io/docs/practices/naming/)
- [Docker BuildKit SBOM and provenance attestations](https://docs.docker.com/build/metadata/attestations/)
- [Sigstore Cosign container signing](https://docs.sigstore.dev/cosign/signing/signing_with_containers/)
- [Sigstore Cosign verification](https://docs.sigstore.dev/cosign/verifying/verify/)
- [GitHub Actions OpenID Connect](https://docs.github.com/en/actions/concepts/security/openid-connect)
