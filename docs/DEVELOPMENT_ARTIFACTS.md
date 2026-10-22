# Development artifacts

The [development client workflow](../.github/workflows/development-client-artifact.yml)
produces Linux x86_64 archives and Fedora RPMs, an SPDX SBOM, provenance, and
an external build record. Successful runs retain the download for 14 days.
These are development builds of a named commit.

Choose a successful run of **Development client artifacts** on `main` in
[GitHub Actions](https://github.com/gongahkia/yeokcham/actions/workflows/development-client-artifact.yml).
Record its full commit SHA and download the artifact named
`yeokcham-development-client-COMMIT_SHA` into a new directory outside your work.
GitHub CLI users can use `gh run download RUN_ID --repo gongahkia/yeokcham
--name yeokcham-development-client-COMMIT_SHA --dir DIRECTORY`.

With Cosign installed, verify both signed files from that directory:

```sh
IDENTITY=https://github.com/gongahkia/yeokcham/.github/workflows/development-client-artifact.yml@refs/heads/main
ISSUER=https://token.actions.githubusercontent.com
cosign verify-blob SHA256SUMS --bundle SHA256SUMS.sigstore.json \
  --certificate-identity "$IDENTITY" --certificate-oidc-issuer "$ISSUER"
cosign verify-blob development-build-record-v1.json \
  --bundle development-build-record-v1.json.sigstore.json \
  --certificate-identity "$IDENTITY" --certificate-oidc-issuer "$ISSUER"
sha256sum --check SHA256SUMS
```

Check that the verified build record's `source_commit` is the commit you
selected, then inspect its architecture, artifact names, sizes, and digests.
Only use the archive or RPM after verification succeeds. The archive contains
`usr/bin/yeokcham`; extract it into an empty directory. The source tree's
[artifact smoke test](../test/test_development_artifacts.sh) exercises the
archive, RPM install/remove lifecycle, and HTTPS relay journey.

The [relay workflow](../.github/workflows/relay-artifact.yml) publishes an OCI
candidate under `ghcr.io/gongahkia/yeokcham/relay`. Its job summary records the
immutable digest. Verify that digest with `cosign verify`, using the identity
`https://github.com/gongahkia/yeokcham/.github/workflows/relay-artifact.yml@refs/heads/main`
and the same issuer above. Deploy by digest. A successful publication proves
the build/signing steps; the separate CI workflow supplies integration tests.

These signatures describe external build provenance. They grant no Yeokcham
device identity, membership, recovery authority, or delivery status.
