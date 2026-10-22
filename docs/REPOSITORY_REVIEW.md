# Repository review: purpose, principles, and implementation

Reviewed against the `main` source beginning at `f4b46b3`, October 2026. This
review covers product behavior, the CLI, persistence and recovery, trust and
transfer boundaries, tests, onboarding, and GitHub Actions. It is not a proof
of the absence of bugs or an independent cryptographic audit. `README.md`
was left unchanged.

## What Yeokcham seeks to do

Yeokcham gives a small trusted team a vocabulary for progress that a single
commit concept cannot express well. Ordinary editing produces recoverable
scratch snapshots. A person separately names shared intent, explicitly
resolves ambiguous composition, and records a delivery milestone. Local work
and authority remain usable offline; the relay transports verified immutable
bytes without deciding membership or changing working files.

The product is a CLI and supporting libraries. There is no web or graphical
interface to polish. Its UI quality depends on command discoverability,
honest output, actionable refusals, inspectable recovery, and a predictable
progression from local work to collaboration.

## Principle-to-implementation map

| Principle | Implementation and evidence | Assessment |
| --- | --- | --- |
| Model first | [Pure project model](../lib/yeokcham_v1_model/yeokcham_v1_model.ml), [model properties](../test/v1_model_property_test.ml), [formal specification](FORMAL_MODEL.md) | Distinct types and transitions exist; filesystem, clock, transport, and custody effects stay in adapters. The formal document describes executable invariants, not a machine-checked proof. |
| Scratch is separate from intent | [Local service](../lib/yeokcham_v1_local_service/yeokcham_v1_local_service.ml), [watch runner](../bin/v1_watch_runner.ml), [service tests](../test/test_v1_local_service.ml) | `save` is local and unchanged saves are no-ops. `share` is explicit. Automatic capture requires a running watch/daemon; initialization alone does not start it. |
| Exact recovery | [Snapshot scanner and materialiser](../lib/yeokcham_snapshot/yeokcham_snapshot.ml), [restore journal](../lib/yeokcham_v1_restore_journal/yeokcham_v1_restore_journal.ml), [restore proofs](../test/test_v1_restore_proof.ml) | Bytes, symlink targets, executable state, and directories are represented. This is not preservation of every filesystem attribute. Restore preflight gaps found in this review are fixed below. |
| Shared intent includes the exact tree | [Revision construction](../lib/yeokcham_v1_local_service/yeokcham_v1_local_service.ml), [signed records](../lib/yeokcham_v1_trust/yeokcham_v1_trust.ml) | Immutable signed revisions exist. Directory-only differences were omitted when deriving edits; this review fixes that omission. |
| Ambiguity is durable data | [Projection and resolution model](../lib/yeokcham_v1_model/yeokcham_v1_model.ml), [proposal logic](../lib/yeokcham_v1_proposal/yeokcham_v1_proposal.ml), [proposal properties](../test/v1_proposal_property_test.ml) | Overlap/stale bases create decisions. Inspection, exact proposals, and optional LSP observations cannot accept a resolution. |
| Delivery is separate | [Delivery transition](../lib/yeokcham_v1_model/yeokcham_v1_model.ml), [service delivery tests](../test/test_v1_local_service.ml) | Requires decision-free represented shared work and starts a new draft. The current adapter records the observed tree; it does not prove that its bytes equal the composition of the listed revisions. |
| Local authority works offline | [Trust core](../lib/yeokcham_v1_trust/yeokcham_v1_trust.ml), [authority properties](../test/v1_authority_property_test.ml) | Certificate/epoch verification is local. Concurrent heads require explicit selection or reconciliation; relay order supplies no authority. |
| Identity differs from a label or credential | [Custody providers](../lib/yeokcham_v1_custody/yeokcham_v1_custody.ml), [recovery](../lib/yeokcham_v1_recovery/yeokcham_v1_recovery.ml), [custody tests](../test/test_v1_custody.ml) | Device public keys define identity; usernames are display data. Private signing capabilities and relay credentials are outside project history. |
| Receipt never edits source | [Receipt boundary](../lib/yeokcham_v1_receipt/yeokcham_v1_receipt.ml), [package verification](../lib/yeokcham_v1_package/yeokcham_v1_package.ml), [transport properties](../test/v1_transport_property_test.ml) | Separate verified staging and persistent receipt paths exist. Bootstrap activation is separately explicit. Offline join still lacks a comparable source-population path. |
| Relay is only a courier | [Sync orchestration](../lib/yeokcham_v1_sync/yeokcham_v1_sync.ml), [transfer tests](../test/test_v1_transfer.ml), [relay smoke](../test/test_relay_container.sh) | Receipt precedes upload; failed uploads remain retryable. Transfer ranges and object identities are verified. Relay payloads are not end-to-end encrypted. |
| Recovery remains inspectable and retained | [GC](../lib/yeokcham_v1_gc/yeokcham_v1_gc.ml), [GC properties](../test/v1_gc_property_test.ml), [repair](../lib/yeokcham_v1_repair/yeokcham_v1_repair.ml) | Named checkpoints, pins, journals, and proofs protect roots. Quarantine precedes explicit purge. A scan can add unreferenced objects, so inspection is not always zero disk growth. |
| Advisory tools cannot block progress indefinitely | [Hook runner](../lib/yeokcham_v1_hook_runner/yeokcham_v1_hook_runner.ml), [LSP sidecar](../lib/yeokcham_v1_lsp_sidecar/yeokcham_v1_lsp_sidecar.ml) | Hook failures are warnings after success; LSP failure is advisory. Hook timeout enforcement had an unbounded wait and blocking stdin write, fixed below. |
| Honest, usable inspection | [CLI](../bin/yeokcham_v1.ml), [inspection renderer](../lib/yeokcham_v1_inspection/yeokcham_v1_inspection.ml), [CLI journeys](../test/test_v1_cli.ml) | Detailed help, color control, graph/log views, completions, and JSON envelopes exist. History scanning and hidden mnemonic issues are fixed. Most JSON commands still expose completion rather than domain data. |
| Repeatable validation and distribution | [CI](../.github/workflows/ci.yml), [client artifact workflow](../.github/workflows/development-client-artifact.yml), [relay workflow](../.github/workflows/relay-artifact.yml) | Linux/macOS tests, formatting, OCI/RPM smoke, pinned actions, and signed development artifacts exist. Documentation and workflow checks now run directly in ordinary CI. |

