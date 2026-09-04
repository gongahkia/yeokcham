# Historical GitHub issue record

As of 2026-09-04, [`ACTIVE-TICKLIST.md`](../ACTIVE-TICKLIST.md) is the sole
authoritative development tracker. GitHub Issues are not a live backlog and
must not be used as a prerequisite for work. The historical records below
preserve former issue scope, accepted V4 evidence, and ADR relationships.

Issues [#242](https://github.com/gongahkia/yeokcham/issues/242) and
[#244](https://github.com/gongahkia/yeokcham/issues/244) have been migrated to
the `MACOS-001` and `DIST-OPAM-001` deferred items in the active ticklist. Their
closure records a roadmap migration/deferment, not completion of macOS field
trials or opam publication.

[#263](https://github.com/gongahkia/yeokcham/issues/263), V4 onboarding and
exact local inspection, is complete and closed. It adds source-only evaluation
guidance, command discovery, recovery-first material, explicit
collaboration/relay operation, and `changes`: a current-working-tree versus
latest-saved-checkpoint exact comparison. It adds no persistent format, generic
verification command, Git interchange, clone workflow, authority semantics, or
relay behaviour. On 2026-09-04, `make ci`, `make release-verify-test`, focused
service/CLI tests, and demo-fixture shell syntax passed; the optional PKCS#11
integration was skipped because its test module was unset. This is not a
published-release, installer, field-trial, or cross-platform-support claim.

[#250](https://github.com/gongahkia/yeokcham/issues/250), Git interchange,
[#249](https://github.com/gongahkia/yeokcham/issues/249), durable command
metadata, and [#253](https://github.com/gongahkia/yeokcham/issues/253), CI
attestations, are closed as not planned. V4 does not import from, export to, or
present itself as compatible with Git; it retains no persistent command diary;
and CI does not enter the V4 model. WSL is unsupported and not planned; it is
neither implementation nor release-gate evidence. #242 and #251 retain only
their separate macOS evidence and watcher work.

[#251](https://github.com/gongahkia/yeokcham/issues/251), macOS advisory
capture, is complete. ADR-096 limits it to a foreground FSEvents source that
requests existing exact save; it adds neither a macOS daemon nor a V4 model,
authority, transport, or persistent-format change. Its real-host evidence is
recorded separately in `TESTING_AND_EXPERIMENTS.md`; it does not establish
Linux, daemon, WSL, or release support.

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

[#261](https://github.com/gongahkia/yeokcham/issues/261), the V4 advisory
background runtime, is complete. ADR-089 defines a Linux-only private XDG
runtime with a kernel-backed single-owner lock, local control socket,
disposable bounded observability, crash restart, and no service-unit or
autostart policy. It schedules only existing debounced scratch capture by
default; `daemon sync` is explicit and reuses the ordinary staged,
receive-first transport path without working-tree mutation.

[#247](https://github.com/gongahkia/yeokcham/issues/247), durable restore
recovery after journal pruning, is complete. ADR-090 adds a canonical,
local-only restore proof for both snapshots of every explicit in-place restore.
Compaction validates those roots and only prunes a completed journal after a
matching proof exists; explicit `restore forget` is the sole removal path.

[#248](https://github.com/gongahkia/yeokcham/issues/248), explicit retention
roots and safe local object collection, is complete. ADR-091 defines a pure
reachability plan over every named checkpoint closure, durable restore roots,
and the current V4 state head. `storage gc --dry-run --explain` shows every
retain/collect decision; `--apply` only stages a local canonical quarantine;
`restore`, `resume`, and revalidated `purge` make interruption explicit. The
collector neither changes the working tree nor touches package or relay
storage. Tests cover chunk manifests, shared work, empty worktrees, corrupt or
missing closure, a state-head change after staging, and purge recovery.

[#260](https://github.com/gongahkia/yeokcham/issues/260), exact
decision-proposal assistance, is complete. ADR-092 defines a parser-free,
ephemeral comparison of one named candidate pair. It displays complete
provenance, every exact path source, and granular refusals; it has no proposal
acceptance or rejection event. A ready output can be materialised only outside
the live working tree, and a person must still use the separate explicit
resolution command to create durable V4 process state. Proposal side
information is neither stored in the project model nor transferred through
package, relay, bootstrap, authority, or delivery state. Tests cover
competing-pair enumeration, stale inputs, byte-exact file/mode/symlink/binary
output, conflict/refusal, missing closure, destination isolation, and the
later explicit resolution journey.

[#252](https://github.com/gongahkia/yeokcham/issues/252), V4 device custody,
is complete. ADR-093 keeps an opaque signing capability outside the V4 model
and records. Existing native signers remain the default; a person may explicitly
attach one `ssh-ed25519` SSH-agent key or create/attach one PKCS#11 Ed25519
token key. Local canonical custody profiles select only the provider and exact
public key; they contain no PIN or private material and grant no authority.
Changing an active device still uses the ordinary explicit signed rotation.
Focused tests cover the canonical profile, live SSH agent, disposable SoftHSM
token, all V4 signing purposes, non-exportability, unavailable/locked/mismatched
providers, and declined rotation without a repository or working-tree write.

[#254](https://github.com/gongahkia/yeokcham/issues/254), conservative external
LSP semantic sidecars, is complete. ADR-094 adds an opt-in local configuration
for one already-installed, named language server and runs it only over three
disposable exact snapshot materialisations. Its bounded, stdio-only protocol
session can request symbols, definitions, references, and workspace symbols;
it refuses server-initiated edits, commands, and configuration. Results are
session-only, disclosed with their exact snapshot, command, version, and
capabilities, and can only mark a possible overlap beside the byte-exact
decision proposal. An absent, ambiguous, incompatible, malformed, slow, or
over-budget server produces unavailable semantic advice without affecting the
proposal or any V4 state. The fake-server evidence covers disposable-root
binding, all three snapshots, both broader sensitivity modes, malicious
requests, malformed and oversized replies, timeout, and repository-state
preservation.

[#243](https://github.com/gongahkia/yeokcham/issues/243), V4 source-tag
verification tooling, is complete. ADR-095 adds a local, explicit verifier for
one annotated OpenPGP-signed Git tag, its exact source commit, an independently
obtained full primary-key or signing-subkey fingerprint, and a local archive's
SHA-256. It is outside V4 identity, authority, history, package, relay, and
delivery semantics; it neither downloads keys or archives nor creates a tag,
release, or project state. Disposable GnuPG/Git evidence covers valid primary
and signing-subkey paths plus malformed input, lightweight and unsigned tags,
fingerprint mismatch, wrong commit, changed archive, and no `.yeokcham` write.
Publishing a real key or source release, recording field evidence, and opam
submission remain separate maintainer actions.

[#257](https://github.com/gongahkia/yeokcham/issues/257), relay payload
encryption, is closed as not planned for the active V4 milestone. V4's small
trusted-team boundary is the existing HTTPS relay and verified staged receipt;
the relay can read stored payloads. End-to-end payload privacy is not implied,
and any future proposal must start with a dedicated issue and ADR rather than
reuse retired V1–V3 protocol or runtime formats.

Future feature proposals need a dedicated issue and ADR before coding when they
change trust, transport, delivery, snapshot retention, or persistent semantics.
