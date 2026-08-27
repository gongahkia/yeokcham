Implemented V4 bounded checkpoint retention and Linux command-capture follow-up.

- `yeokcham-v4 compact` drops unnamed timeline entries. Named roots are share,
  delivery, pin, open decision, draft/baseline, and pending restore-safety.
  Default extra keep is 32 newest unprotected checkpoints. Object bytes are not
  deleted. Published restore journals are pruned after a successful compact.
- Pins live in V4 project-state schema v3. V1 and V2 fixtures still decode.
- `status` prints `capture command` and `uncaptured yes|no`.
- `yeokcham-v4 watch` is Linux-only (1s quiet / 30s max) and calls `save`.
  Other platforms exit with an explicit unsupported error.

opam exec -- dune exec test/test_v4_model.exe
opam exec -- dune exec test/v4_model_property_test.exe
opam exec -- dune exec test/test_v4_record.exe
opam exec -- dune exec test/test_v4_restore_journal.exe
opam exec -- dune exec test/test_v4_local_service.exe
opam exec -- dune exec test/test_v4_cli.exe

This still does not implement blob GC, a durable capture-mode setting, or
macOS/WSL watchers.
