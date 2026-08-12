# Testing and Experiments

## 1. Testing philosophy

yeokcham's strongest portfolio value comes from making its model falsifiable.

Each core claim should map to an invariant, generated test, benchmark, or comparative experiment.

Yeokcham is a local VCS and persistent-data-model project. Testing is limited to repository correctness and checked-in local fixtures; external security analysis is outside scope. Bounds checks, corruption detection, atomic writes, and malformed-input handling remain required storage-system behavior.

## 2. Test layers

### Unit tests

Cover:

- Canonical encoding.
- Object IDs.
- Path validation.
- Snapshot construction.
- File-mode preservation.
- Scratch-event application.
- Retention classification.
- Capsule identity and revision identity.
- Dependency ordering.
- Conflict construction.
- Release identity.
- Git mapping records.

### Property tests

Use QCheck or an equivalent maintained OCaml property-testing library.

Property tests use bounded counts and a printed, reproducible seed. Independent per-property random states must be derived from that base seed so test order cannot alter generated inputs. Codec tests must include deterministically sampled zero, boundary, near-limit, and malformed byte lengths.

Generate:

- Directory trees.
- Byte contents.
- Scratch operation sequences.
- Checkpoint graphs.
- Retention policies.
- Capsule operation sequences.
- Dependency DAGs.
- Conflicting edits.
- Compaction plans.
- Git-style commit sequences for bridge tests.

Core properties:

#### P0 — V2 multiprocess immutable recovery

V2-009 runs a seeded real-process state machine, with a separately derived
per-property random state, over two through four sibling causal children and a
bounded nonce offset. The printed base seed and `forks`/`offset` counterexample
reproduce a failing sequence. Each run concurrently publishes sibling encrypted
ledger events, races two byte-identical prepare writers, and models child exit
immediately after durable prepare and immediately after durable commit.

The parent reopens the repository, verifies it without mutation, then recovers
the journals and verifies it again. Before recovery, the report must retain the
complete explicit causal divergence together with one prepare-only and one
committed transaction; the on-disk image must be byte-identical across the
read-only verification. After recovery, exactly the prepare-only transaction is
discarded, the committed transaction's immutable event is published, no journal
state remains, and the causal heads remain an explicit divergence rather than a
selected winner. Root validation and enumeration may ignore only the V2
adapter's exact regular private staging-file grammar, including a temporary
that disappears between enumeration and inspection; all canonical object names
and other paths remain fail-closed.

#### P1 — Snapshot round trip

Serialise, store, load, and materialise a snapshot; resulting filesystem model is identical.

#### P2 — Scratch replay

Applying scratch events from a retained boundary yields the expected checkpoint snapshot.

#### P3 — Restore exactness

Restoring a checkpoint reproduces exact bytes and supported metadata.

Milestone 2 additionally checks immutable event/checkpoint replay, CAS head
publication, pin identity preservation, deterministic bounded ancestry
traversal, reopen recovery, failed-publication head preservation, disposable
index recovery, unsupported-record rejection, polling debounce/no-duplicate
behaviour, and restore-plan external-mutation rejection. A failed
populated-directory restore is tested for an available safety checkpoint and no
target-head advancement; it is not represented as crash-atomic unless an
operation journal is implemented.

Milestone 3 additionally checks deterministic recent-window and periodic
selection, pin precedence, permutation-independent selection, retained logical
snapshot equivalence after activated generation compaction, direct generation
schema decoding/goldens, replay verification, post-compaction checkpointing and
retention changes, repeated generation activation, resolver corruption
rejection, and idempotent cleanup resume. Deterministic fixtures compare the
dry-run canonical cleanup IDs, expected types, object count, and exact stored
file lengths with quarantine and prune results. Candidate-boundary faults run
before and after every quarantine and prune movement, reopen the repository,
resume, and verify retained logical restoration, active-generation stability,
and idempotence. Missing, wrong-path/type, foreign-generation quarantine,
stale-generation, and corrupt-manifest states reject structurally. The current
cleanup scope excludes shared content-domain objects pending full cross-domain
reachability.

