# Experiment 100 — EVIDENCE-001 supply-chain review

- Date: 2026-09-04
- Scope: checked-in GitHub Actions workflow references only
- Method: inspect every `uses:` reference, resolve its declared tag against the
  upstream action repository, and enforce the resulting full commit SHA in
  `test/test_workflow_security.sh`

## Finding EVIDENCE-SEC-001

The workflows initially referenced mutable major or release tags. GitHub
documents a full commit SHA as the immutable action reference, so a moved or
compromised tag could otherwise change the code that receives repository
contents, the GitHub token, registry credentials, or the OIDC signing token.
The resolved mappings are now:

| Action | Reviewed tag | Commit SHA |
| --- | --- | --- |
| `actions/checkout` | `v6.1.0` | `d23441a48e516b6c34aea4fa41551a30e30af803` |
| `ocaml/setup-ocaml` and `lint-fmt` | `v3.8.0` | `e89b2ded52a6e13f50162220cf5fe47290162032` |
| `docker/setup-buildx-action` | `v3.11.1` | `e468171a9de216ec08956ac3ada2f0791b6bd435` |
| `docker/login-action` | `v4.4.0` | `af1e73f918a031802d376d3c8bbc3fe56130a9b0` |
| `docker/build-push-action` | `v7.3.0` | `53b7df96c91f9c12dcc8a07bcb9ccacbed38856a` |
| `sigstore/cosign-installer` | `v4.1.2` | `6f9f17788090df1f26f669e9d70d6ae9567deba6` |
| `actions/upload-artifact` | `v4.6.2` | `ea165f8d65b6e75b540449e92b4886f43607fa02` |

`make workflow-security-test` rejects a non-SHA action reference and verifies
every expected action/tag/SHA tuple. Updating an action requires reviewing its
upstream source and changing both the workflow and this table/test in one
commit. This is an integrity control for checked-in workflow references; it
does not establish that a remote workflow ran safely.

The normal CI workflow also runs a dedicated Ubuntu package-and-OCI smoke job.
It checks that the Docker service is reachable before building the unsigned
development archive/RPM and executing the bounded relay-container journey.
This makes a missing OCI runtime a failed CI condition rather than an implicit
skip. Its remote result remains [Unverified] until a run for the current
revision completes.

## External references

- [GitHub secure use reference: full-SHA action pins](https://docs.github.com/en/actions/reference/security/secure-use)
- [GitHub OIDC permission boundary](https://docs.github.com/en/actions/reference/security/oidc)
- [Docker provenance and SBOM attestation guidance](https://docs.docker.com/build/metadata/attestations/)
- [Sigstore blob verification](https://docs.sigstore.dev/cosign/verifying/verify/)
