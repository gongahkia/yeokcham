Implemented the first usable V4 vertical slice: model-first, local-first, exact snapshot capture and safe restore.

- The V4 contract and ADR now define the four states: saved checkpoints, active drafts, shared changes/decisions, and delivered history. See [V4 contract](/home/gongahkia/Desktop/coding/projects/yeokcham/docs/V4_PRODUCT_CONTRACT.md) and [ADR 079](/home/gongahkia/Desktop/coding/projects/yeokcham/docs/adr/079-v4-small-team-change-composer.md).
- Added immutable model state, revision chains, checkpoint history, edit-level conflicts, explicit resolution, and delivery tracking in [V4 model](/home/gongahkia/Desktop/coding/projects/yeokcham/lib/yeokcham_v4_model/yeokcham_v4_model.ml).
- Added canonical, versioned V4 persistence with V1 compatibility and golden fixtures.
- Added V4’s immutable state-object store with optimistic concurrency and protection against adopting an existing `.yeokcham` repository.
- Added local `init`, `save`, `status`, `timeline`, `draft new`, and safe checkpoint `restore` through [the V4 CLI](/home/gongahkia/Desktop/coding/projects/yeokcham/bin/yeokcham_v4.ml).
- V4 snapshot capture excludes both `.yeokcham` and `.git`, so restored source snapshots do not accidentally include Git metadata.
- Added model, property, persistence, storage, local-service, and end-to-end CLI tests.

Verification passed:

```sh
opam exec -- dune build @fmt
opam exec -- dune build @all
opam exec -- dune exec test/test_v4_model.exe
opam exec -- dune exec test/v4_model_property_test.exe
opam exec -- dune exec test/test_v4_record.exe
opam exec -- dune exec test/test_v4_store.exe
opam exec -- dune exec test/test_v4_local_service.exe
opam exec -- dune exec test/test_v4_cli.exe
git diff --check
```

`opam exec -- dune runtest` does not fully pass: the non-V4 OpenSSH integration test `test_peer_sync_ssh` fails with `peer transport ended mid-frame`. The V4-focused suite passes.

This deliberately stops before watcher-based capture, scratch compaction, in-place journaled restore, sharing transport, identity/signing, and Git interoperability. Those need their own vertical slices so the product doesn’t overstate capability.