#### P4 — Compaction preservation

Before and after compaction, every retained checkpoint resolves to the same snapshot.

#### P5 — Compaction idempotence

Running compaction again without new data does not change repository meaning.

#### P6 — Capsule revision immutability

A revision ID never resolves to different content.

Milestone 4 checks exact transition replay over bounded generated scratch
states, explicit text-fallback conflicts, ancestry-validated checkpoint-range
derivation, persistent Capsule/Capsule_revision/current-ref canonical goldens
and inverse decoders, reopen resolution, idempotent retry, current-ref CAS,
failure before/after visibility, pinned boundaries, parent/type/corruption
rejection, split/combine replay, and a seeded create/fold/show/split/combine
restart state machine. The forced seed is reported by the property executable.
Current-working-diff creation additionally checks exact double-scan creation,
no-change non-publication, deterministic external mutation rejection before
checkpoint publication, pre-current-ref interruption with a safely retained
checkpoint, idempotent retry, and boundary retention after reopen.
Single-capsule editing additionally checks revision-result materialisation,
safety checkpointing of divergent work, bytes/mode/symlink exactness, anchor
reuse when the result is already current, stale apply rejection without target
head publication, and folding from the returned anchor into a new immutable
revision.
Split/combine tests additionally prove that plans are read-only and expose
selected/source order, output bases/results, composition, provenance, and pins;
unconfirmed calls reject; confirmed calls retain exact replay and sources; and
the seeded restart state machine includes current creation, edit, fold, and
confirmed split/combine. Parent-cycle coverage uses the pure logical resolver
with a synthetic cycle. Persistent tests separately retain wrong-ID, corrupt,
missing-parent, wrong-type, and cross-capsule-parent rejection; no impossible
hash-verifying cyclic object fixture is claimed.

V2-018 separately checks deterministic byte-only structural proposals, explicit
dependent-subset conflicts, empty-directory replay, immutable Capsule and
Capsule_revision frame goldens, encrypted reopen, pre-binding interruption,
and source-boundary resolution after scratch compaction. Its seeded generated
coverage varies exact file bytes and executable modes in both pure and durable
paths; it makes no semantic or intent-inference claim.

#### P7 — Stable capsule identity

Creating a new revision does not change capsule ID.

#### P8 — Composition determinism

Identical workspace inputs produce identical result and conflict set.

#### P15 — Immutable exchange preservation

ADR-038 tests retain exact frame goldens for every message kind and reject bad
lengths, noncanonical CBOR, unknown required features, ordering, page/session,
sequence, membership, budget, Envelope, identity, and collision states before
mutable state changes. Two local repositories cover empty/equal/divergent
object sets, repeated transfer, interruption/restart, idempotent publication,
and unchanged refs. The seeded property test varies object sets, duplicate
input, and interruption positions; retry must make every declared source object
available while preserving the destination ref exactly. These tests exercise an
in-process transport-neutral adapter, not networking.

#### P16 — Verifiable ref-event preservation

ADR-039 retains an exact Ref_event v1 fixture and verifies an independent
Ed25519 signature only through a caller-provided key map. Focused two-local
repository tests cover verified/untrusted/wrong-repository, malformed or bad
signature, replay, missing predecessor, divergence, store/reload, and unchanged
mutable refs. The seeded chain property varies signed event lengths and
corruption/replay positions; verification and restart decoding retain exact
event bytes and never advance a ref.

#### P17 — Local device identity preservation

ADR-040 retains an exact public Device_identity v1 Envelope fixture and rejects
malformed records, unsupported algorithms, mismatched object IDs, oversized
registries, absent mappings, and ambiguous signer rows structurally. Two local
repositories transfer/reopen one declaration, resolve only an independently
verified event through an explicit registry, and preserve the destination ref.
The seeded restart property varies bounded public declarations, repeated
create-only publication, reload, registry resolution, and corrupt payloads; no
test treats a public declaration as trust or persists private key bytes.

#### P18 — Bounded local HTTP exchange preservation

