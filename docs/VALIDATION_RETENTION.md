# Passing-validation checkpoint retention

## M6-D01 scope

`validation run --retain-passing-checkpoints` is an explicit opt-in policy. It
stores ordinary immutable validation evidence first, then loads that stored
object and acts only when its status is `Passed`.

The policy selects every logical scratch checkpoint whose snapshot ID exactly
equals the evidence snapshot ID. Each gets the existing typed
`Validation_passed <validation-id>` retention reason. Multiple checkpoints may
match one immutable snapshot; all are retained because their equality is exact,
not an ambiguous intent guess. The reason is idempotent for one
evidence/checkpoint pair.

Failed, timed-out, execution-error, and no-matching-checkpoint outcomes leave
retention unchanged. The opt-in command may append immutable retention changes
and advance `retention-head`; it never changes `scratch-head`, workspace current
refs, release bindings, the evidence snapshot, or the evidence object. Ordinary
`validation run` and release-created validation evidence have no retention side
effect.

The existing ADR-023 retention-reason tag for `Validation_passed` already stores
the validation ID. This work adds no persistent schema, migration, or automatic
release ancestry inference. Compaction treats the resulting reason as protected
retention and preserves the logical checkpoint through generation activation.

## Verify

```text
opam exec -- dune runtest test/test_validation_retention.exe
opam exec -- dune runtest test/validation_retention_property_test.exe
make property-test PROPERTY_TEST_SEED=17
make check
```
