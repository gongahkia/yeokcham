# Source-release verification

The repository includes a verifier for an explicitly supplied source-release
candidate. It requires an annotated OpenPGP-signed Git tag, its exact commit,
an independently trusted full signing fingerprint, a local archive, and the
expected SHA-256 digest. The existing lightweight `1.0.0` tag does not meet
these requirements; this document does not retroactively certify it.

Import the trusted public key into your verification keyring and obtain the
expected values independently of an untrusted archive. Then run:

```sh
tools/verify-v1-source-release.sh --repo SOURCE_CHECKOUT \
  --tag TAG --commit FULL_COMMIT_SHA --fingerprint FULL_OPENPGP_FINGERPRINT \
  --archive ARCHIVE_PATH --sha256 ARCHIVE_SHA256
```

The [verifier](../tools/verify-v1-source-release.sh) fails on unsigned or
lightweight tags, unexpected commits or signers, and mismatched archive bytes.
It checks the supplied digest, not a reconstruction of the archive from the
tag. A maintainer must establish that correspondence when publishing the
candidate. Run `make release-verify-test` to exercise the verifier's fixtures.

Publishing a future source release needs a separately reviewed release
decision and these concrete verification materials. The current CI workflows
publish development artifacts; they do not create stable source releases or
alter Yeokcham project authority. See [Development artifacts](DEVELOPMENT_ARTIFACTS.md)
for those distinct signing and verification steps.