M10-04 drives exact ADR-038 frames through bounded HTTP request/response
parsing. Focused tests cover malformed HTTP, destination-side Want selection,
loopback TCP transfer, explicit interruption/restart, store reload, and an
unchanged destination ref. The seeded state machine varies bounded object sets,
interruption points, restart/reoffer, idempotent immutable publication, and
corrupt HTTP input. No test asserts peer identity, transport authentication, or
ref reconciliation.

#### P19 — Durable divergent ref-head preservation

ADR-041 retains exact type-28 set-envelope and checksummed binding goldens with
inverse decode coverage. Focused storage tests cover two-device candidate
union, duplicate delivery, reopen, stale observed state, untrusted event,
missing link, wrong object type, corrupt binding, stored-context mismatch, and
unchanged application refs. The seeded state machine varies candidate delivery
order, duplicates, restart points, union, and corrupt binding decoding; it
checks the retained candidate cardinality and never treats a candidate as an
applied ref, selected head, or reconciliation result.

#### P20 — Encrypted offline bundle preservation

ADR-042 retains exact canonical plaintext, authenticated-header, and fixed
ciphertext fixtures, plus the RFC 8439 ChaCha20-Poly1305 AEAD vector. Focused
two-local-repository tests cover empty, equal/retried, and divergent explicit
object sets; reopen; repeated create-only import; fresh exporter output; and
unchanged application-ref and divergence-binding bytes. Wrong keys, altered
authenticated nonce/ciphertext/tag, wrong repository, malformed or
noncanonical bytes, unsupported outer fields, duplicate entries, and bounds
reject structurally before publication. The seeded property varies bounded
object sets, reversed/duplicate exporter input, corrupted delivery, and restart;
it checks that rejected deliveries publish no source object and that successful
retries preserve the destination ref.

#### P21 — Two-device synchronisation preservation

M10-07 composes the existing local exchange, public-device, signed-ref-event,
and divergence adapters without a central service. Focused two-repository
fixtures transfer initially missing device identities, target objects, and
signed competing events in both directions; resolve the remote event through a
caller-held registry; retain one matching two-entry divergence set on each
device; and preserve both application refs. Separate focused coverage injects
an interrupted transfer, reopens and reoffers objects, then corrupts a source
object and proves that it is not published. The seeded property varies bounded
missing-object sets, interruption points, duplicate input, and corruption;
retries must make valid objects available while every destination ref stays
unchanged.

#### P22 — Shared-directory encrypted bundle preservation

ADR-043 retains v1 partial/final filename ordering as a fixture and reuses the
ADR-042 exact encrypted-bundle fixtures. Focused local source/destination/shared
directory tests cover export/list/inspect/import/reopen retry, retained partial
visibility with explicit non-importability, corrupt final bytes, unexpected
entries, symlinks, exact object bytes, and unchanged destination refs/bindings.
The seeded property varies bounded object sets, duplicate export input, corrupt
final delivery, and import retry/reopen; rejected files publish no source object
and valid retries preserve the destination ref. The tests do not claim repair of
an interrupted export stream or filesystem permission enforcement.

#### P23 — Missing-object exchange preservation

M10-09 retains a deterministic two-repository fixture with one byte-identical
already-present object and one missing object. It checks exact object identity,
one missing-only request/transfer, inode-stable already-present bytes, reopen
retry with zero requests/transfers, corruption rejection before destination
publication, and unchanged refs. The existing seeded ADR-038 exchange property
varies bounded missing object sets, duplicate input, interruption, and retry.

Milestone 5 additionally checks Workspace/Workspace_revision/Workspace_attempt,
Conflict, Resolution, and workspace-current-ref canonical goldens with inverse
decoders; workspace reopen; immutable enable/reorder revisions; stale workspace
CAS; local conflict persistence/list/show; independent-operation continuation;
guarded materialisation bytes/modes/symlink targets and safety checkpoints;
externally mutated plan rejection; scratch/workspace ref preservation on
guarded-apply failure; immutable skip-operation resolution/rematerialisation;
and a bounded restart state machine for create, enable, disable, reorder,
materialise, conflict, resolve, and rematerialise. Properties remain bounded
and seeded; release dependencies still return the explicit unsupported resolver
error.

