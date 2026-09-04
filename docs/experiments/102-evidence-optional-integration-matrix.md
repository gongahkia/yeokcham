# Experiment 102 — EVIDENCE-001 optional integration matrix

The ordinary GitHub Actions matrix is the supported continuous evidence path:
Linux and macOS run the model, generated, golden, protocol-fault, and local
receipt non-mutation suites. The separate Ubuntu `package-and-oci-smoke` job
builds the development RPM/archive and runs the disposable OCI relay/proxy,
backup-restore, scoped-access, and source-unchanged journey. It is deliberately
a development test, not a published artifact or service claim.

`make workflow-ci-test` parses the checked-in workflow and refuses removal of
the Linux/macOS matrix or the dedicated Docker/package-and-OCI smoke job;
`make workflow-security-test` separately enforces full-SHA action pins.

The following integrations need a separately recorded environment. They are
not skipped successes.

| Integration | Re-entry conditions | Evidence status |
| --- | --- | --- |
| Physical PKCS#11 device | A person provides a non-production token, exact module, and PIN through an approved isolated test host. | [Unverified] CI's SoftHSM exercise proves only the software-token adapter. |
| Existing SSH agent | A person supplies a dedicated test agent/key with forwarding disabled and records the OS/OpenSSH version. | [Unverified] The disposable local agent test covers the protocol boundary only. |
| macOS Keychain | A macOS host with an interactive test account and Keychain permission is available. | [Unverified] macOS CI does not establish end-user Keychain authorization behaviour. |
| Rootless Docker or Podman relay | An isolated Linux host exposes the intended rootless runtime and proxy configuration. | [Unverified] The OCI smoke checks Docker runtime hardening, not every runtime. |
| External TLS proxy and DNS/certificate automation | An isolated non-production domain, proxy configuration, and certificate issuer are available. | [Unverified] Loopback TLS verifies the client/relay boundary; it is not deployment evidence. |

For every re-entry, record date, host OS/kernel/runtime versions, exact command
and configuration (with credentials and payload bytes redacted), result,
ordinary-source non-mutation result where applicable, and observed limitations
in `TESTING_AND_EXPERIMENTS.md`. No result changes a compatibility, support,
or release claim without a separate explicit decision.
