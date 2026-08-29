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

The active implementation vertical slice is [#246](https://github.com/gongahkia/yeokcham/issues/246): V4 signed relay transport. It is governed by ADR-085 and must retain the package staging boundary, authority/decision semantics, and no-working-tree-mutation invariant.

The Linux watcher loop passed in the latest local `dune runtest` on Fedora 43;
that result is recorded in `TESTING_AND_EXPERIMENTS.md` and is not transport
evidence. #246 has local HTTPS reverse-proxy, post-receive
upload-interruption/retry, feed-fork, signed-resolution, and
incomplete-closure evidence recorded there. Its malicious-peer matrix and
late-review feed-fork retry case now cover the remaining ADR-085 acceptance
criteria; the issue is ready to close after its final documented verification.
No local test result alone is a deployment claim.

Future feature proposals need a dedicated issue and ADR before coding when they
change trust, transport, delivery, snapshot retention, or persistent semantics.