## Gaps fixed in this review

### Recovery could erase bytes outside its safety checkpoint

The scanner respects `.yeokchamignore`, while in-place materialisation removed
every ordinary root entry. An ignored file could therefore be deleted without
being present in the safety checkpoint. In-place restore now rejects existing
ignored entries before state, journal, or source mutation, with destination
restore or moving the entry outside the tree as the recovery options. The
same guard covers resumed replacement and workspace activation. It does not
follow symlink ancestors or read excluded contents.

Materialisation also previously checked some content only after starting
output. Missing later content could leave a destination partly populated or
delete live files before failing. Plans now validate every content object and
symlink target before output. Replacement rejects symlink roots and collisions
with preserved metadata. In-place restore validates its target before making
a new journal and checks safety/target closure before resuming.

Regression coverage:
[materialisation preflight](../test/test_snapshot_materialize.ml) and
[local recovery service](../test/test_v1_local_service.ml).

### Directory-only work could be saved but not shared

The exact scanner represented empty directories, but shared-edit derivation
compared only file leaves. Creating or deleting an empty directory resulted in
an empty edit list and failed sharing. Edit derivation now compares the same
exact file/directory entries used by `changes`. Directory additions and
removals receive explicit whole-path edits; unchanged ancestors do not become
edits merely because their child tree IDs changed. A changed ancestor subsumes
its descendants so nested additions, removals, and file/directory replacements
do not create conflicts within one revision.

### JSON mode silently discarded new recovery mnemonics

The generic JSON wrapper redirected text to `/dev/null`. `init --format json`
still created custody and a repository, and `recovery use --format json`
could rotate recovery authority, while their new mnemonic disappeared. Both
ceremonies now refuse JSON before running, with a stable error and directions
to text mode. Tests check that initialization creates neither repository nor
key on refusal and that a text retry displays all 24 words.

### Recovery history unnecessarily depended on a successful live scan