V2-021 separately checks canonical Validation_evidence and Release bytes with
inverse decoders and typed-frame goldens; generated evidence round trips;
release identity independence from observation timestamps and physical evidence
references; exact complete-attempt replay after reopen; failed, mismatched, or
missing evidence rejection; conflict-bearing attempt rejection; idempotent
retry; parent physical-link rejection; interruption before binding; and typed
storage counts. This client-neutral slice does not claim a process runner,
review approval, signing workflow, CLI behaviour, or a benchmark.

V2-022 checks a pure complete typed-physical mark, permutation-independent
opaque-reference eviction, retained-set budget overrun, canonical
`cache-reclamation-v1` fixture decoding, and the invariant that no marked
reference is selected. Durable tests retain active scratch and pin roots,
reject changed root state before movement, inject interruption after a
quarantine move, reopen/retry the same manifest, and separate successful
quarantine from explicit prune. Existing scratch, capsule, workspace, and
release store suites re-exercise their complete publication intervals under the
same shared guard. This slice adds no throughput benchmark, automatic cleanup,
or CLI claim.

V2-025's Linux custody boundary retains routine injected-runner tests and a
seeded capability/bootstrap property that do not touch a desktop keyring. The
separate opt-in `YEOKCHAM_RUN_SECRET_SERVICE_INTEGRATION=1 make
secret-service-integration` check uses the production `busctl` and
`secret-tool` runner against an unlocked local service. It creates a random
handle, verifies enrollment and reopening, confirms the public bootstrap does
not contain any private role bytes, clears only the item initialized by that
run, and verifies the resulting missing state. It is deliberately excluded from
normal tests and CI because it mutates the caller's Secret Service collection.
On 2026-08-13, it passed against the local default `kdewallet` collection.
[Inference] The initial timeout arose because the child inherited the stdin
pipe's writer; after closing that descriptor on `exec`, the native
enrol/reopen/clear/missing sequence completed successfully.

V2-024 provides an injected macOS Keychain custody core, a canonical public
Keychain-account vector, and a seeded re-open property without modifying the
host Keychain. Focused tests verify repository-byte exclusion, explicit
locked/unavailable/non-exportable refusal, create-only handle collision,
malformed/mismatched value rejection, and local removal that leaves the signed
bootstrap unchanged. The separate opt-in
`YEOKCHAM_RUN_KEYCHAIN_INTEGRATION=1 make keychain-integration` target is
macOS-only: it creates a random Data Protection Keychain generic-password item
through Security.framework, reopens it, deletes only that item, and verifies
missing state. It cannot be run on this Linux host and remains required native
evidence before #146 can close, alongside #122's hosted-success gate.

V2-026 adds the browser-vault package's deterministic fake-WebAuthn suite and
a seeded 120-case restart property. It fixes a public associated-data vector,
proves that the durable record contains no plaintext capability or stored key,
and rejects changed origin/RP ID/credential data, missing user verification,
PRF or WebAuthn unavailability, corrupt AES-GCM ciphertext, storage failure,
and create-only collisions. `make check` and the seeded property command run
that Node suite. [Unverified] The package has no real-browser or hardware
passkey result yet: its fakes verify the boundary's requested options and its
assertion checks, not browser/user-agent WebAuthn interoperability. A future
Svelte/browser harness must execute the opt-in native flow before #148 can
close, alongside #122's hosted-success gate.

V2-023 separately checks fixed canonical public repository-authority,
device-certificate, and device-revocation records, their strict inverse
decoders, and distinct typed encrypted-object frames. Focused cases reject
tampered identities, unsupported mandatory features, cross-root certificate
use, root/device signer reuse, duplicate device bindings, and malformed frame
payload before publication. The durable case publishes all three records into
the existing create-only encrypted object store, reopens them, verifies the
certificate and revocation against the recovered authority anchor, and proves
an exact retry is idempotent. The seeded property varies repository and device
identities and requires canonical authority/certificate round trips. This
slice does not claim authority-ledger ordering, bootstrap binding, recovery,
remote encryption-key non-reuse, a CLI command, or a benchmark.

