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
requires both that digest and an immutable `NGINX_IMAGE` digest. Do not publish
the relay's port 8080 directly; publish only the proxy's TLS port. Mount the
named relay volume with UID/GID 10001 ownership, run the relay with a read-only
root filesystem and dropped capabilities, and keep the metrics listener on the
private network.

`relay-config-v1` is the only service configuration. It has no bearer secret;
the documented `YEOKCHAM_RELAY_*` overrides are revalidated and unknown
prefixed names refuse startup. `/healthz` is liveness. `/readyz` returns 200
only while storage and the credential registry remain usable. `/metrics` emits
fixed aggregate Prometheus text counters without repository, object, payload,
credential, or source-path values.

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
