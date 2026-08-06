# Retargeting uncertainty and fallback demonstration

## M11-07 vertical slice

`tools/demo/demonstrate-retargeting-v1.sh` runs a deterministic, pure
demonstration helper against in-memory evidence and bytes. It prints three
semantic evidence outcomes and three independent textual-baseline outcomes:

- incomplete alias evidence is `uncertain-anchor`, never automatically applied;
- exact textual fallback remains low confidence and non-automatic;
- equivalent candidates remain `ambiguous-anchor` with both reports retained;
- unique byte preimage relocation applies only as a textual result;
- duplicate byte preimages become an inspectable `ambiguous-match`; and
- an invalid textual operation is a returned `rejected` error.

The helper imports only the pure `yeokcham_semantic_retarget` and
`yeokcham_textual_patch` boundaries. It opens no repository, executes no parser
or compiler process, reads no project source, and writes no object, ref,
snapshot, capsule, workspace, release, or semantic sidecar state.

## Run and inspect

```sh
sh tools/demo/demonstrate-retargeting-v1.sh
```

The output exposes outcome, evidence stage, confidence, automatic-application
permission, fallback use, and candidate count. It is a bounded demonstration,
not a TypeScript parser, compiler, retargeting engine, semantic identity, or
production-safety claim. The checked 40-case experiment, host-specific results,
and limitations remain in `docs/experiments/semantic-sidecar-v1.md`.

Malformed script arguments and an invalid helper path reject nonzero. The
demonstrated invalid patch is a returned error value; the duplicate candidate
case is a returned conflict value. Neither creates repository state.

No model type, persistent format, ADR, `yeokcham` CLI behavior, semantic sidecar
storage, source rewrite, materialisation, release, Git export, sync state, or
performance claim is added.

## Verification

`test_demo_retargeting` runs the script with the deterministic helper and
asserts uncertainty, fallback, ambiguity, textual application, structured
conflict, and structured invalid-operation output. `make check` runs the
focused test.