Milestone 6 validation checks canonical command/evidence goldens and inverse
decoders; exact-snapshot materialisation; passing, failed, signalled, timeout,
and execution-error observations; bounded stdout/stderr retention and hashes;
reopen; malformed command rejection; and the invariant that validation cannot
move scratch, workspace, or release refs. Runner tests inject deterministic
process outcomes and use direct local argv fixtures for the Unix timeout path.
M6-D01 additionally checks the pure passed-exact-snapshot selector, idempotent
stored-evidence retention after reopen, no retention for failed evidence, and
compaction planning/activation of a validation-retained checkpoint. The seeded
property varies matching checkpoint candidates and requires each selected ID to
occur exactly once.

Milestone 6 release checks canonical Release/binding goldens and inverse
decoders; create/reopen/show/list/verify; exact workspace-attempt replay;
evidence/final-snapshot binding; failed-validation and unresolved-conflict
publication rejection; interrupted pre-binding invisibility; retry idempotency;
later immutable capsule/workspace revisions; corruption/type/context rejection;
and parent closure/cycle traversal through a pure resolver seam. Release
verification reads no rebuildable index.

Milestone 6 also checks the Release_attestation v1 golden and inverse decoder,
reopen storage, and the explicit non-cryptographic deterministic test signer.
The bounded seeded release/validation state machine executes validation,
parent/child release creation, reopen, verification, and parent closure with
`PROPERTY_TEST_SEED=17`. `Requires_release.satisfied` accepts only an exact
base or verified parent closure and rejects an absent ID; its integration into
durable workspace ordering remains blocked by ADR-026's missing base-release
field.

Milestone 8 Git-import checks materialise imported snapshots with exact regular
file bytes, executable mode, symlink target, and nested-tree structure. They
mutate the source Git working tree after import, reopen Yeokcham storage, and
prove materialisation still matches the imported tree; corrupt mappings or
objects reject explicitly.

M8-16 additionally imports one complete supported local Git repository into a
fresh Yeokcham store: its merge commit, ordered parents, tree, regular/executable
and symlink blobs, lightweight and annotated tags, opaque author/committer and
annotation provenance, and every bridge mapping. The fixture reopens all
durable evidence, mutates the source Git worktree, then materialises the stored
import into a separate destination to prove the byte/mode/symlink oracle does
not depend on live Git files. Unsupported interchange is documented in
`docs/GIT_INTERCHANGE.md`.

M8-08 Git-export checks a verified release's Git checkout for exact regular
bytes, executable mode, symlink target, and nested-tree structure; it runs
`git fsck --full`, reopens the mapping, and proves deterministic retry.
Generated bounded releases check checkout bytes/mode. Fixtures reject nested
empty directories and inject pre-ref/pre-mapping interruptions, which leave an
explicit retry path without a changed Yeokcham release.

M8-10 Git-export checks optional configured author, committer, timestamp, and
message output exactly; verifies default/configured and distinct configured
commits do not collide; checks metadata-qualified ref and mapping retry,
checkout, restart, and `git fsck --full`; and rejects invalid identities,
over-limit metadata, interrupted publication, and changed-ref collision before
any silent overwrite. The seeded generated property varies bounded valid
metadata and proves exact headers/message, exact checkout, and stable retry.

M8-09 Git-export checks explicit revision links by replaying each source,
checking exact result/base chaining, root/sole-parent linearity, exact regular
bytes, executable mode, symlink target, empty-root handling, nested-empty
rejection, mapping source verification, `git fsck --full`, deterministic retry,
ref collision, bounded selection, and pre-ref/between-mapping interruption.
The bounded generated test checks two generated snapshots for exact checkout,
sole-parent order, stable mappings/ref, retry, and `fsck`.

M8-18 uses one shared final-state oracle for supported Git import, release
export (including configured metadata), and linear revision export. It compares
entry sets, regular bytes, executable bit, symlink target bytes, and nested
tree structure against the immutable Yeokcham snapshot; only a Git checkout's
`.git` directory is excluded. Failure labels name the divergent path and the
relevant kind, bytes, mode, or symlink metadata. This is not a semantic
equivalence claim.

