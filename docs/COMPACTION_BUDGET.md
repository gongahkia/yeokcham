# Compaction storage-budget policy

## M3-D01 scope

`paengi compact --storage-budget-bytes N` bounds deterministic retention
selection. It does not enforce a total `.paengi/` directory size or delete
shared snapshot/content objects; M3 lacks the complete cross-domain root mark
needed to make that safe.

For each logical checkpoint, planning charges the exact current regular-file
bytes of its Checkpoint object plus its direct Scratch_event object when one
exists. The cost is planning evidence only and does not change a canonical
record or object format.

## Selection order

1. Retain every protected checkpoint and the logical scratch head.
2. Charge their costs first. If they exceed `N`, retain them and report the
   protected-only overrun.
3. Consider optional recent checkpoints newest-first, with logical checkpoint
   object ID as the tie-breaker.
4. Then consider periodic representatives in the same order.
5. Retain a candidate only when its cost fits the remaining budget; otherwise
   record `budget-excluded` and continue.

Pins, capsule/release/conflict/validation retention, and the current logical
head therefore remain resolvable. The selection makes no claim that all
repository bytes fit `N`.

## Inspect and verify

```text
opam exec -- dune exec bin/paengi.exe -- compact --dry-run --explain \
  --storage-budget-bytes 1048576
opam exec -- dune runtest test/test_compaction.exe
opam exec -- dune runtest test/compaction_property_test.exe
make property-test PROPERTY_TEST_SEED=17
```

`--explain` prints configured policy, retained/protected checkpoint-byte
accounting, every checkpoint decision, `budget-excluded-checkpoints`, and a
protected-only `budget-exceeded-bytes` value when applicable. Invalid negative
budgets reject before planning; analysis and dry-run publish no generation or
ref.
