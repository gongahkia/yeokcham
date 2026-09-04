# Experiment 103 — EVIDENCE-001 security-boundary review

- Date: 2026-09-04
- Scope: development V4 implementation, checked-in deployment material, and
  automated tests. This is a code-and-document review, not a penetration test,
  a remote-workflow attestation, or a production deployment assessment.

## Review record

| Boundary | Reviewed controls and evidence | Result and limit |
| --- | --- | --- |
| Relay bearer access | [ADR-087](../adr/087-v4-scoped-relay-access.md) stores SHA-256 verifiers instead of plaintext 256-bit secrets; credentials are repository/scoped, finite-lived, revocable, and rotation revokes the old one atomically. `test/test_v4_relay_access.ml` covers scope, expiry, revocation, and rotation; `test/test_v4_cli.ml` refuses non-interactive secret output. | Automated boundary evidence exists. A copied, currently valid bearer remains replayable by design; TLS, scope, expiry, rotation, and revocation limit rather than remove that exposure. |
| TLS proxy deployment | [ADR-102](../adr/102-development-relay-packaging-and-operation.md) keeps TLS termination outside the plain-HTTP relay, requires a separately operated reverse proxy, and rejects direct-public-HTTP as an operational configuration. `test/test_relay_container.sh` runs the client through a disposable TLS proxy. | [Unverified] No external proxy, DNS, certificate automation, or public deployment has been exercised. |
| Relay path/object/range/decompression limits | Relay routes validate canonical SHA-addressed object identities and body bounds; V2 transfer uses bounded 1 MiB ranges and rejects malformed overlap/gap, zstd corruption, and decompression expansion. `test/test_v4_transport.ml` and `test/test_v4_transfer.ml` cover malformed peer bytes, route IDs, ranges, quotas, expiry, and decompression refusal. | Automated adapter evidence exists; it is not a general network-security assessment. |
| Hook redaction | [ADR-101](../adr/101-v4-versioned-cli-data-and-post-operation-observers.md) makes observer payload rendering pure and excludes credentials/secret-provider values. `test/test_v4_hook_runner.ml` checks redacted argv launch, no inherited secret, and secret-shaped event rejection; `test/test_v4_cli.ml` checks configured hook argv redaction. | Automated interface evidence exists. Hook executables remain user-authorized local programs, not a sandbox. |
| Repair provenance | [ADR-100](../adr/100-v4-scoped-verification-and-conservative-sourced-repair.md) requires an explicit source, candidate ID, plan digest, expiry, and reread/verification before write. `test/test_v4_repair.ml` covers exact backup provenance, disappearing/stale candidates, interrupted staging, and source-tree non-mutation. | Automated evidence supports conservative repair refusal; it does not make any backup trustworthy by itself. |
| Backup exposure | [RELAY_OPERATIONS.md](../RELAY_OPERATIONS.md) requires a checksum, disposable-volume restore, and a regular drill; the OCI test rejects a deliberately corrupt archive and reads the restored volume before a bootstrap smoke journey. | Backup bytes are still as confidential as the operator's volume/archive storage. Encryption, retention enforcement, and off-site backup operations are [Unverified]. |
| OCI and CI supply chain | [Experiment 100](100-evidence-security-review.md) records full-SHA action pins. [ADR-102](../adr/102-development-relay-packaging-and-operation.md) requires digest-addressed images plus SBOM/provenance and keyless OIDC signing. `make workflow-security-test` rejects mutable action references; the CI smoke job builds package and OCI journeys. | Checked-in policy and local static enforcement exist. [Unverified] No current-revision remote build, published digest, SBOM/provenance attestation, or Cosign verification artifact has been inspected. |

## Finding status

`EVIDENCE-SEC-001` is resolved in the checked-in workflows: every third-party
action is pinned to its reviewed full commit SHA and has a release-tag mapping
recorded in Experiment 100. `make workflow-security-test` is the regression
check. The remaining [Unverified] deployment and remote-artifact boundaries are
explicit evidence gaps, not accepted security findings or release claims.

## External references

- [RFC 6750 bearer-token transport](https://www.rfc-editor.org/info/rfc6750/)
- [GitHub secure use: full-SHA action references](https://docs.github.com/en/actions/reference/security/secure-use)
- [Docker BuildKit attestations](https://docs.docker.com/build/metadata/attestations/)
- [Sigstore Cosign verification](https://docs.sigstore.dev/cosign/verifying/verify/)