#### P9 — Dependency safety

No materialisation silently omits an unsatisfied required dependency.

#### P10 — Conflict persistence

Unresolved conflicts survive restart and remain associated with the same application context.

#### P11 — Release reproducibility

Rebuilding a release yields the recorded final snapshot ID.

#### P12 — Git export bytes

Exported Git branch checkout matches the yeokcham release snapshot.

### State-machine tests

Model command sequences:

- Init.
- Edit.
- Checkpoint.
- Restore.
- Pin.
- Compact.
- Create capsule.
- Revise capsule.
- Enable and disable.
- Resolve conflict.
- Create release.

Compare implementation state with a simple in-memory reference model.

### Failure-injection tests

Inject failure during:

- Object write.
- Checkpoint ref update.
- Compaction generation publication.
- Workspace materialisation.
- Capsule revision creation.
- Release creation.
- Git export.
- Index update.

Expected result:

- Old valid state.
- New valid state.
- Detectable recoverable staging state.

Generation failure states are: pre-activation immutable-object leftovers with
the prior ref unchanged; post-activation/pre-cleanup valid logical resolution
with excess objects; and partially quarantined manifest candidates resumed
idempotently. Candidate-level injection occurs before candidate zero, before
every later candidate, and after every candidate including the final movement
before normal completion. Permanent prune is tested separately from recoverable
quarantine; a prune retry accepts an absent candidate only when the active
generation's verified manifest names it.

## 3. Filesystem fixtures

Include:

- Empty files.
- Large files.
- Unicode names.
- Deep paths.
- Wide directories.
- Executable files.
- Symlinks.
- Rename chains.
- Delete and recreate.
- Invalid source files.
- Already-compressed binaries.
- Mixed line endings.
- Non-UTF-8 bytes where platform support permits.
- Files immediately below, at, and above the inline/manifest cutoff.
- Multi-chunk files, local large-file edits, and insertions near the beginning.
- Corrupt/missing/reordered chunks and manifests.
- Unsupported FIFOs, sockets, and device nodes where portable; each must return a structured path/category error without publishing a partial snapshot.

## 4. Scratch-history experiments

### E1 — Retention policy matrix

Generate or record realistic editing traces.

Compare:

- Keep every checkpoint.
- Time-window retention.
- Exponential thinning.
- Test-boundary pinning.
- Capsule-boundary pinning.
- Storage-budget retention.

Budget selection tests must retain pinned and current logical-head checkpoints,
be invariant under timeline input order, label nonfitting optional candidates,
and preserve every selected snapshot after activation/reopen. A protected-only
overrun is a structured plan result, not a correctness or timing failure.

Inverse-pair coverage composes an unretained scratch gap, checks exact
structural-pair reduction and unmatched-operation preservation, and verifies
that both the original/reduced chains and post-activation retained restores
reach the identical snapshots. Generated pairs may become adjacent only after
an earlier exact elimination; every other operation remains intact.

Measure:

- Storage.
- Restore latency.
- Event replay length.
- Retained meaningful states.

M3-D03 records the implemented subset in
`docs/experiments/results/scratch-retention-benchmark-v1.json`: keep-all,
recent-window, periodic, and storage-budget policy runs over a deterministic
25-checkpoint trace with a pinned restore target. The schema requires fixture
checksum, environment, repetitions, active-object-store bytes after temporary
benchmark prune, generated physical event-chain depth, and every guarded
restore timing sample. This is host-specific evidence, not a threshold or a
claim about unsupported exponential/test/capsule-boundary policies.

### E2 — Compaction strategies

Compare:

- Reachability-only GC.
- Direct retained-snapshot preservation.
- Periodic snapshots plus deltas.
- Inverse-event elimination.
- Chunk-level deduplication.

Verify every retained state before comparing performance.

## 5. Capsule experiments

### E3 — Messy-to-curated workflow

Fixture:

- Implement feature.
- Add debug logging.
- Reformat unrelated file.
- Fix typo.
- Revert debug logging.
- Add tests.