`timeline` called the scanning `status` service. An unsupported live file could
prevent checkpoint discovery, and merely listing history could create scan
objects. Timeline now uses persisted inspection state. The CLI regression
places a named pipe in the worktree and verifies that timeline/log/graph still
work without creating objects or changing history.

Change/decision paths and draft titles now quote whitespace and control bytes
when needed. A filename containing a newline or escape sequence is displayed
as one literal value instead of introducing fake output rows or terminal
styling. Ordinary filenames retain their existing presentation.

### Observer timeout was not a real execution bound

The hook runner sent SIGTERM then waited indefinitely, allowing an observer
that ignores SIGTERM to hang an already-successful operation. It also wrote
the whole event to a pipe before starting its timeout. Event input now uses a
private, immediately unlinked file, and observers run in a separate session
whose process group is killed on timeout or excessive output. The regression
uses an oversized unread event and a TERM-ignoring observer with a delayed
child side effect.

### Onboarding references and release messaging contradicted reality

Seven local documentation references led to missing files. The quick guide's
restore destination did not exist, and source-build setup was omitted. Those
paths are repaired, with concrete product, artifact, and source-verification
guides. Ignore semantics and the precise filesystem fidelity are now stated.

Installation/help claimed no published release existed, although GitHub has a
`1.0.0` release. Inspection found a lightweight tag with no attached assets.
The docs now distinguish that release from current development source and
from the stronger annotated signed-tag verifier. The README's release badge
was not changed.

`make docs-check` verifies local Markdown file destinations, including README
links, without modifying files or using the network. Ordinary CI runs it and
the existing workflow checks in a separate lightweight job.

## Remaining product and engineering decisions

These are visible limitations, not claims that the completed fixes implement
a new collaboration or storage model.

1. **Delivery provenance needs an explicit policy.** Decide whether a delivery
   is a person's assertion about the current tree or a mechanically verified
   composition of shared revisions. The latter needs a canonical projection
   materialiser and validation for whole-path and text-span edits. Silently
   changing that meaning during a maintenance review would alter the model.
2. **Offline collaboration stops at history receipt.** A member can join and
   inspect a package, but cannot activate it through the bootstrap-only
   workspace path. A separately named, verified offline projection basis would
   make the two-person workflow practical without relaxing receipt isolation.
3. **Workspace advancement needs a complete user journey.** The service checks
   the imported basis against the projection baseline, but there is no command
   to select a later imported basis. `workspace update` should not be described
   as generic checkout of whatever `sync` most recently received.
4. **The automation API is incomplete.** Most `--format json` commands return
   only `{"outcome":"completed"}`. Structured status, changes, history,
   generated IDs, and recoverable partial sync outcomes would make scripts
   useful without parsing presentation text. Command help/dispatch/specification
   are maintained separately in a large CLI module, increasing drift risk.
5. **Completion is broad rather than contextual.** Shell scripts enumerate all
   commands/options everywhere; they do not guide users through valid next
   subcommands, value choices, or paths. There is also no compact task-oriented
   overview of the large command surface in the default help.
6. **Capture and storage need an operating policy.** Watch/daemon are opt-in,
   compaction and collection are explicit, and each scan can allocate objects.
   Long-running teams need documented retention settings, capacity guidance,
   and performance measurements on large trees. No new deletion policy was
   inferred from the phrase “bounded retention.”
7. **Exactness has a defined filesystem scope.** Full POSIX modes, directory
   permissions, metadata, and concurrent external writes are not covered by
   current snapshot fidelity. A directory journal makes replacement restartable,
   not atomically visible to unrelated readers. The contract now states these
   limits rather than promising broader recovery guarantees.
8. **Publication and validation are independent workflows.** The relay
   publication can finish before CI integration tests. Treat a signed digest
   as build provenance and check CI for the same commit before deployment.
   Gating publication and establishing stable release compatibility deserve
   a separate release policy.

## Validation

The relevant checks are `make ci`, the focused recovery/CLI/hook regressions,
Linux/macOS GitHub Actions tests, and the client/package/relay smoke workflows.
The handoff records final commit and Actions results separately so this source
document does not make a stale claim about a later commit's workflow state.
