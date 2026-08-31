# Architecture decisions

The active V4 decisions are:

- [ADR-079](docs/adr/079-v4-small-team-change-composer.md): small-team change
  composer with explicit decisions.
- [ADR-080](docs/adr/080-v4-in-place-restore-journal.md): retained safety
  checkpoint and restartable in-place restore.
- [ADR-081](docs/adr/081-v4-bounded-checkpoint-retention.md): bounded scratch
  retention with explicit pins.
- [ADR-082](docs/adr/082-v4-linux-command-capture.md): command capture and
  advisory Linux watcher debounce.
- [ADR-083](docs/adr/083-v4-device-identity-and-signed-receive.md): device
  identity, signer custody, and verified offline receipt.
- [ADR-084](docs/adr/084-v4-branching-authority-epochs-and-recovery.md):
  branching authority epochs, forward-looking revocation, exact adoption, key
  rotation, phrase-checked join, and recovery authority.
- [ADR-085](docs/adr/085-v4-verified-signed-relay-transport.md): signed relay
  publication feeds, staged package receipt, local credential custody, and
  receive-first partial-success semantics.
- [ADR-086](docs/adr/086-v4-verified-relay-bootstrap.md): explicit signed
  bootstrap bases for fresh replicas, with a separate receipt boundary.
- [ADR-087](docs/adr/087-v4-scoped-relay-access.md): operator-local,
  repository-scoped relay access with rotation and revocation.
- [ADR-088](docs/adr/088-v4-reject-online-authority-coordination.md): rejects
  online authority coordination; disconnected administrator actions remain
  valid and concurrent authority epochs remain explicit until reconciled.
- [ADR-089](docs/adr/089-v4-linux-advisory-background-runtime.md): Linux-only
  managed advisory capture with explicit receipt-bound synchronization and
  disposable private runtime state.
- [ADR-090](docs/adr/090-v4-durable-restore-proofs.md): local durable recovery
  proof for each explicit in-place restore, retained until explicit forget.
- [ADR-091](docs/adr/091-v4-local-recoverable-garbage-collection.md): local
  reachability planning and explicit recoverable object collection.
- [ADR-092](docs/adr/092-v4-exact-decision-proposal-assistance.md):
  parser-free, exact-source proposal inspection for open decisions, with no
  automatic or durable proposal acceptance.
- [ADR-093](docs/adr/093-v4-device-custody-providers.md): explicit local
  native, SSH-agent, and PKCS#11 Ed25519 custody providers without changing
  device identity, authority, or signed record bytes.
- [ADR-094](docs/adr/094-v4-external-lsp-semantic-sidecars.md): optional
  external LSP observations over disposable exact decision snapshots; they are
  bounded local advice, never a parser, merge engine, trust input, or V4 state.
- [ADR-095](docs/adr/095-v4-source-release-verification.md): explicit
  maintainer/consumer verification of a signed source tag, exact commit,
  expected OpenPGP fingerprint, and source-archive digest, outside V4 trust
  and history.

Earlier product-track ADRs have been removed with their implementations. Git
history retains their historical record; they are not active architecture.