Evaluate whether the user can create:

- One feature capsule.
- One optional formatting capsule.
- No permanent debug-log history unless retained intentionally.

### E4 — Capsule revision

Revise the same feature several times.

Verify:

- Stable capsule ID.
- Immutable revisions.
- Clear difference between implementation evolution and release history.

## 6. Composition experiments

### E5 — Parallel workstreams

Enable:

- Auth refactor.
- Logging fix.
- Parser experiment.

Test:

- Independent enable/disable.
- Shared-file overlap.
- Dependency declaration.
- Order explanation.
- Conflict localisation.

Compare conceptually with branch switching and virtual branches.

## 7. Semantic replay experiments

### Dataset categories

- Identifier rename.
- Function move.
- File move.
- Surrounding formatting.
- Added nearby duplicate.
- Base refactor.
- Signature change.
- Split function.
- Macro or generated code.
- Parse error.

### Baselines

- Exact precondition only.
- Text context patch.
- Token-based matching.
- Semantic-anchor matching.

### Outcomes

- Correct exact application: selected target and resulting bytes equal the
  fixture oracle with Exact semantic confidence or the textual exact-span stage.
- Correct non-exact application: target and bytes equal the oracle through a
  lower-confidence semantic stage or a contextual textual stage.
- Safe conflict: refusal where the oracle permits or requires refusal, with no
  byte modification. It is not counted as an application.
- False-confident application: Exact/High semantic application with a wrong
  target, wrong bytes, outside-span bytes, or an oracle-required conflict.
- False negative: missing, ambiguity, or rejection where the oracle has one
  uniquely applicable target.
- Validation pass or failure, including exact byte-splice invariance.

The report must highlight false-confident applications prominently. The checked
v1 schema and report are
`docs/experiments/schema/semantic-retargeting-v1.schema.json` and
`docs/experiments/results/semantic-retargeting-v1.json`; use `make
semantic-experiment` to regenerate and validate them. Its elapsed timings are
host-specific evidence, not a gate.

## 8. Performance benchmarks

Record:

- yeokcham commit.
- OCaml version.
- Compiler mode.
- OS and hardware.
- Filesystem.
- Fixture checksum.
- Cache state.
- Repetitions.
- Median and tail.
- Peak RSS.
- Bytes stored.
- Objects written.
- Replay depth.

Benchmarks:

- Initial scan.
- Incremental scan.
- Checkpoint creation.
- Restore.
- Timeline query.
- Compaction.
- Capsule application.
- Workspace rematerialisation.
- Semantic retargeting.
- Release creation.
- Git import/export.
- Large-content representation: encoded bytes, object count, reused bytes across versions, encoding, materialisation, and approximate allocation for deterministic content fixtures. These results choose a format but never act as CI timing thresholds.

## 9. Comparative demonstrations

For a small reproducible repository, document the equivalent workflow in:

- Git.
- Jujutsu.
- yeokcham.

Where practical, also show:

- Pijul.
- GitButler.
- Stacked Git changes.

The comparison should acknowledge features those tools already provide.

## 9.1 TypeScript sidecar protocol experiment

The optional Compiler API helper is pinned to TypeScript `5.9.3` in
`tools/yeokcham-typescript-adapter/package-lock.json`; its minimum Node version
is `14.17.0`. Setup is one explicit local
`npm ci --ignore-scripts --no-audit --no-fund`; tests do not download packages
or use a global TypeScript installation.

The deterministic protocol suite covers handshake/version pinning, virtual
TypeScript and TSX input, UTF-8 byte spans with BOM/Unicode/emoji/CRLF, aliases
and re-exports, parser damage, unresolved imports, bounded path mapping,
unsafe input, output bounds, and a byte-splice replacement with stale-preimage
and post-parse conflict cases. The OCaml suite separately covers the verified
snapshot virtual-file boundary and unavailable outcomes for a missing helper,
timeout, malformed response, crash, and oversized output.

