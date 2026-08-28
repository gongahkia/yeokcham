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

Earlier product-track ADRs have been removed with their implementations. Git
history retains their historical record; they are not active architecture.
