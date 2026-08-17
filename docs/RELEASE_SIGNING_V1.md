# Release signing v1

Release signing is a release-manager operation, not a repository credential.
The signing key's secret material must remain outside this checkout and outside
release evidence. The release gate takes an explicit expected fingerprint and
rejects a valid signature from any other key.

## Procedure

After independent field-trial evidence exists for the exact clean release
commit, the maintainer publishes the signing fingerprint through an independent
channel and records it in the release evidence. Consumers obtain that public
key from the same independent channel, compare its full fingerprint byte for
byte, then verify both tag and archive:

```sh
git verify-tag vMAJOR.MINOR.PATCH
git tag --verify vMAJOR.MINOR.PATCH
sha256sum -c yeokcham-MAJOR.MINOR.PATCH.tar.gz.sha256
```

The release manager supplies the same full 40-hex fingerprint to the local
gate:

```sh
make release-gate \
  RELEASE_VERSION=MAJOR.MINOR.PATCH \
  RELEASE_SIGNING_FINGERPRINT=<40-hex-fingerprint> \
  RELEASE_EVIDENCE_DIR=/absolute/path/to/evidence \
  RELEASE_ARCHIVE=/absolute/path/to/yeokcham-MAJOR.MINOR.PATCH.tar.gz
```

The actual maintainer fingerprint and a signed release tag have not been
established in this repository. This document intentionally does not invent
either value; #243 remains open until the key owner supplies independent,
verifiable release evidence.

## Invariants and tests

The gate requires a clean `HEAD`-pointing annotated tag, a cryptographically
valid tag signature, and a `VALIDSIG` primary or signing-subkey fingerprint
matching the supplied expectation. Its fixture test covers malformed
fingerprints, lightweight and wrong-commit tags, unsigned tags, and a valid
ephemeral test-key signature with a mismatched expected fingerprint when a
local GPG agent is available.

No canonical Yeokcham format, object, or ref changes. No ADR change is needed.