These are correctness checks, not performance gates. The result remains limited
to exact-span replacement, the bounded declaration matcher, and a
nonpersistent evidence selector. The deterministic shared fixture dataset has
40 cases and drives both the byte-only contextual baseline and semantic
selector. The checked-in versioned comparative report is schema-validated by
`make semantic-experiment` and statically revalidated by `make check`.
`docs/experiments/semantic-sidecar-v1.md` records the measured scope and must
not be read as a general reliability claim.

## 9.2 Rust syntax-sidecar protocol experiment

ADR-035's optional helper is pinned through
`tools/yeokcham-rust-adapter/Cargo.lock` with direct dependencies
`tree-sitter 0.26.11` and `tree-sitter-rust 0.24.2`. Build it explicitly with
`cargo build --locked --release`; adapter analysis never invokes Cargo. The
checked-in protocol-v1 request/response goldens are exercised by `cargo test
--locked`.

Focused OCaml coverage verifies handshake pins, top-level item kinds, UTF-8
byte spans, parser damage, verified-snapshot-only virtual input, unsafe and
non-UTF-8 input, request/output bounds, missing helper, timeout, crash,
malformed response, and textual fallback after an unavailable result. A seeded
generated test varies safe sorted virtual maps and checks parser completeness,
item count, canonical item kind, and bounded spans. `make test` and `make
property-test` build the helper before their relevant coverage. These checks do
not establish semantic equivalence, module resolution, macro expansion, or
rewrite correctness; any timing record is host-specific evidence only.

M9-04 adds `yeokcham_rust_fixtures`, a deterministic version-1 dataset of six
bounded virtual Rust source-map workloads: rename after insertion, within-file
move, cross-module move, duplicate ambiguity, macro-heavy fallback, and parser
damage fallback. Every supported case has an exact `yeokcham_textual_patch` byte
oracle; ambiguity remains a structured conflict. Fallback cases verify the
same independent textual oracle while the Rust adapter reports no semantic
authority. Fixture maps, paths, spans, fallback kinds, and module observations
are checked by focused tests; a seeded property varies bounded prefix shifts.
This is input for a later language comparison, not a Rust rename/move engine or
a cross-language result.

M9-05 publishes that later comparison as the separate
`rust-typescript-retargeting-comparison-v1` report and schema. It preserves the
40-case TypeScript v1 result by reference, reports the six-case Rust textual
and fallback workload separately, and records false-confidence/false-negative
fields without pooling values or comparing rates. Rust semantic retargeting
attempts are explicitly zero; a zero false-confident Rust count is therefore
not a safety claim. `make rust-retargeting-comparison` regenerates and validates
the documentation artifact; `make check` statically validates it.

M9-06 records the complete Rust support/failure boundary in
`docs/experiments/rust-semantic-sidecar-limitations-v1.md`. It names the
syntax-only scope, unsupported macros/attributes/configuration, fallback-only
behaviour, structured unavailable/incomplete outcomes, fixture limits, and the
non-comparable TypeScript boundary without changing TypeScript evidence or
claiming Rust semantic retargeting.

## 10. Release gates

### Model prototype gate

- Snapshot and restore property tests pass.
- Compaction preserves retained states.
- Process interruption during compaction preserves a valid generation.
- Storage statistics distinguish history classes.

### Local alpha gate

- Capsules and revisions work.
- Workspace composition is deterministic.
- Conflicts persist.
- Release reproduction works.
- CLI can explain states.

### Research beta gate

- TypeScript semantic adapter evaluated.
- False-confidence rate reported.
- Git import/export demonstrated.
- Comparative workflow report published.
- Repository format documented.

M11-10 indexes versioned benchmark/experiment inputs, host/fixture metadata,
negative outcomes, and demonstration limits in
`docs/RESEARCH_AND_BENCHMARK_REPORT.md`. The index does not pool workloads or
turn timing into a correctness gate.

## 11. Suggested tooling

- Dune.
- Alcotest.
- QCheck.
- Bounded deterministic generated-input properties for pure codecs.
- SQLite bindings for indexes.
- Process-level benchmark scripts.
- `hyperfine` where appropriate.
- Golden fixtures for CLI and encodings.
- Git plumbing commands for bridge verification.
