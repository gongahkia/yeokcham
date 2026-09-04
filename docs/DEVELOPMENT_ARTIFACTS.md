# Development Linux client artifacts

## Status and trust boundary

The development-client-artifact.yml workflow can upload a short-lived
development artifact for a successful main-branch run. It is not a public
release, a stable format promise, an opam package, a source release, or a
support commitment. A local build or a GitHub artifact name is not sufficient
evidence by itself.

Obtain the complete artifact directory from the intended workflow run through a
route you trust. It must contain:

- one yeokcham-*-linux-x86_64.tar.zst archive;
- one yeokcham-*.x86_64.rpm package;
- SHA256SUMS, SHA256SUMS.sigstore.json, development-build-record-v1.json, and
  development-build-record-v1.json.sigstore.json; and
- BuildKit sbom.spdx.json and provenance.json.

The archive and RPM contain only the native executable and licence. The build
record, checksum manifest, SBOM, provenance, and Cosign bundles are external
delivery evidence; none is a .yeokcham object, package, bootstrap input,
authority record, semantic sidecar, or source file.

The expected keyless identity is:

~~~text
https://github.com/gongahkia/yeokcham/.github/workflows/development-client-artifact.yml@refs/heads/main
~~~

The expected issuer is https://token.actions.githubusercontent.com. These
values, plus the rotation and revocation policy, are defined by
[ADR-103](adr/103-development-client-artifacts.md). A missing, mismatched, or
unverifiable bundle is a refusal: do not install.

## Verify before every install or upgrade

From the downloaded artifact directory, with Cosign, sha256sum, and jq
available:

~~~sh
IDENTITY='https://github.com/gongahkia/yeokcham/.github/workflows/development-client-artifact.yml@refs/heads/main'
ISSUER='https://token.actions.githubusercontent.com'

cosign verify-blob SHA256SUMS \
  --bundle SHA256SUMS.sigstore.json \
  --certificate-identity "$IDENTITY" \
  --certificate-oidc-issuer "$ISSUER"
sha256sum --check SHA256SUMS

cosign verify-blob development-build-record-v1.json \
  --bundle development-build-record-v1.json.sigstore.json \
  --certificate-identity "$IDENTITY" \
  --certificate-oidc-issuer "$ISSUER"
jq -e '
  .schema_version == 1
  and .architecture == "linux-x86_64"
  and .signing.workflow_identity == $identity
  and .signing.oidc_issuer == $issuer
  and .signing.bundle_filename == "SHA256SUMS.sigstore.json"
' --arg identity "$IDENTITY" --arg issuer "$ISSUER" \
  development-build-record-v1.json
~~~

The signed checksum manifest binds the archive, RPM, SBOM, and provenance. The
canonical build record additionally identifies the source commit/timestamp,
toolchain, lock digest, base images, artifact digest/size, SBOM digest, and
the SHA256SUMS signing certificate fingerprint. Inspect it before trusting the
artifact; verification does not turn it into a stable release.

## Install and uninstall

For the portable archive, extract into a new tester-owned versioned directory,
not a source tree or an existing V4 repository:

~~~sh
mkdir -p "$HOME/opt/yeokcham-dev-EXACT_BUILD"
tar --zstd -xf yeokcham-*-linux-x86_64.tar.zst \
  -C "$HOME/opt/yeokcham-dev-EXACT_BUILD"
"$HOME/opt/yeokcham-dev-EXACT_BUILD/usr/bin/yeokcham" --version
~~~

For Fedora, install only the verified local RPM:

~~~sh
sudo dnf install ./yeokcham-*.x86_64.rpm
yeokcham --version
rpm -q --scripts yeokcham
~~~

The last command should print no scriptlets. The package does not install a
service, user, timer, or daemon; it does not create or scan a repository.
Uninstall with sudo dnf remove yeokcham. For the archive, delete only the exact
versioned directory you created after closing running clients. Neither uninstall
path removes .yeokcham, Secret Service entries, an SSH-agent or PKCS#11 custody
profile, ordinary source, or relay volumes.

## Upgrade, downgrade, and backup

Before replacing a development client, verify the new artifact as above and
preserve the prior executable until the new one has completed a read-only
yeokcham verify --root PROJECT on a copy or intended repository. Back up the
repository's .yeokcham metadata and the operator-managed relay volume through
their documented explicit procedures; package installation is not a backup.

Development artifacts make no migration promise. A downgrade must not rewrite
or guess-convert records. If the older client refuses a newer V4 record, keep
the compatible client or restore a separately verified backup instead. The
private signer remains outside the package and repository; never copy private
key material into .yeokcham to work around an installation problem.

## Local maintainers and verification scope

tools/build-development-artifacts.sh --output /absolute/disposable/directory
builds unsigned test artifacts only; it refuses a repository output directory.
tools/write-development-build-record.sh requires an existing Cosign bundle for
SHA256SUMS, verifies checksums before rendering, and refuses a missing bundle
or changed artifact. The development-client workflow performs the keyless
signing and upload. Its remote OIDC execution, third-party availability, and
uploaded artifact persistence are [Unverified] until a maintainer-controlled
workflow run succeeds.
