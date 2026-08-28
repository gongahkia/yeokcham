# V4 roadmap

This file is the local source of truth for the V4 replacement track. Completion
claims require the stated acceptance criteria and recorded verification
evidence.

1. Complete branch-safe device lifecycle and recovery (ADR-084).
   - Add pure canonical authority epochs, branch-scoped signed revisions,
     causal revocation frontiers, durable authority review/adoption, one-use
     authorisations, atomic rotation, and a human reconciliation path.
   - Add a safe fresh-device join that verifies a twelve-word root phrase and
     imports a full authority closure without touching the working tree.
   - Add optional creation and one-time use of a 24-word-mnemonic encrypted
     recovery package. A successful use revokes the replaced device and rotates
     recovery authority.
   - Every new record needs canonical/legacy decoder, golden, unit, generated,
     package-failure, and two-repository tests.

2. Retire the V1--V3 product tracks after the lifecycle tests pass.
   - Promote V4 as the sole `yeokcham` executable. Remove old commands, product
     code, fixtures, documentation, and V1--V3 issues from `main`; no migration
     or compatibility alias is required because there are no current users.
   - Retain unversioned encoding, envelope, object-store, snapshot, hashing,
     chunking, testkit, and Linux watcher modules as V4 foundations.
   - Close #242, #243, and #244 with the documented retirement disposition.

1. Seal the current local slice.
   - The committed CLI and model APIs agree; the Linux watcher test supplies
     --username; documentation is in a separate commit.
   - Local focused tests are green on Darwin. Still open: a green Ubuntu
     `dune runtest` including `test_v4_watch.exe`. A macOS run cannot
     substitute for the Linux proof.

2. Provide a richer isolated resolver inspection surface.
   - decision inspect shows canonical candidate provenance and edit metadata.
   - decision diff compares one candidate with the baseline or another
     candidate using exact structural snapshot entries, without textual
     interpretation or mutations.
   - Done: `decision inspect` and `decision diff` are read-only service/CLI
     surfaces with ordering, invalid-candidate, binary-safe metadata, and
     no-state/no-working-tree test coverage.

3. Define V4 device identity and signing before coding it.
   - A dedicated ADR specifies self-certifying Ed25519 devices, a
     multi-administrator causal membership policy, native signer providers,
     enrollment, record domains, and deferred revocation/epoch succession.
   - Usernames remain local display metadata, never identity or authority.
   - Done for the current boundary: ADR-083, canonical Ed25519 certificate
     and signed-revision records, causal multi-administrator enrollment,
     macOS Keychain/Linux Secret Service providers, and focused tampering and
     causality tests. Still deferred: an independently confirmed new-device
     join, revocation, epochs, rotation, recovery, external signers, and
     RFC-vector coverage plus a package-manifest golden fixture.

4. Implement verified offline receive.
   - A versioned directory package carries signed records and complete
     immutable object closure. Receive verifies before publishing revisions
     and derived open decisions; it never writes the working tree or
     auto-resolves.
   - Done for existing V4 projects: versioned directory packages carry the
     exact signed-revision snapshot closure; receive verifies membership
     continuity, signatures, causal parents, and closure in staging before
     one state-head update, without working-tree mutation. Focused exchange,
     signature, closure, rejection, retry-idempotence, and preservation tests
     are green. An explicit new-device join remains follow-up work.

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
