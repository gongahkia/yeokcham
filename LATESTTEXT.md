Implemented the local V4 four-fact loop: saved, shared, needs-a-decision, and delivered on one device.

- `save` remains recovery-only. `share` captures an exact tree, records `Whole_path` edits against the current delivery baseline, and either publishes the active draft or amends its linear revision chain.
- Local overlap of two shared drafts becomes a named decision without rewriting the working tree. `resolve` records a replacement revision; `withdraw` still cannot drop the active shared change.
- `deliver` requires a shared, decision-free active draft, consumes resolved changes, drops resolutions bound to the previous baseline, and starts a new draft.
- `yeokcham-v4 status` lists shared-change, decision, and delivery identities. `receive`, signatures, watcher capture, in-place restore, and transport are still out of scope.
- Model, local-service, and CLI journey tests cover share, amend, empty share, overlap, resolve, withdraw, blocked delivery, and successful delivery.

Verification passed:

```sh
opam exec -- dune build @fmt
opam exec -- dune exec test/test_v4_model.exe
opam exec -- dune exec test/v4_model_property_test.exe
opam exec -- dune exec test/test_v4_record.exe
opam exec -- dune exec test/test_v4_store.exe
opam exec -- dune exec test/test_v4_local_service.exe
opam exec -- dune exec test/test_v4_cli.exe
```

This deliberately stops before watcher-based capture, scratch compaction, in-place journaled restore, sharing transport, identity/signing, and Git interoperability.
