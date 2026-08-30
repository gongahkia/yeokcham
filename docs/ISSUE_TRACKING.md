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

[#246](https://github.com/gongahkia/yeokcham/issues/246), V4 signed relay
transport, is complete and closed. ADR-085 records its package staging
boundary, authority/decision semantics, and no-working-tree-mutation
invariant.

The Linux watcher loop passed in the latest local `dune runtest` on Fedora 43;
that result is recorded in `TESTING_AND_EXPERIMENTS.md` and is not transport
evidence. #246 has local HTTPS reverse-proxy, post-receive
upload-interruption/retry, feed-fork, signed-resolution, and
incomplete-closure evidence recorded there. Its malicious-peer matrix and
late-review feed-fork retry case now cover the remaining ADR-085 acceptance
criteria. No local test result alone is a deployment claim.

[#256](https://github.com/gongahkia/yeokcham/issues/256), verified bootstrap,
[#258](https://github.com/gongahkia/yeokcham/issues/258), scoped relay access,
and [#262](https://github.com/gongahkia/yeokcham/issues/262), the transport
no-working-tree-mutation guardrail, are complete. Bootstrap accepts a signed,
immutable basis from an untrusted relay, validates it before creating local
state, and only materialises a working tree on a later explicit restore. The
receipt module owns receive and sync receipt without a snapshot or
materialisation dependency; the product contract includes a review checklist
for that boundary. Scoped relay access uses operator-local repository read/write
credentials with finite lifetime, rotation, and revocation; it does not change
authority, package, publication, or receipt semantics.

[#255](https://github.com/gongahkia/yeokcham/issues/255), honest V4 terminal
inspection, is complete. `log` and `graph` are pure projections of persisted
work; `graph --authority` renders the epoch DAG separately. Their stable plain
text output exposes unresolved decisions and concurrent heads without creating
synthetic delivery ancestry or authority policy.

[#259](https://github.com/gongahkia/yeokcham/issues/259), online authority
coordination evaluation, is complete. ADR-088 rejects coordinators, quorums,
leases, threshold authority, and witness receipts as V4 authority inputs. An
active administrator may act while disconnected; concurrent epochs remain
explicit until a valid reconciliation.

The remaining V4 backlog is relay payload encryption
[#257](https://github.com/gongahkia/yeokcham/issues/257), explicit
decision-proposal assistance [#260](https://github.com/gongahkia/yeokcham/issues/260),
and advisory background runtime [#261](https://github.com/gongahkia/yeokcham/issues/261).
None may reuse retired V1–V3 protocol or runtime formats.

Future feature proposals need a dedicated issue and ADR before coding when they
change trust, transport, delivery, snapshot retention, or persistent semantics.
