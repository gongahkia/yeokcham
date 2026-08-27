Implemented V4 in-place journaled restore without importing any V1-V3 product
semantics.

- `yeokcham-v4 restore --checkpoint ID` now replaces the active source tree.
  The existing `--destination PATH` path remains a non-destructive restore into
  an empty directory.
- Before replacement, V4 captures the current exact tree, publishes it through
  the V4 project-state head, and retains it as a safety checkpoint.
- A canonical create-only journal advances through `Prepared`, `Applying`,
  `Materialized`, and `Published`. An interrupted `Applying` phase can be
  repeated because replacement is re-derived from the target snapshot.
- In-place replacement preserves `.yeokcham` and `.git`; neither is canonical
  source content.
- The generic exact-snapshot materializer gained an explicit replacing adapter,
  but the restore state, journal, service, and CLI are V4-only.
- Golden, transition, service, recovery, metadata-preservation, and CLI journey
  tests cover the new slice.

Verification passed:

```sh
opam exec -- dune build @fmt
opam exec -- dune exec test/test_v4_model.exe
opam exec -- dune exec test/v4_model_property_test.exe
opam exec -- dune exec test/test_v4_record.exe
opam exec -- dune exec test/test_v4_store.exe
opam exec -- dune exec test/test_v4_restore_journal.exe
opam exec -- dune exec test/test_v4_local_service.exe
opam exec -- dune exec test/test_v4_cli.exe
```

This deliberately stops before watcher-based capture, scratch compaction,
sharing transport, and identity/signing. Git interoperability remains excluded
from V4.
