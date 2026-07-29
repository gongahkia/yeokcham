# Contributing

Paengi is a model-first research prototype. Contributions must preserve the separation of scratch, intent, and release history.

## Before changing code

1. Read the documents listed in `AGENTS.md` in order.
2. Select the first eligible open task in `TODO.md` and stay within one milestone.
3. Record the active vertical slice, types, invariants, tests, and ADR impact in `TODO.md`.
4. Open or amend an ADR before implementing an architectural or persistent-format decision.

## Implementation order

For each feature:

1. Define algebraic types.
2. State invariants.
3. Implement pure transitions.
4. Add unit and generated property tests.
5. Add persistent adapters and failure tests.
6. Add CLI behavior.

Exact bytes remain canonical. Semantic data is optional sidecar metadata. Ambiguity must become a proposal, confidence value, conflict, or explicit user choice.

## Local checks

Use OCaml 5.5.0 and Dune 3.23 or newer.

```bash
opam install . --deps-only --with-test
opam exec -- dune build @opam @fmt @lint @all
opam exec -- dune runtest
```

Generated `paengi.opam` changes must be produced from `dune-project` and applied with `dune promote`.

## Pull requests

- Keep each commit limited to one model change or TODO task.
- Include the invariant and tests in the commit or pull-request description.
- Update `TODO.md`; update the formal model when semantics change.
- Add golden fixtures for persistent-format changes and retain old-format fixtures.
- Record experiment results separately from product claims.
- Do not use OCaml `Marshal` for persistent data.
- Do not overstate unmeasured or uncertain behavior.

Contributions are licensed under the repository's MIT License.
