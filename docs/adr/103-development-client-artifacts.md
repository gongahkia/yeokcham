# ADR-103 — development client artifact boundary

- Status: Accepted
- Date: 2026-09-04
- Deciders: maintainers
- Implements: DIST-001

## Context

ADR-102 governs a digest-addressed relay OCI image. A native client archive and
Fedora RPM have a different consumer, installation, and signing boundary: they
place an executable on a tester's machine but must not imply a stable release,
format compatibility, daemon service, or source-tree action.

## Decision

DIST-001 produces Linux x86_64 development artifacts from one checked-in
container build-input lock:

- a relocatable `tar.zst` archive containing `/usr/bin/yeokcham` and licence;
  and
- a Fedora RPM containing the same executable and licence.

The archive and RPM are development artifacts, not an opam package, a source
release, a compatibility promise, or a V1 object. The RPM has no systemd unit,
tmpfiles entry, user creation, `%post`, `%preun`, or other scriptlet. Installing
or uninstalling it therefore never starts a daemon, contacts a relay, creates a
repository, scans, restores, or alters ordinary source files. The native client
does nothing to a working tree until the operator explicitly invokes an
authorised V1 command.

The external build record is a canonical JSON document carrying schema version, source
commit and commit timestamp, architecture, OCaml/Dune versions, opam lock
digest, pinned builder/Fedora base images, artifact names/sizes/SHA-256 values,
SBOM digest, and signing bundle filename. It is deliberately outside the files
it digests, avoiding a self-referential archive or RPM. `SOURCE_DATE_EPOCH` is the source
commit timestamp. This makes inputs and produced bytes inspectable; it is not a
claim that independent native builds are bit-for-bit reproducible.

The release workflow builds OCI relay images as ADR-102 specifies. A separate
development-client workflow signs SHA256SUMS, which binds the archive, RPM,
SBOM, and provenance, and then signs the external build record. It writes a
Cosign bundle beside both signed blobs. The build record names the SHA256SUMS
bundle and records its short-lived certificate SHA-256; the record itself stays
outside the files named by its checksum manifest. The development signing root
is the exact workflow identity on the repository's main branch plus GitHub's
OIDC issuer, not an unpublished maintainer key. Verification pins that identity
and issuer rather than trusting an ephemeral fingerprint.

Maintainers rotate this root by changing the workflow path/branch only through
an ADR amendment and an announcement containing the old and new identities.
If GitHub OIDC, Fulcio, Rekor, or the named workflow identity is unavailable or
revoked, publication stops; no local fallback key silently replaces it. Testers
obtain the expected workflow identity and issuer from this ADR and verify both
signed blobs, then the recorded artifact SHA-256 values before installation.
No artifact is called stable or publicly released merely because this
verification succeeds.

The Fedora smoke image is pinned and uses the explicit test-only signer only to
exercise `init`, `save`, `restore`, explicit workspace activation, relay sync,
and `verify` in a disposable container. It does not attest to desktop Secret
Service integration. The smoke test also compares a sentinel ordinary source
file before and after package install/uninstall; all materialisation remains an
explicit V1 operation.

Upgrade replaces a development artifact only after verifying its bundle and
build record. Downgrade runs no conversion: a command encountering a newer V1
record must refuse according to the existing record decoder. Operators preserve
the old executable, repository metadata, credential configuration, and any
relay backup before changing an artifact; uninstall removes only package-owned
files and leaves all user repositories and relay volumes intact.

## Invariants

1. Client artifacts and their records are not V1 history, packages, relay
   objects, authority state, receipts, semantic sidecars, or source content.
2. Every published development artifact is bound to one immutable source commit,
   SHA-256, SBOM, signing bundle, and OIDC workflow identity.
3. Packaging lifecycle actions do not start services or write ordinary source.
4. A failed build, signature verification, install, uninstall, or smoke journey
   does not create an implicit materialisation, merge, or repair.
5. No local key generation, tag, registry publication, or format-stability claim
   is a fallback for the CI signing route.

## Consequences

The workflow is a checked-in development delivery mechanism. Remote
publication, OIDC signatures, registry persistence, and third-party
availability require a successful run in the maintainer-controlled GitHub
environment; local tests can validate artifact layout and verification commands
but cannot establish those external facts.

## References

- [Fedora systemd packaging: packages must not autostart services](https://fedoraproject.org/wiki/Packaging%3ASystemd)
- [Fedora reproducible package builds and `SOURCE_DATE_EPOCH`](https://fedoraproject.org/wiki/Changes/ReproduciblePackageBuilds)
- [Docker BuildKit attestations](https://docs.docker.com/build/metadata/attestations/)
- [Docker SBOM attestations](https://docs.docker.com/build/metadata/attestations/sbom/)
- [Sigstore CI quickstart and identity verification](https://docs.sigstore.dev/quickstart/quickstart-ci/)
- [Sigstore blob signing](https://docs.sigstore.dev/cosign/signing/signing_with_blobs/)
- [Sigstore blob verification](https://docs.sigstore.dev/cosign/verifying/verify/)
