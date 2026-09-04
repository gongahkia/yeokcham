# Development relay operation

RELAY-OPS-001 provides one single-node, plain-HTTP relay for a small trusted
team. It is not HA, managed hosting, replication, a public HTTP service, or
end-to-end payload privacy. Terminate TLS in an operator-managed proxy.

Build only from the digest-pinned inputs in `containers/relay/build-inputs.lock`:

```sh
docker build --file containers/relay/Containerfile --tag yeokcham-relay:local .
docker image inspect yeokcham-relay:local --format '{{index .RepoDigests 0}}'
```

The local tag is not a deployable identity. Record the resulting immutable
manifest digest and deploy that digest as `YEOKCHAM_RELAY_IMAGE`. `compose.yaml`
requires that relay digest and defaults to the immutable Nginx digest pinned in
`build-inputs.lock`; an `NGINX_IMAGE` override must also be an immutable digest.
Do not publish the relay's port 8080 directly; publish only the proxy's TLS
port. Mount the named relay volume with UID/GID 10001 ownership, run the relay
with a read-only root filesystem and dropped capabilities, and keep the metrics
listener on the private network. The example proxy runs as the pinned Nginx
image's UID/GID 101 on internal port 8443; Compose maps host TLS port 443 to
it. Its two tmpfs directories are owned by that unprivileged account, so it
also runs with a read-only root filesystem and dropped capabilities.

The relay image intentionally has no Docker `VOLUME` instruction. Docker would
otherwise create an anonymous writable volume when an operator forgot the named
mount, hiding a deployment error. With a read-only root filesystem, startup
refuses unless the operator mounts `/var/lib/yeokcham-relay` explicitly.

`relay-config-v1` is the only service configuration. It has no bearer secret;
the documented `YEOKCHAM_RELAY_*` overrides are revalidated and unknown
prefixed names refuse startup. `/healthz` is liveness. `/readyz` returns 200
only while storage and the credential registry remain usable. Its storage
check creates and removes a zero-byte probe in the relay data volume; it does
not create a relay object, session, V4 record, or ordinary source file.
`/metrics` emits fixed aggregate Prometheus text counters without repository,
object, payload, credential, or source-path values.

## Reproducible container check

Run `make relay-container-test` from a Docker host. By default it builds the
local relay image with a 900-second timeout. Set `RELAY_IMAGE` only to test a
previously built local image; it is a test convenience, not a deployable image
identity. The check uses a disposable Docker network and volumes, a generated
one-day TLS certificate, and the pinned Nginx image. It proves the non-root
read-only runtime, proxy readiness, scoped immutable upload/fetch, restart
persistence, checksum rejection of a corrupt backup, and a disposable
read-only restored fetch. It also refuses an unknown configuration key and a
relay without a data volume. The script compares repository status before and
after so it fails if its receipt path changes ordinary source files.

## Backup and restore drill

Quiesce the relay or take a filesystem-consistent snapshot of its data volume.
Archive the snapshot, record a SHA-256 checksum outside the volume, and retain
daily backups for 14 days plus one weekly backup for eight weeks. At least once
per quarter, restore one retained snapshot to a disposable volume and start a
disposable relay with its own private proxy. Verify the archive checksum before
starting it, query `/readyz`, run only read-only relay verification, then use a
separate disposable client repository for an explicit receive/bootstrap smoke
journey. The drill must not materialise or alter any ordinary source tree.

A corrupt checksum, failed readiness, malformed registry, or failed smoke
journey is a failed drill: preserve the original backup, do not overwrite the
live volume, and record the failure for operator follow-up. A backup is not a
repair source selection or authority input.

## Artifact provenance

Before any development image publication, produce an OCI SBOM and provenance
attestation for the manifest digest, sign that digest with Cosign keyless OIDC,
and verify using the workflow identity
`https://github.com/gongahkia/yeokcham/.github/workflows/relay-artifact.yml@refs/heads/main`
and GitHub OIDC issuer `https://token.actions.githubusercontent.com`. The
checked-in `relay-artifact.yml` workflow runs only for this repository's `main`
branch and uses an ephemeral GitHub OIDC credential: no long-lived signing key
or registry credential is configured. Its candidate digest is the only
deployable identity; do not deploy the candidate tag. The signing identity,
attestation, and digest are external development artifacts; they do not alter
V4 project state or prove a public release.
