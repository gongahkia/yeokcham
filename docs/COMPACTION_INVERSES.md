# Exact inverse scratch compaction

## M3-D02 scope

Compaction can reduce exact source-event operations between two retained
checkpoints. It never removes a retained logical checkpoint, changes a
checkpoint ID, or treats a semantic similarity as an inverse.

The reducer uses a stack over the ordered source operations and removes only
adjacent structural inverses, including pairs made adjacent after an earlier
removal:

- create/delete and delete/create of the same exact entry at the same path;
- reciprocal content or mode changes at one path; and
- a move immediately followed by the same-entry reverse move.

Before writing a generated replacement event, Yeokcham applies both the original
composed sequence and the reduced sequence to the prior retained snapshot. Each
must reproduce the next retained snapshot byte-for-byte. A failed source or
reduced replay is a structured compaction error with no generation publication.
Unmatched operations remain in their original order.

## Inspect and verify

```text
opam exec -- dune exec bin/yeokcham.exe -- compact --dry-run --explain
opam exec -- dune runtest test/test_compaction.exe
opam exec -- dune runtest test/compaction_property_test.exe
make property-test PROPERTY_TEST_SEED=17
```

`inverse-pairs-eliminated` is a dry-run count. It is not a performance claim,
retention policy, semantic analysis result, or persistent schema field.
