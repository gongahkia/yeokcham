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

Earlier product-track ADRs have been removed with their implementations. Git
history retains their historical record; they are not active architecture.
