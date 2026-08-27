# V4 roadmap

This file is the local source of truth for V4 slice tracking. Completion claims
require the stated acceptance criteria and recorded verification evidence.

1. Seal the current local slice.
   - The committed CLI and model APIs agree; the Linux watcher test supplies
     --username; documentation is in a separate commit.
   - Evidence: focused V4 tests and a green Ubuntu dune runtest including
     test_v4_watch.exe. A macOS run cannot substitute for the Linux proof.

2. Provide a richer isolated resolver inspection surface.
   - decision inspect shows canonical candidate provenance and edit metadata.
   - decision diff compares one candidate with the baseline or another
     candidate using exact structural snapshot entries, without textual
     interpretation or mutations.
   - Evidence: service and CLI tests cover ordering, invalid candidates,
     binary-safe metadata, and no state/working-tree change.

3. Define V4 device identity and signing before coding it.
   - A dedicated ADR specifies self-certifying Ed25519 devices, a
     multi-administrator causal membership policy, native signer providers,
     enrollment, record domains, and deferred revocation/epoch succession.
   - Usernames remain local display metadata, never identity or authority.
   - Evidence: approved ADR and canonical record/test-vector specification.

4. Implement verified offline receive.
   - A versioned directory package carries signed records and complete
     immutable object closure. Receive verifies before publishing revisions
     and derived open decisions; it never writes the working tree or
     auto-resolves.
   - Evidence: exchange, signature, closure, rejection, idempotence, and
     working-tree-preservation tests.

5. Add a transport adapter only after verified receive is sound.
   - Reuse the verified package/closure boundary rather than creating a second
     V4 import path.

6. Consider Git import/export after V4’s local and receive semantics are
   stable.

7. Add macOS/WSL watchers only after the Linux proof and CI baseline;
   WSL needs real field testing rather than assuming inotify behavior.

8. Leave CI-backed delivery late. It needs separate validation evidence
   and policy; automatically treating a CI result as deliver would
   violate the model’s rule that delivery is not approval.

9. Retire V1–V3 last, through explicit deprecation/archive/migration
   policy—not deletion—once V4 has replacement paths.
