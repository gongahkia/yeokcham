# Verifying a future V4 source release

Yeokcham has no published stable V4 source release yet. This document describes
how to verify a future candidate once a maintainer has published its tag,
expected source commit, public OpenPGP fingerprint, archive, and SHA-256
digest.

This is source-distribution provenance only. It does not create or verify a
Yeokcham device, authority epoch, package, relay permission, decision, or
delivery. It does not make an archive safe for a particular team by itself.

## Before verification

Obtain the maintainer's full OpenPGP primary-key or signing-subkey fingerprint
through an independent route.
Do not rely only on a key ID, a key fetched automatically during verification,
or a fingerprint carried solely by the archive being checked. Import the
corresponding public key into the GnuPG keyring you intend to use, using the
key-distribution procedure you trust.

Obtain the release tag, full commit ID, archive path, and SHA-256 digest from
the release announcement. A tag and an archive are separate things: the tag
binds a source commit, while the digest binds the exact archive bytes you
downloaded.

## Verify one candidate

Run the source tool directly, or use the Make target:

```sh
make release-verify \
  RELEASE_TAG=vX.Y.Z \
  RELEASE_COMMIT=FULL_COMMIT_OBJECT_ID \
  RELEASE_FINGERPRINT=FULL_OPENPGP_FINGERPRINT \
  RELEASE_ARCHIVE=/path/to/yeokcham-vX.Y.Z.tar.gz \
  RELEASE_SHA256=ARCHIVE_SHA256
```

`RELEASE_REPOSITORY` defaults to the current Git repository and can be set to a
different local checkout. Set `GPG` only when the OpenPGP executable is not
named `gpg` on your `PATH`.

Success prints the verified tag, commit, signer fingerprint, and archive
digest. Any failure is a refusal, not a partial success:

- a lightweight tag is not a release tag;
- an unsigned or invalid tag has no accepted signature;
- a valid signature from another key is still rejected;
- a tag pointing to another commit is rejected; and
- a changed archive is rejected.

The verifier never downloads keys or archives, never creates tags or releases,
and never calls `yeokcham`. It makes only a disposable operating-system
temporary file for GnuPG status output. GnuPG may maintain its usual local
keyring or agent state.

## Maintainer boundary

Before publishing an actual release, a maintainer must independently publish
the real full public fingerprint, create an annotated OpenPGP-signed tag that
points to the intended commit, make an immutable archive available, and publish
its SHA-256. The same verification command should succeed from a clean consumer
environment before any release claim.

Those maintainer actions, macOS field evidence, and opam publication are not
implemented or implied by this repository check. Do not replace them with a
test fixture or a locally generated key.
