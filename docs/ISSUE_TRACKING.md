# GitHub issue tracking

GitHub Issues is the live backlog; this file records only the active V4
boundary. Inspect live bodies, labels, and blocking relationships before work.

The V4 lifecycle and V4-only cutover have removed earlier product code and
documentation from `main`; historical evidence remains in Git history. Issues
[#242](https://github.com/gongahkia/yeokcham/issues/242),
[#243](https://github.com/gongahkia/yeokcham/issues/243), and
[#244](https://github.com/gongahkia/yeokcham/issues/244) remain open
release/distribution work. V4-only cutover does not satisfy their field-trial,
release-signing, or opam-publication criteria, so do not close them as a
retirement side effect. Their retired command references need explicit future
re-scoping before that work begins.

The immediate open verification item is not a substitute issue or a completion
claim: run `opam exec -- dune exec test/test_v4_watch.exe` on Linux, or record a
green Ubuntu `dune runtest` that includes it. See
`TESTING_AND_EXPERIMENTS.md` for what counts as evidence.

Future feature proposals need a dedicated issue and ADR before coding when they
change trust, transport, delivery, snapshot retention, or persistent semantics.
