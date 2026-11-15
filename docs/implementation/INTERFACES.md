# Core-workflow interfaces (P1/P2, P3 in progress)

P1 supplies the pure canonical model/record/trust interfaces. P2 connects them
to durable local branches, workspace/history identities, capture, inspection and
verified local selection/recovery. Read actual signatures in
[model Core](../../lib/yeokcham_v1_model/core.mli),
[record Core](../../lib/yeokcham_v1_record/core_record.mli),
[trust Core](../../lib/yeokcham_v1_trust/yeokcham_v1_trust.mli) and the local
adapters below. P1 left V1 CLI/wrappers unchanged; P2 extends the existing local
state root while preserving public package/transport formats. P3 composition/accepted-result verification is now in progress below; clone,
exchange and complete conflict/recovery journeys remain in progress. Local
integration execution and its CLI are described below. See the
[P2 report](reports/P02-attempt-01.md). TC01/TC02/TC06 remain the authority in
[Technical contracts](../TECHNICAL_CONTRACTS.md).

## Registry and canonical bytes

`Yeokcham_envelope.object_type_code` is the sole object-type registry. P1 uses:

| Body kind (UTF-8 text) | Envelope constructor / code | Ed25519 domain |
| --- | --- | --- |
| `shared-revision` | `Core_shared_revision` / 41 | `yeokcham/record/shared-revision/v1` |
| `accepted-version` | `Core_accepted_version` / 42 | `yeokcham/record/accepted-version/v1` |
| `branch-event` | `Core_branch_event` / 43 | `yeokcham/record/branch-event/v1` |

No second type-code table is used by production consumers. Existing object
codes 1-40 retain their meanings. Existing GC conservatively retains these new
object types; P1 adds no deletion policy or root traversal for future workflows.

The body is the canonical CBOR array
`[kind, 1, repository, parents, author_certificate, authority_heads, payload, display_time]`.
Repository, certificate, authority, object and record references are exactly
32 raw bytes. Workspace/branch/change IDs are exactly 16 raw bytes. Names and
the composition profile use CBOR text. Absent time/name values are explicit
nulls. Display time is a nonnegative int64, never an authority ordering input.

The payload is a consecutive integer-keyed map, starting at zero:

| Kind | Fields in key order |
| --- | --- |
| Shared revision | change, previous revisions, base snapshot, result snapshot, edit-scope root, dependencies |
| Accepted version | branch, accepted parents, chosen revisions, resolutions, result snapshot, composition profile, policy heads, review evidence |
| Branch event | branch, previous events, action, targets, display name |

Branch action integers are create=0, rename=1, advance=2, reconcile=3.
The top-level parents must equal the payload's previous-revision, accepted-parent
or previous-event set, respectively. Every identifier set is strictly increasing
by raw bytes, without duplicates. Constructors sort sets and reject duplicates;
decoders reject unsorted input instead of silently repairing signed bytes.

The signed envelope payload is `[body, signature]`, embedding the body array
directly. The signature is exactly 64 bytes. The signed message is the domain
above immediately followed by the canonical body, without a separator or NUL.
`signing_input` exposes those exact combined bytes; `Trust.sign_detached` takes
domain and body separately. The record ID is SHA-256 of the **complete** canonical
envelope, including the signature and existing envelope checksum/header.
Compression, a local counter and a user-supplied label do not define this ID.

`Record.Core` supplies:

```ocaml
encode_body : Model.Core.body -> (string, error) result
decode_body : repository:Model.Core.Repository_id.t -> string -> (Model.Core.body, error) result
signing_input : Model.Core.body -> (string, error) result
attach_signature : Model.Core.body -> signature:string -> (signed, error) result
body : signed -> Model.Core.body
signature : signed -> string
encode : signed -> (string, error) result
decode : repository:Model.Core.Repository_id.t -> string -> (signed, error) result
id : signed -> (Model.Core.Record_id.t, error) result
```

Here `Model` means `Yeokcham_v1_model`, `Record` means `Yeokcham_v1_record`, and
`Trust` means `Yeokcham_v1_trust`. `signed` is syntactic, not a verified capability.
`attach_signature` checks length, not authenticity. Use the trust API for outside
bytes. Unknown kinds, tuple/map shapes, versions, mandatory envelope features,
wrong scope/types, malformed references and noncanonical CBOR fail explicitly.

Each body/envelope input is capped at 8 MiB before parsing/checksumming. Parser
depth is 8 and its item budget is `8 * Model.Core.max_references + 128` (131,200).
Each reference set is capped at 16,384 entries; branch names at 1,024 UTF-8 bytes,
nonempty and without NUL. The only supported composition profile is
`line-hunks-v1`. This declares a profile; P1 does not implement its composition.
Limits bound individual control records, not file contents or repository history.
Future unbounded collections require paged records, not a larger unbounded parser.

## Identities and local allocation ownership

`Model.Core.Workspace_id`, `Branch_id`, `Change_id`, and `Operation_id` are distinct abstract
types implementing `Random_id`. Each exposes `of_raw`, `to_raw`, `of_hex`,
`to_hex`, `equal`, `compare`, and:

```ocaml
generate : random_bytes:(int -> (string, string) result) -> unit -> (t, error) result
```

The adapter supplies an OS CSPRNG; exactly 16 bytes are requested. Short/error/
exceptional entropy is rejected. Hex parsing accepts exactly the lowercase
representation. `Repository_id`, `Record_id`, `Object_id`, `Digest`, and `Plan_id` use
the same strict conversion/comparison interface with 32-byte values, without
a random-generation function. A raw ID alone does not prove a referenced object.

`History_id.make ~workspace ~sequence` rejects negative sequence values.
`History_id.allocate ~workspace ~next` returns `(history_id, next_counter)`;
`next : int64 option` uses `None` for exhaustion. Allocating `Int64.max_int`
returns it once and then `None`. `Record.Core.encode_history_id` and
`decode_history_id` use the canonical CBOR pair `[workspace_bytes, sequence]`.
The same snapshot can occur at multiple distinct positions.

**Durability belongs to the local store/journal adapter.** It must retain the
workspace namespace, acquire the repository writer lock, reserve the sequence,
append the node and publish the returned counter/cursor under one atomic
metadata-root update. Failed/retried writes must reuse the committed operation
or leave the reservation unpublished. P1's pure `allocate` function does not
perform that transaction. P2's implemented durable-history checkpoint below
binds existing short integer positions to a persisted workspace namespace. A copied workspace needs a new namespace; its first node can name the
source workspace's node as explicit ancestry.

## Model records, retention and trust

`make_shared_revision`, `make_accepted_version`, `make_branch_event` and
`make_context` take the named fields in the payload/body tables above and return
validated private records. `make_body ~context ~payload` joins those values.
The model and codec share these types; there is no duplicate record model.

```ocaml
empty_pool : repository:Repository_id.t -> pool
pool_repository : pool -> Repository_id.t
records : pool -> (Record_id.t * body) list
find : pool -> Record_id.t -> body option
retain : pool -> id:Record_id.t -> body -> (pool * insertion, error) result
```

`insertion = Added | Unchanged`. Scope, known reference kinds, previous revision
change identity and previous branch-event identity are checked. An identical
ID/body repeat is unchanged; a conflicting body under that ID is rejected.
Independently creating an existing change/branch ID is a collision. Causal
successors explicitly name their preceding records. Missing references refuse
retention; a future receipt adapter can stage/reorder them without inventing
missing history. The pool preserves all retained records, independent of arrival
order, without reducing branch heads or selecting an accepted version.

New retention of policy/review/resolution-bearing acceptances is unsupported and
returns `Unsupported_policy`. Their typed references remain representable for
future implementers; absence of an evaluator cannot mean approval. Snapshot
closure, declared-scope proof, genesis-empty-tree proof, actual composition,
branch-head reduction and durable publication remain downstream responsibilities.
Do not treat `retain` as sufficient authorization to mutate project state.

```ocaml
Trust.Core.sign : Trust.authority -> Trust.signing_capability -> body -> (Record.Core.signed, error) result
Trust.Core.verify : Trust.authority -> Record.Core.signed -> (unit, error) result
Trust.Core.receive : Trust.authority -> pool -> string -> (pool * insertion, error) result
```

Signing binds the existing verified repository, author certificate and explicit
current authority heads. The author must be active at every named head; heads
must be incomparable. A mismatched/refusing/invalid external signer fails.
Verification checks the signature and historical activity at the signed heads;
it does not establish current policy or snapshot correctness. `receive` performs
bounded decoding, historical verification, ID derivation, model validation and
the current late-arrival check. A newly arrived record revoked by a descendant
current head returns `Late_record_requires_adoption`. Core adoption is explicitly
unimplemented; V1 adoption records cannot be borrowed across record domains.
An already-retained identical historical record remains an unchanged repeat.
All functions are pure: no disk, cursor, accepted head or outbox is mutated.

## Workspace/history and composition consumer contracts

`make_history_node ~id ~parent ~snapshot ~working_basis ~published_revisions`
returns a validated local node. `empty_history`, `history_nodes`, and
`retain_history : history -> history_node -> (history * insertion, error) result`
provide immutable retention. Parents must exist and precede children within one
workspace; cross-workspace ancestry starts at sequence zero. Equal contents do
not collapse nodes; conflicting payloads under one workspace/sequence fail.

`make_workspace_observation ~workspace ~cursor ~working_basis ~basis_snapshot
~observed_snapshot ~correspondence` binds one workspace/cursor, accepted basis,
exact disk observation and revision-to-local-node correspondence. It validates
shape and namespace, not the truth of a filesystem scan or correspondence.

`make_composition_request ~repository ~branch ~accepted_heads ~selected_revisions
~resolution_ids ~authority_heads ~policy_heads ~review_evidence ~workspace
~composition_profile` preserves explicit concurrent heads and exact inputs.
`validate_request_references : pool -> composition_request -> (unit, error) result`
checks scope/reference kinds and rejects unsupported policies. It is not a planner.

The consumer types are `composition_result = { accepted_snapshot; workspace_snapshot }`
and `'plan preparation = Prepared of 'plan | Blocked of blocker list`.
Blockers represent missing objects, shared/private conflicts, invalid authority,
unsupported required review, unavailable policies, stale inputs and ambiguous
correspondence. `check_review_requirement ~required:true` returns
`Required_review_unsupported`; false only means this particular gate is optional.
It is not an authorization result. No prepare/apply stub fabricates a ready plan.

Separate accepted/workspace results preserve the contract that integrating shared
D must not publish later private E. Actual composition, preview identity, stale
input checking and journal execution belong to the later pilot work.

## Vectors and remaining G02 scope

[Independent vector generator](../../test/generate_core_vectors.py) uses Python
CBOR and OpenSSL Ed25519, importing no Yeokcham implementation. It generates
three body/signature-input/envelope/ID families plus a max-int64 history pair
under [golden/core](../../test/golden/core). Run `python3 -B test/generate_core_vectors.py`
to reproduce them. The fixed `a`-byte seed is public test material. Tests compare
the independent vectors and consume verified records through `Trust.Core.receive`.

P1 covers G02's three core record families, workspace/branch/change identities,
history namespace, the pilot consumer contracts and their vectors/negative cases.
G02 remains partial: review request/version/event and repository-policy records,
account epochs/settings/archive manifests, request/member identity and proof,
private-crypto interfaces and full review/policy/archive/journal consumer APIs
are outstanding. There is no claim of completed G03 authority policy, G04
composition, persisted new history, clone/integration services or pilot usability.

## P2 native ignore checkpoint

`Yeokcham_snapshot.Ignore` is a pure byte-oriented matcher. `empty` starts a rule
set; `extend : t -> source:string -> base:string list -> string -> (t,error) result`
adds one file's rules. `evaluate : t -> path:string list -> directory:bool -> decision`
returns `{ignored; rule; blocked_by_parent}`. `source`, `line`, `pattern` and
`includes` inspect the matching abstract rule. A malformed rule returns a file,
line, original pattern and reason. No filesystem/Git lookup happens in the matcher.

`Yeokcham_snapshot.explain_ignore` and the local-service `ignore_explain` expose
`?directory:bool -> root:string -> string list -> (ignore_explanation,error) result`.
The hint supplies the kind of a nonexistent final directory; existing filesystem
kinds take precedence. Explanations distinguish mandatory exclusion, matched rule
and no rule. They read ancestor rule files without writing objects/history and
stop at excluded or symlink ancestors. Capture uses the same matcher at each
included directory, preserving one source of truth for native exclusions.

This matcher is one part of P2. Capture consistency, durable local branch/history
state and safe selection/CLI adapters are described below.

### P2 capture consistency checkpoint

`Yeokcham_snapshot.scan` and `scan_excluding_root_names` retain their existing
signatures. Internally, the POSIX descriptor adapter opens children with
`openat`/`O_NOFOLLOW`, observes them with `fstatat` without traversal and reads
symlinks with `readlinkat`. Regular reads compare device/inode/type, mode, size,
and nanosecond mtime/ctime, including an end-of-scan pathname recheck. Directory
entry lists and ignore-file presence/identity are rechecked. Large reads stop at
the initially observed size plus a one-byte growth probe.

`Observation_changed of string` requests an internal retry; after three unstable
attempts `Capture_unstable of string` reports an incomplete capture. Other
errors, including malformed rules and special files, are explicit failures.
Snapshot/object creation does not itself allocate history or publish the project
head. Failed attempts may leave unreachable immutable objects, as before.

`Yeokcham_snapshot.For_test.scan` adds an in-process
`observe:(stage -> string list -> unit)` seam (`Before_open`, `After_read`,
`Before_publish`) to exercise filesystem mutations at actual observation
boundaries. Production `scan` supplies a no-op observer. No environment,
repository configuration or remote input enables fault injection. The adapter
is POSIX-only; unsupported native platforms fail explicitly.

### P2 durable history identity checkpoint

`Yeokcham_v1_undo` retains its node/tree navigation API and adds:

```ocaml
val workspace : t -> Yeokcham_v1_model.Core.Workspace_id.t option
val next_sequence : t -> int64 option
val bind_workspace : t -> Yeokcham_v1_model.Core.Workspace_id.t -> (t, string) result
val identity : t -> node -> (Yeokcham_v1_model.Core.History_id.t, string) result
val validate_update : previous:t -> t -> (t, string) result
```

History schema 2 has ordered fields `[2, workspace_bytes_16, next_sequence_or_null,
cursor_sequence, nodes]`. Each node retains `[sequence, parent_or_null,
snapshot_text, draft_text, timestamp]`. IDs are nonnegative and strictly ordered;
parents must already exist. The next counter must exactly follow the last node,
with null only after `Int64.max_int`. Schema 1 remains readable for current data;
its known ancestry is preserved on the next write. The new canonical fixture is
`test/golden/local/history-v2.cbor.hex`.

History-only current data uses the existing
`["yeokcham-local-state", 1, inner_project_bytes, history_bytes]` wrapper under
`v1-project-state`; native initialization adds local core state with wrapper 2
below. There is no second mutable history head. The store generates
128-bit workspace entropy via `Yeokcham_v1_trust.random_bytes` and the P1 typed
constructor. Reads do not invent a fresh namespace. A mutating write binds an
existing unnamespaced history once. Namespaced appends use P1
`Core.History_id.allocate`; the returned counter, nodes, cursor and project are
published by one root CAS. Local-service mutations retain the existing worktree
writer lock. A reservation or staged immutable object is not durable allocation.

State updates refuse namespace reassignment, altered earlier nodes and erased
ancestry. A stale writer cannot publish against a newer root. Identical-content
retries after reload do not append again, including at exhaustion. These changes
retain whole-history encoding; bounded paging/index replacement and depth
measurements remain G06 work, outside this checkpoint.

`Yeokcham_v1_store.For_test.save` injects trusted in-process callbacks immediately
before/after root CAS (after immutable object persistence). Production `save` has
no external fault flags. Crash tests exercise both boundaries and subsequent
reload/retry. Materialization-journal and branch acceptance use the separate
connected service tests below.


### P2 causal branch projection checkpoint

`Yeokcham_v1_model.Core.branch_states : pool -> branch_state list` projects
verified retained records. Each row contains `branch_id`, `event_heads`,
`accepted_heads` and `display_names`. Event ancestry supersedes earlier events;
rename events inherit accepted targets through that ancestry. Accepted-parent
ancestry removes superseded target records while preserving incomparable
alternatives, even when their result snapshots match. Concurrent names remain
a set. IDs order presentation only; display times and receipt order never
choose a winner. Traversal visits each causal record once per projection pass.

The connected adapter refuses ambiguous branch names/heads and verifies actual
snapshot closure and accepted-result semantics. This pure projection neither
persists selection nor authorizes file replacement. Three signed-record cases
exercise rename inheritance, all six receipt permutations of concurrent events,
explicit target reconciliation and independent branch identities. This projection
does not implement P3 exchange/composition; CLI selection is tested separately.

### P2 authenticated local branch state

`Yeokcham_v1_store.Local` aliases `Local_core`. Its concrete signatures are in
[local_core.mli](../../lib/yeokcham_v1_store/local_core.mli). It creates signed
empty accepted genesis and a generated `main` branch, creates named forks of the
selected accepted version, resolves names conservatively and retains a private
`{ branch; cursor; basis }` position per branch. Duplicate names, identity
collisions, exhausted collision retries, ambiguous event/accepted/name sets,
unknown positions and unsupported acceptance refuse explicitly. `select` only
prepares metadata; a service must materialize safely before publishing it.
The connected CLI branch/switch adapter is described below.

`initialize` stores a canonical empty snapshot and signs it through
`Trust.Core.sign`/`receive`. It never accepts existing worktree files. The P2
adapter originally admitted only empty genesis/forks. P3 now admits nonempty
results only through the actual graph-composition verifier below. Required
policy/review and resolution support are still explicitly unsupported at this
checkpoint; no integration CLI success follows merely from staging metadata. Historical
state reload verifies signatures and causal references. New records pass
current admission separately; a late revoked signer cannot bypass this boundary
by decoding historically valid bytes.

Local core metadata has ordered fields
`[1, empty_snapshot_object_id, selected_branch_id, record_references, positions]`.
A reference is `[signed_record_id, stored_object_id]`; a position is
`[branch_id, cursor_sequence, working_basis_record_id]`. References and positions
are strictly ordered by their logical IDs, without duplicates. Every branch has
one position; each basis belongs to its branch's accepted ancestry.

The distinction between the two record references is intentional. P1 signed
record identity is SHA-256 of the complete canonical envelope. The existing
object store hashes its domain prefix plus that envelope. Both identities are
verified on reload, and their immutable association is retained in the same
state root. Neither the accepted P1 vectors nor existing snapshot/object IDs
were changed. These remain typed objects 41-43 in the single registry; there is
no second mutable object store or record-ID registry.

`Yeokcham_v1_store.loaded` now includes `local : Local.t option`.
`init_local_collaborative_with` atomically publishes project/private capture,
workspace/history and local core state. Wrapper version 2 is
`["yeokcham-local-state", 2, inner_project_bytes, history_bytes, local_core_bytes]`.
Existing version-1/current data remains readable; its state is preserved by
ordinary saves. `save`/`save_collaborative` accept optional `local`, preserve it
when omitted and cannot erase previously retained signed records, branches or
history. Selection/counter updates share the existing `v1-project-state` CAS.
Unsigned state cannot acquire authenticated core metadata.

`local_branch_snapshots : loaded -> Model.Snapshot_id.t list` exposes all private
branch working positions as retention roots. `Model.compact` adds optional
`branch_snapshots` and reports the `Local_branch` protection reason; local
service compaction/storage-root inspection and GC pass the actual roots. The
store refuses dropping a branch's retained checkpoint. These protections do not
invent snapshot availability after independent object loss.

Twenty-three adapter cases cover signed/private initialization, metadata selection in a
fresh process, duplicate names, missing objects/positions, bounded identity
collision and entropy failure, logical/physical identity mismatch, invalid
signatures, unsupported acceptance, historical/current admission and unselected
private work surviving compaction/GC planning, actual materialization interruptions,
copy-out recovery and signed concurrent-name refusal. CLI journeys are below.


### P2 private-init and branch CLI checkpoint

`Service.init_local_signed_with_recovery` reuses the existing signer/recovery
ceremony while capturing initial files privately against authenticated empty
accepted genesis. The earlier V1 library initializer remains for current V1
workflows. `Service.branch_list` returns selected identity, causal branch rows,
private positions and workspace namespace. `Service.branch_create` scans and
retains unsaved disk edits, creates a signed named fork and publishes the
history/positions together under the worktree lock and sole state-head CAS.

CLI `init [PATH]` generates required IDs and default names; username/draft/title
options remain available. A new PATH may be created when its parent exists.
Existing metadata refuses before another signer is created. The recovery
ceremony still refuses JSON before mutation. Automatic capture and backup are
reported unconfigured, without managed-service claims. `branch list` and
`branch create NAME` provide actual domain data in the existing CLI JSON
boundary and escaped plain text. `Core.validate_branch_name` is shared by the
constructor, store adapter and CLI argument check. Full target JSON outcomes
and ordinary inspection journeys remain P2 work.

`Service.branch_switch` now implements private file selection (documented below). The legacy V1 share/deliver path is
not native core acceptance; P3 must connect explicit publication/integration
through its real policy/composition boundary. Existing proposal CLI fixtures
now explicitly share/deliver their initial V1 baseline, rather than relying on
initialization to accept private files. Their substantive conflict/provenance,
no-acceptance and recovery assertions remain intact.

### P2 bounded inspection prerequisite

`Snapshot.Content.load_bounded repository ~max_bytes id` verifies complete
content closure and returns `Some bytes` within the bound or `None` for a larger
file. Oversized display does not hide missing chunks, incorrect lengths,
noncanonical chunk boundaries or a mismatched full-content identity.
`Snapshot.Content.verify repository id` performs the same closure validation
without returning file bytes. Neither operation writes objects or metadata.

`Manifest.load` now verifies with a streaming CDC/hash pass instead of rebuilding
whole file contents. Working memory retains manifest references, the splitter
and individual stored chunks. Existing `Content.load` still returns a complete
string when a caller explicitly requests it. Snapshot/manifest/chunk identities
and canonical bytes remain unchanged. The local service's closure preflight
uses `Content.verify`; materialization output staging remains separate work.

### P2 local inspection domain checkpoint

`Service.inspect_local_status` returns saved metadata, exact cursor/content
identity, selected branch metadata, a complete current comparison or explicit
capture-incomplete error, and any pending recovery operation. Incomplete capture
must not be rendered as clean. Working observations use the existing worktree
writer boundary and refuse pending recovery, so inspection does not capture an
interrupted partial application. They may store immutable scan objects, but do
not publish a root, create history or rewrite ordinary files.

`Service.compare_local_states` accepts `Current_saved`, `Working_tree`,
`History_node sequence`, `Exact_history workspace_sequence` and
`Snapshot_state snapshot`. It verifies content availability, compares exact
path/type/mode/content metadata and adds bounded display hunks. Foreign workspace
IDs refuse instead of being interpreted as local sequences. Equal contents at
different nodes retain different state identities. Saved-only comparisons do
not scan the live tree and remain available while recovery is pending.

`Service.inspect_local_history ~root ~before ~limit` returns newest-first saved
rows, alternate children, titles, known changed paths, workspace identities and
availability. Limits are 1-200; the CLI default remains to be wired at 50.
Availability distinguishes verified local contents, no longer retained contents,
and missing/corrupt/unavailable contents. A missing parent comparison is explicit.
Branch working positions appear only as references to real branch identities;
undo continuations are not synthesized as shared branches. This query does not
scan working files or move the history cursor.

`Service.Text_diff` uses UTF-8 without NUL, exact CRLF/final-newline information,
common-prefix/suffix trimming, deletion-first LCS alignment and three context
lines. Display limits are 2 MiB per side and 4,000,000 alignment cells. Beyond
limits or for opaque bytes it reports an opaque result with exact metadata
available separately. This is display logic, not a P3 composition proof.
Five text cases include 400 randomized exact-byte hunk reconstructions. Six
service cases cover mixed changes, A-B-C/return-B-D, pagination, namespace scope,
equal contents/different positions, malformed/special-file capture, unavailable
contents, compaction and pending recovery without a partial capture. The connected
CLI exposes these actual results through the domain schema below.

### P2 inspection CLI and domain JSON checkpoint

`status`, `history`, `diff`, `changes`, `save`, `ignore explain` and branch
inspection/creation now use the shared schema-2 domain result in
`Yeokcham_v1_cli_data`. It contains `schema_version`, `command`, `outcome`,
`code`, `message`, `data`, `warnings`, `next_actions` and optional operation/plan
IDs. Checked `ok`/`result`/`error` aliases preserve current consumers. Legacy
schema-1 commands and exact golden bytes remain readable. Actions contain literal
argument arrays, explanation, applicability and confirmation requirements;
unknown fields, contradictory aliases/outcomes and malformed actions refuse.
The new fixture is `test/golden/local/cli-domain-v2.json`.

`status` reports changed path/type/mode/content entries, exact saved cursor,
branch/head sets and complete/incomplete observation. Incomplete observation has
`uncaptured: null`, never a clean result. Successful inspection still exits 0.
Watcher state is explicitly uninspected; managed scheduling is unimplemented and
private backup unconfigured. No runtime or backup success is inferred.

`history [--before SEQUENCE] [--limit 1-200] [--all]` defaults to 50 rows and
reports alternate children, paths, titles, recorded UTC times, exact workspace
identities and verified availability. Initial zero timestamps are unrecorded,
not displayed as 1970. Archive state remains explicitly unconfigured. Suggested
recovery actions use the currently supported preview command.

`diff [STATE_A [STATE_B]]` compares exact retained snapshots/history positions
or `working`. No arguments compares current saved with working; one compares it
with working. Sequences are local convenience selectors; `workspace:sequence`
identifies a scoped history position. Missing content and foreign scopes refuse
explicitly. Text displays bounded hunks with exact newline flags; opaque/type/
mode changes retain exact identities. `changes` keeps its existing plain metadata
view while now exposing domain data in JSON. `save` returns actual saved/unchanged
snapshot data and emits JSON after post-success hooks so warnings are retained.

Byte paths use nullable UTF-8 text plus an exact hex representation in structured
inspection; invalid UTF-8 is escaped in plain text. Literal terminal controls in
text differences are escaped. Ignore explanation preserves byte-pattern/source
hex alongside nullable display strings. Non-UTF-8 workspace roots use a safe
default title; actions that cannot represent that root as a JSON string are
explicitly inapplicable with a run-from-workspace explanation.

Nine fresh-process inspection cases cover mixed text/binary/mode/type changes,
A-B-C/return-B-D, pagination, equal content/different positions, malformed rules,
missing content, namespace errors, terminal controls and byte paths/roots.
Seventeen branch cases additionally cover creation/selection, plan changes,
interactive cancellation, literal names, ignored obstructions and unavailable
signers. These journeys use real immutable records/durable state with the explicit
disposable test signer; native credential-service acceptance is not inferred.

P2 safe-application prerequisites expose `Yeokcham_snapshot.Filesystem` for
no-follow descriptor-relative inspection, exclusive creation, exclusive rename
and atomic exchange. Unsupported rename adapters refuse; no overwrite fallback
is used. `Content.stream_to_fd` verifies full content while writing only to a
caller-owned private staging file. Failure may leave partial staged bytes.
`Observation.scan` returns the successful capture's included-entry fingerprints,
ignore-rule read set and raw directory names (without reading ignored contents).
These observations do not reserve names or constitute a filesystem transaction.
These primitives support staged P2 in-place navigation and copy-out. The legacy
shared workspace-activation adapter is separate and retains its conservative
behavior; P2 does not claim to replace that future P3 integration path.

`Yeokcham_v1_local_service.Safe_apply` prepares bounded canonical physical plans
under `.yeokcham/restore-staging/OPERATION/`, binds them to safety/target snapshot
IDs and a SHA-256 digest, and applies them using no-follow parent descriptors.
`prepare` validates complete target contents, native exclusions, known ignored
obstructions, parent access, component lengths and filesystem boundaries before
ordinary mutations. Changed nodes use exclusive moves or atomic exchange;
displaced original inodes stay in numbered slots. Shared directories containing
noncolliding ignored children remain in place. `load` validates the digest,
operation/snapshot scope, canonical paths/order and the 16 MiB plan bound.
`apply` checks every action's recorded initial/applied identity state before
continuing. Unknown states refuse with the path and retained slot; there is no
automatic rollback over external edits. `For_test.apply` exposes trusted
in-process hooks before/after actual mutations and after directory fsyncs.
Casefold directories, cross-filesystem application and unavailable native rename
semantics refuse explicitly. The engine is now connected to the schema-3 restore journal, navigation and CLI switch described below.

P2 navigation now uses the physical engine. Restore journal schema 3 extends
schema 2 with a 32-byte physical-plan digest and optional typed branch identity.
Every generation must preserve operation, safety/target IDs, exact history node,
plan digest and branch scope. The service saves a complete safety observation
and target-node reservation before appending Prepared, then advances Applying,
verifies/applies the physical plan, appends Materialized, publishes the exact
cursor/project/branch root and appends the existing restore proof and Published.
A Materialized retry publishes metadata without rescanning or rewriting later
external edits. A crash after metadata publication selects the same reserved
node again, without allocating another safety or target node. Displaced native
nodes are retained in the operation's staging directory; proof forgetting and
object GC do not erase them. This is process-interruption evidence, not a claim
of tested power-loss behavior on every filesystem.

Legacy Prepared/Applying journals without physical identity plans refuse
replacement and retain their live bytes and checkpoint roots for explicit
copy-out/diagnosis. Legacy Materialized/Published journals remain readable and
can finish metadata publication. `Store.save{,_collaborative}` now refuses a
changed branch selection unless the submitted history already selects that
branch's exact retained cursor. This prevents accidental branch retargeting.
`Service.For_test` provides in-process hooks at safety publication, journal
phases, actual file mutations and metadata publication; no CLI, project file or
environment setting enables those hooks. CLI switch is now delivered below;
selection confirmation, exact plan binding and copy-out routing are described below.


`Service.branch_switch ~root ~name ~dry_run` resolves an unambiguous authenticated
branch and its exact private history node. A different branch causes a complete
source observation, full target-closure and read-only filesystem preflight,
then either a metadata-only selection for equal contents or the schema-3
journaled file operation. The source branch remembers its private safety cursor;
the target retains its own cursor. Selecting the current branch is a no-op and
does not capture unsaved files. Pending switches resume only their original
target; unrelated operations refuse. `branch_switch_confirmed ~preview` checks
the state-head, target branch/node and observed contents under the writer lock;
stale interactive previews cannot apply another plan. `branch_switch` results
carry those scope values, exact changed paths, capture effects and recovery IDs.
`For_test.branch_switch` exercises actual mutation and metadata boundaries.

`Safe_apply.check` performs read-only preflight without staging or ordinary-file,
history or journal writes. Actual application also stages native representations
and probes exclusive rename/exchange before replacement. The target planner now
uses streaming content verification and bounded symlink targets. The CLI
`switch NAME [--preview|--yes]` emits schema-2 domain data with typed branch and
full workspace/history identities, changes and retained recovery-directory
references. Noninteractive selection without confirmation returns exit 3 and
literal next actions; default interactive cancellation changes no files/history.
Initial selection obstructions return exit 4; a conflicted pending application
returns exit 8. Required missing content remains unavailable (5), integrity and
unsupported state fail closed (6), and unknown names are invalid (2).

Local metadata publication now reuses `Yeokcham_store.publish_file_create_only
~path ~bytes`: write/fsync an exclusive private temporary, hard-link without
replacement, fsync the parent, then remove the temporary. The boolean result
means created versus existing; callers must validate existing bytes. Restore
journal/proof append use this boundary, so readers do not recognize partially
written final records. `read_file_bounded` validates regular-file identity and
bounds; journal/proof reads and public decoders reject records above 8192 bytes.
Their canonical record schemas and existing golden bytes are unchanged.

Mutable-ref locking retains the existing `name.lock` owner marker and adds a
persistent `name.lock.gate` advisory process lock. Owner markers are themselves
published atomically. Under the gate, only an exact known marker whose positive
PID is confirmed absent can be removed. Unknown markers and live/unverifiable
owners remain untouched; PID reuse can therefore require explicit diagnosis.
The gate is released on process exit; normal return or an exception releases
both resources. The root CAS still publishes one complete immutable state ID.
`Store.For_test` exposes trusted publication hooks at temporary creation/write/
fsync, final link/directory fsync and ref replacement/directory fsync. These
process-interruption tests do not claim filesystem-independent power-loss proof.

GC's consistent/mutating operations now acquire the same workspace process lock
as capture/navigation before restore-retention and state-head locks. This stops
a second CLI process from collecting newly captured objects before their safety
root is published. Read-only `Gc.inspect` remains an observation. The lock order
is workspace, restore-retention, state head. This pilot does not introduce a
managed scheduler or claim concurrent-domain support for process advisory locks.

The physical engine now reports typed `Conflict`, `Unavailable` and
`Invalid_plan` errors. Initial preflight maps these to selection conflict (4),
unavailable capability/I/O (5) or integrity failure (6); interrupted application
retains its operation and refuses recovery conflicts (8). `Content.verify_fd`
compares an opened regular file with its complete canonical content through EOF,
using bounded inline/chunk buffers and before/after native observations.
`Safe_apply.apply` and `For_test.apply` now take the immutable store explicitly:
all initial/applied states verify original/retained and target bytes against the
actual safety/target snapshot trees as well as native ownership fingerprints.
This detects changed bytes even when an external writer restores inode, length
and nanosecond mtime. Corrupt staged targets refuse before ordinary replacement.

`Safe_apply.check_copyout` returns canonical destination and a 32-byte native
preflight token without staging/history/file writes. `prepare_copyout` creates
one whole-directory action for a new/empty destination. Physical-plan schema 2
adds the canonical destination-parent path and origin-repository fingerprint;
workspace schema-1 plans stay readable and byte-stable. Apply/load share the
same verified action state machine. Both repository/staging scope and destination
parent identity are checked; a replaced/occupied destination refuses, and an
exchange retains its original inode, including external directory-FD writes.
Destinations on another filesystem, within source metadata/Git metadata or
covering the source root refuse explicitly. This is an engine checkpoint:
service/journal routing and the supported local CLI contract are described below.


Restore journal schema 4 is exactly `[4, operation, target, target, generation,
phase, null, physical_digest, null, destination_bytes]`. It records a canonical
absolute destination (at most 4096 bytes) with no source-history or branch
reservation. Schema 4 permits equal safety/target IDs in copy-out scope; schema 5 below also
permits metadata-only selection. Schema 1–3 bytes/invariants remain unchanged. `Journal.pending` exposes every
pending scope/root. `latest_pending` keeps the sole in-place operation primary
when a separate recovery export is pending; multiple in-place operations refuse.
`pending_snapshots` roots all incomplete scopes. The independent Python emitter
`tools/generate_local_vectors.py` checks the schema-4 golden fixture.

`Service.preview_copy_out` returns exact target/destination and a stable semantic
plan hash, without staging or changing history/files. `copy_out ~expected_plan`
checks that token under the workspace lock and stages/journals one directory
installation. `restore ~destination` is now the compatibility wrapper over this
engine; its existing nonempty-destination error shape remains supported.
Source namespace, allocation counter, cursor, branch positions and mutable head
are unchanged. Pending copy-outs resume the same recorded operation. A
Materialized retry publishes completion without rewriting destination edits made
later. A recovery export outside the source workspace can materialize its saved
safety/target while an original in-place operation remains conflicted, without
capturing a partial source tree. Another copy-out requires completing the
existing copy-out scope first.

`Service.recover_operation ~operation` dispatches explicit recovery by journal
scope. An already Published operation is acknowledged without navigating again
or claiming its current filesystem contents were reverified. Completed exports
create no source restore proof and stop rooting immutable source snapshots;
compaction can prune their Published journals. Pending export targets remain
retained. Displaced native directories remain in operation staging. Unsupported
filesystem placement, corrupt/missing targets and newly occupied destinations
fail before replacement. CLI `restore STATE` and explicit operation recovery
use this same service boundary; their contract follows below.

The G01 harness's untimed checkpoint verifier now restores from a disposable
metadata replica. The supported restore path durably journals recovery, so
running verification directly against the measured fixture would change its
storage count during resume. Copying metadata before verification preserves the
measured fixture and still verifies stored snapshot bytes against the full
manifest. Accepted G01 measurements/results are unchanged; only tiny harness
regression fixtures run as part of required CI.

Schema 5 in-place selection is `[5, operation, safety, target, generation, phase,
exact_history_node, physical_digest, branch_or_null, selection_plan_id]`. The
32-byte local selection plan identifies the immutable pre-selection state head,
complete observed contents, exact target node/snapshot and optional target
branch. It is independent of signed review/acceptance. `Journal.make_selection`
also supports equal safety/target contents when changing history position or
branch. Those metadata-only operations still need a durable exact-node journal:
a process exit after cursor publication must not turn retry into another undo.
`requires_source_proof` is false for copy-out and equal-content selection; their
Published journals do not permanently root contents or fabricate source proofs.
Existing schema-1 through schema-4 bytes remain readable and unchanged.

`Service.navigate_history_plan ~expected_plan` and `branch_switch_plan` validate
fresh local selection intent under the workspace lock. Resuming schema-5
operations compares the recorded intent before continuing its original node.
`history_direction` now includes `Restore_snapshot`; a retained snapshot without
local ancestry receives a separate root when published. Preview results label
provisional target nodes and never durably reserve their IDs. `history_navigation`
adds optional `selection_plan` and `target_provisional`; branch results add
optional `switch_plan`. Existing convenience methods use fresh validation.
All non-no-op navigation, including equal-byte moves, now uses the same journal
path. Metadata-only selection leaves ordinary file inodes/bytes unchanged.


### Local selection CLI and recovery contract

`undo [--to NODE]`, `redo [--node NODE]`, `restore STATE [--to DIRECTORY]`
and `switch NAME` share `--preview` (`--dry-run` alias), `--yes` and optional
`--plan ID`. Interactive confirmation defaults to cancel. Without explicit
confirmation, noninteractive writes return choice-required/exit 3 with real
preview data and literal next-action arrays. `--yes` validates fresh inputs;
`--plan ID --yes` refuses changed inputs with exit 3. Explicit preview/cancellation
never moves the cursor or writes ordinary files. All non-no-op selections use
an exact journal, including equal-content cursor/branch moves. No-op results
return unchanged without a confirmation prompt. The CLI specification registers
these flags for completion/help and keeps existing hook eligibility.

`restore STATE` accepts current saved, local sequence, workspace:sequence or a
snapshot identity. `working` is invalid as a restore target; save it first.
Foreign workspace IDs refuse before mutation. `--checkpoint SNAPSHOT` and
`--destination DIRECTORY` remain compatibility aliases. Preview target nodes
include `target_provisional`; only atomic history publication allocates them.
`history_navigation` results include plan ID, exact history identity, full target
metadata, actual changed paths, whether unsaved work is preserved and recovery
operation data. Copy-out results include exact byte-valued destination, snapshot,
plan/operation IDs, and explicit false source-history/source-branch change flags.

`restore --resume [--operation ID]` inspects/resumes a recorded operation. Without
an ID it selects a sole pending operation; multiple operations return a choice
with exact IDs/actions. `--preview` reads recorded state without scanning a
partial source tree and labels current contents unverified. `--yes` dispatches
`Service.recover_operation_plan ~root ~operation ~expected_plan`. Schema-5 intent
or schema-4 physical copy intent must match a supplied plan. Older intents cannot
claim that binding. An already Published operation is acknowledged unchanged,
without rewriting or reverifying current files. `recover_operation` remains the
unbound convenience wrapper. A new relative command after completed acknowledgement
is a new request; explicit operation retry handles lost acknowledgement.

`Service.local_status` includes `pending_recovery_journals : Journal.t list` and
`recovery_inspection_error : string option`, alongside the compatibility primary
recovery summary. All pending scopes block partial capture. Status returns domain
metadata even when capture/journal inspection is incomplete. JSON lists each
operation's exact target history/snapshot/branch, scope, phase, destination,
retained staging location, known intent and `current_contents_verified=false`.
Selection errors include saved metadata, redo alternatives and pending operations,
plus meaningful preview/resume actions. Inspection exits 0 while reporting
incomplete data; mutation exits follow the design: 2 arguments/rule syntax,
3 choice/stale plan, 4 initial workspace conflict, 5 unavailable data/provider,
6 integrity/unsupported format, 7 authority refusal, 8 pending/conflicted recovery.
Legacy unrelated commands keep their existing output contract.

Byte-valued destinations use nullable UTF-8 text, display and exact bytes hex.
Actions containing non-UTF-8 arguments are escaped, explicitly inapplicable and
explain how to use the original bytes. UTF-8 actions preserve literal `--`
separators, including branch names beginning with a dash. `Safe_apply.copyout_token : t -> (string, error) result` explicitly rejects a workspace-scoped physical
plan rather than assuming every loaded plan has a destination.

Sixteen fresh-process selection journeys (`test_local_selection_cli.py`) cover
mixed byte fidelity, A-B-C/return-B-D, exact IDs, dirty redo, equal-byte metadata
moves, plan staleness, TTY cancellation, copy-out/source isolation, raw byte
paths, missing/corrupt targets and recorded recovery after actual native mutation,
Materialized and metadata-publication exits. `test/local_cli_fault.ml` is a trusted
test-only process using existing `For_test` observers; production CLI has no
fault-injection option/environment switch. Existing CLI28, branch17, inspection9,
ignore4 and tiny harness regressions remain part of CI. No native macOS/Windows,
managed scheduling, private archive/backup or P3 shared-loop claim follows from
these Linux tests.

## P3 composition and exact edit scopes (in progress)

`Yeokcham_v1_composition.Line_hunks` implements TC06 base-indexed half-open
hunks with exact line bytes, deletion-first LCS ties, prefix/suffix trimming,
2 MiB per-input and 4,000,000-cell limits. Set merge coalesces identical hunks;
competing insertions and insertions touching replacement boundaries refuse.
`Text_diff` uses the same alignment while retaining its separate display/context
API. Text display alone is not a proof of accepted contents.

`Yeokcham_v1_composition` exposes opaque flat trees, validated snapshot `load`,
immutable `store`, exact `differences`, selected subtree construction with
explicit excluded paths, and multi-variant `merge`. Whole-path equality/unchanged
rules apply before bounded text merging. Types, directories, executable changes
and symlink contents participate; no guessed opaque-file merge. Only immutable
objects may be staged, never live files, cursors, accepted history or state roots.
`Invalid_input`, `Unavailable`, `Integrity` and `Conflicts of string list list`
remain distinct outcomes.

Registry code **44** is `Core_edit_scope`. A scope is a canonical immutable
collection of byte-component paths: leaf `[1, 0, paths]` or index
`[1, 1, child_object_ids]`. Every complete envelope is at most 1 MiB. Leaves hold
at most 128 paths, greedily split with a 64-byte envelope/array allowance; indexes
hold at most 128 children. Paths sort by raw components. Readers bound bytes
before decoding, reject repeated/cyclic/deep pages, malformed IDs, unsupported
versions, metadata paths and noncanonical ordering/duplicates/pagination, and
recompute the canonical root without writing objects. Root identities use the
existing domain-separated store object identity. `Scope.closure` returns verified
page IDs for package/retention consumers. The sole registry remains
`Yeokcham_envelope`; P1 record codes 41–43 and their bytes are unchanged.

`validate_revision store revision` verifies full base/result closure and exact
scope equality to the actual changed path set. Mandatory metadata paths refuse.
A signed declaration cannot substitute for this content check. Independent
Python scope envelope/identity fixtures are in `test/golden/composition/` and
checked by `tools/generate_composition_vectors.py`. Focused profile/tree/scope
and malformed-input/property cases are in `test/test_composition.ml`.

The later P3 checkpoints below supply accepted-result graph verification and
scoped publication receipts. Selected share CLI, clone/exchange, integration
plans/execution and conflict resolution remain incomplete.


### P3 accepted-result graph and signed store boundary (in progress)

`Composition.Graph` exposes `accepted`, `represented`, `common_base`, `compose`
and `validate`. It validates full revision scope/content correspondence and
recorded public bases, composes dependency layers as sets, preserves unrelated
accepted work during exact revision updates, rejects concurrent floating versions
of one change, and refuses missing/incomparable merge bases. Accepted snapshots
must equal deterministic composition of their exact parents/chosen revisions.
An advance/reconciliation cannot discard an accepted head inherited from its
previous branch events. Rename inherits rather than replacing accepted targets.
Graph errors distinguish underlying content failure, invalid graph and an
explicit decision. Signature verification/admission remains `Trust.Core`.

`Store.Local.decode` now runs this verifier after historical signature/reference
validation, and `admit_update` runs it after current admission for new records.
Complete public dependency data is required by this current read boundary;
unknown/missing/invalid data is refused rather than called verified. A valid
signature over a false accepted snapshot is rejected. Nonempty forks inherit the
verified source accepted snapshot rather than substituting empty contents.

`Store.Local.prepare_revision` and `prepare_acceptance` stage canonical signed
records and return metadata plus the logical record identity. The latter checks
exact current accepted heads and creates an advance/reconciliation event. These
APIs do not publish a root, materialize files or create a durable outbox. Actual
journaled service execution/atomic history/outbound publication is still needed.
Change ID generation uses the existing typed CSPRNG constructor with three
collision attempts. `Local.pool` and `record_objects` expose verified public
records separately from local positions; packaging must never export `Local.encode`.

`Store.local_shared_snapshots` exposes public revision bases/results and accepted
snapshots as independent retention roots. `Gc.Shared_history` roots their entire
snapshot/content closure even when a derived selected result does not appear in
any private checkpoint. The signed-store test runs actual collection and reload
before checking a nonempty fork; private file bytes remain absent from the public
result. Scope pages/record types remain conservatively retained until their
collection consumers are extended.

Six graph cases cover updates, dependency bases, concurrent accepted heads,
equal-content ambiguous bases, false results/nonempty genesis, inherited-head
loss and unrecorded private bases. Native signed local-state suite has 25 cases,
including a valid signature over an existing wrong snapshot that still fails
composition proof, and a bounded typed change-ID collision test. This does not
complete P3 or authorize unsupported resolution/policy behavior.


Status inspection has a writer-busy outcome: if the workspace process lock is
held, it reads the atomic saved metadata while marking capture incomplete and
uncaptured/changes unknown. It does not scan partial live files or claim clean
contents. The forked writer test plus foreground-watch and runtime journeys
exercise this boundary; status remains useful while capture/application runs.

### P3 publication receipts and metadata pages (in progress)

`Yeokcham_v1_pages.store repository ~namespace rows` stores immutable byte-key/
value collections; `load` and `closure` verify and return sorted rows or object
identities. Registry **45** is `Core_metadata_page`. Every full envelope is at
most 1 MiB and binds the same 1–128-byte namespace. Keys contain 1–1024 bytes;
values contain at most 8 MiB. Constructor order is immaterial and duplicate keys
refuse. The ordered payloads are:

| Kind | Ordered payload |
| --- | --- |
| Collection leaf | `[1, namespace, 0, [[key, value_reference], ...]]` |
| Collection index | `[1, namespace, 1, [[maximum_key, child_id], ...]]` |
| Value chunk | `[1, namespace, 2, bytes]` |
| Value index | `[1, namespace, 3, total_length, [chunk_id, ...]]` |

References use raw 32-byte store identities. Values up to 4096 bytes use
`[0, bytes]`; larger values use `[1, value_index_id]`. Chunks contain 512 KiB
except the final nonempty chunk. Value indices are mandatory for chunked values,
including a single chunk. Leaves/indices group consecutive sorted rows/children
in sets of 128; a root leaf represents the empty collection. Each index level is
built until one root remains. Readers bound input before decoding, verify object
identity/type/namespace, lengths, child maxima, order and pagination, and
reconstruct the canonical root without writes. Repeated collection pages refuse;
identical value chunks may be reused. This adds collections for new metadata,
not a replacement for the existing whole-history representation or a performance
claim. Independent envelope/identity fixtures share the composition generator.

`Store.Local.publications` exposes private `publication` receipts.
`find_publication ~intent` locates a recorded retry; `record_publication` stages
one under the selected branch and returns its generated typed 128-bit operation
identity. Identical intent/inputs reuse the receipt without entropy; conflicting
intent reuse refuses. New operation allocation allows at most three collisions.
The source `History_id` and observed snapshot must match the authoritative local
history before root publication. Existing receipts cannot be erased or altered.

Local state with no receipt remains schema 1. Schema 2 appends the publication
collection root to the existing fields:
`[2, empty_snapshot, selected_branch, record_pairs, positions, publication_root]`.
The namespace is `local-publications-v1\0` followed by raw repository identity;
each key is the operation's 16 raw bytes. The value is the canonical array
`[1, intent_digest, revision, branch, workspace, sequence, observed_snapshot,
contributed_scope, title, witness_root]`. Titles are nonempty UTF-8 text, at most
1024 bytes and without NUL. Other identities are raw bytes; sequence is a
nonnegative int64. The receipt retains the exact signed revision as outbound
work in the same state root; it does not acknowledge a remote transfer.

The contribution is exactly the difference from the previous public revision's
result (or the declared base for a new change), with corresponding values/absence
proved at its private source observation. Carried-forward public fields are not
claimed as observed local work. Concurrent predecessors currently need an
explicit decision. The witness set uses namespace
`local-publication-witness-v1\0` plus raw repository identity, raw object-ID keys,
and empty values. It must equal the exact snapshot/ancestor trees used to query
the contributed scope; unrelated content blobs are excluded.

`Composition.Witness.inspect ~snapshot ~paths` returns selected entries/absence
and these exact object identities. New `Snapshot.Tree.load_metadata` and
`Snapshot.Snapshot.load_metadata` verify only the canonical referenced object,
without descendant contents. Existing `load` functions still verify full closure.
`Store.local_publication_witnesses` and `Gc.Publication_witness` root witness
objects directly, without recursively retaining every private blob reachable
from an old source snapshot. The GC regression actually removes an old unselected
blob, then reloads and verifies the receipt successfully. Missing old private
contents are not misreported as a complete restorable snapshot.

These APIs stage metadata. The actual share service/CLI must still atomically
publish capture/history, signed records and receipts; transport acknowledgements
and recoverable integration operations remain later P3 work. No exchange or
integration success follows from this checkpoint.

`Yeokcham_v1_pages.page_references ~namespace ~expected bytes` discovers direct
metadata child/value references for transfer before a complete collection is
available. It bounds each input envelope to 1 MiB before decoding, verifies its
raw stored identity/type/scope and supported version/features, and rejects
malformed rows/references, unsorted/duplicate keys, invalid fanout and value/chunk
limits. Returned references are unique and sorted; repeated identical value
chunks remain valid. No object is fetched or written by this function.

This is structural discovery, not admission: a caller must bound graph traversal
and reject repeated collection tree pages, then run the ordinary canonical
`load`/`load_bounded` verifier over the fetched closure. Child maxima, actual chunk
lengths and canonical pagination require that full check. Tests compare discovered
closure against the existing verifier over a 17001-row/8-MiB-value collection and
show that a structurally traversable false child maximum still fails admission.
This primitive alone does not implement Core export, remote receipt or clone.

### P3 selected-publication service and CLI (in progress)

`Local_service.Share` aliases `Native_share`. `Share.prepare ~store ~loaded
~observed ~observation ~paths ~update ~title` returns an opaque prepared value;
`preview` exposes its domain result. `stage ~store ~signing_capability` returns
project/history/local state plus the result, without publishing the mutable root.
`Local_service.share_selected ~root ~paths ~update ~title ~dry_run
~signing_capability` captures/prepares under the existing workspace writer
boundary, releases it for provider-backed immutable staging, then reacquires it
and reloads/revalidates the state head and filesystem facts before publishing
capture/history, signed revision and private receipt atomically. Changed inputs
refuse with a fresh-preview choice; unrelated state is preserved. Concurrent GC
may discard unrooted immutable staging while a provider waits; verification then
refuses without publishing and a fresh attempt recaptures it. Preview needs
no signing capability. Fresh change/operation identities are generated only
when recording; source history identity in a dirty preview is provisional.
Publication entropy retries exclude all integration/recovery attempt tokens,
including superseded attempts, as well as existing publication tokens; the
existing three-attempt bound and identical-request identity reuse remain.

New changes use the recorded private accepted basis; explicit updates select
one causal change head and preserve unselected prior public fields. Concurrent
change/authority heads refuse with a choice. Missing content, invalid selection,
policy and metadata errors remain distinct. Current active local author/key
checks precede signing; the existing trust admission still verifies the result.
`Snapshot.Observation.ignored ~path ~directory` evaluates rules retained by that
successful capture, including ignored formerly-public paths absent from its
snapshot. It never rereads mutable ignore files while constructing public work.

The retry intent is SHA-256 over domain `yeokcham/local-share-intent/v1\0` and
canonical ordered CBOR `[1, repository, workspace, effective_source_sequence,
branch, accepted_basis, observed_snapshot, selected_paths, update_change_or_null,
title]`. Effective source is the existing current node or the unpublished next
node for changed bytes, so an acknowledged or lost-response retry resolves the
same intent after root publication. Unchanged new sharing is an honest no-op;
explicit updates with changed inputs create a new immutable version. A
same-content update may contribute an empty scope, which claims no new local
path correspondence. Its snapshot-only witness still binds the source node.

The ordinary CLI supports `share [PATH...]`, `--title`, `--update CHANGE`,
`--preview`/`--dry-run`, root-relative paths and literal `--` paths. No extra
confirmation is required for an explicit share. Advanced `--change/--revision`
V1 sharing remains a separate parser/record family. Native output uses domain
schema 2 with generated IDs, source/provisional capture information, exact
base/public snapshots and contributed/full public paths; transfer is pending
and acceptance is false. Status exposes the verified native revisions, current
private basis and retained local publication receipts separately from branch
heads. Share hooks run after a new publication, not preview or repeated intent.

Actual root-boundary fault injection is available through trusted
`Store.For_test.save_collaborative` callbacks and the service's existing
`Before_metadata_publish`/`After_metadata_publish` seam. The fork tests verify
that history never commits separately from its revision/receipt and that a
lost response adds no duplicate record, root update or history node. This does
not yet complete public export, transfer acknowledgement, clone or integration.

### P3 exact integration plans and private continuation (in progress)

`Yeokcham_v1_integration` is exposed as `Local_service.Integration`; its
`Preservation` module is also exposed as `Local_service.Preservation`.
`prepare ~store ~loaded ~observed ~observation ~selected_revisions
~reconcile_heads` computes actual accepted/private outputs or named conflicts/
decisions. It stages immutable objects only. `Core.change_heads` supplies the
shared causal head calculation also used by ordinary share; `Graph.represented_revisions`
follows exact dependencies and previous versions separately from pending
composition. Concurrent change heads require a decision. Divergent branch
heads require every current event and accepted head explicitly named, including
equal resulting contents. An active enrolled local author and one authority head are
required. Required policy/review/resolution semantics still refuse explicitly.

Private preservation begins with the recorded accepted basis. It overlays only
newly represented publication scopes whose exact source lies on the current
private ancestry, taking the most recent source per revision in ancestry order.
Already represented basis revisions are excluded, so an old D1 publication
cannot backdate an accepted D2 basis. Source witnesses prove only their scoped
values/absence. The complete private source tree is never a shared base.
`Composition.overlay` applies those proved structural changes and revalidates
parent invariants. Three-way composition of the virtual known-present shared
tree, proposed accepted tree and current observation produces the private result.
Tests prove D accepted with private E/X retained, nonancestor correspondence
refused, and a private return to D1 preserved over a D2 basis.

Registry **46** is `Core_integration_plan`. Its typed `Core.Plan_id` is SHA-256 of
the complete unsigned canonical envelope; its raw store identity remains in the
existing object-store domain. The full control is bounded at 8 MiB. Ordered
payload fields are:

```text
[1, request, selection_root, filesystem_digest, known_present_snapshot,
 accepted_snapshot_or_null, readiness, no_op]

request = [repository, branch, event_heads, accepted_heads, exact_revisions,
           resolutions, authority_heads, policy_heads, review_evidence,
           workspace, composition_profile]
workspace = [workspace_id, cursor_sequence, working_basis, basis_snapshot,
             observed_snapshot, correspondence_root]
readiness = [0, accepted_snapshot, workspace_snapshot]
          | [1, [[path_parts, exact_versions, private_workspace], ...]]
          | [2, decision_text]
```

All identity sets are strict sorted/unique arrays. Identity sizes follow their
Core types; path components and native fingerprints are bytes. The filesystem
digest is SHA-256 over domain `yeokcham/integration-observation/v1\0` and canonical
`[1, entries, rules, directories]`: entry rows contain path/fingerprint; rule rows
contain path/fingerprint-or-null; directory rows contain path/fingerprint/names.
These are the captured facts, not another live scan during encoding.

Selection pages use namespace `integration-selection-v1\0` plus raw repository
identity, change-ID keys and encoded causal-head arrays. Correspondence pages use
`integration-correspondence-v1\0` plus repository/workspace identities; keys are
operation IDs and values are `[1, revision, publication_branch, source_workspace,
source_sequence, observed_snapshot, contributed_scope, witness_root]`. These
private roots bind the exact scoped receipts rather than the mutable global head.
`Pages.load_bounded` additionally bounds row count, individual values and aggregate
reconstructed value bytes before allocation; existing unbounded collection format
and golden bytes are unchanged.

`decode ~store ~loaded bytes` validates bounded canonical shape, typed references,
repository/workspace scope, source receipt membership, branch/reference kinds,
known authority and supported policy. Decoded Ready data is a declared proposal.
`revalidate` freezes the recorded exact selection, recomputes current preparation,
and compares relevant inputs before accepting its deterministic outputs. Unrelated
receipt preserves the plan; selected-head, cursor or disk changes return Stale.
A canonical false private-as-accepted output fails integrity after recomputation.
No decoded declaration alone authorizes application.

`retain` verifies complete proposed contents, then publishes a private immutable
`integration-plans/PLAN_ID.plan` alias through the existing create-only/fsynced
primitive under the retention lock. `load` and `scan` are bounded and verify the
filename identity. No accepted/history ref is added. `Gc.Integration_proposal`
roots observed, basis, known-present, accepted and private output snapshots until
the alias is released. Actual GC/reload and fresh-process tests verify retention;
`forget` releases only the proposal alias, allowing uncommitted staging to be
collected while leaving live files unchanged. `forget` now refuses an alias
owned by an incomplete durable operation. Health durable-record kind 5
is `Integration_plan_record`, so corrupt proposals are diagnosed separately from
an unreadable state head. Corruption refuses replacement and blocks GC planning.

This supplies the actual library planner/retained proposal. The following
checkpoints add durable service execution and ordinary CLI integration;
resolution and native exchange remain in progress. Private recovery is described
after the integration consumer below.


### P3 durable integration service (in progress)

`Local_service.Integrate` is `Native_integration`. Its `prepare ~root
~selected_revisions ~reconcile_heads` captures and retains an exact proposal and
runs the existing `Safe_apply.check` for Ready contents. `apply ~root ~plan
~signing_capability` is called only after confirmation of that Plan ID. `resume
~root ~operation` continues an existing durable operation without another signer.
These APIs are wired to actual storage and file application. The following CLI
checkpoint supplies selection/confirmation/inspection/resume; the private recovery
consumer below supplies explicit cancellation and recovery choices.

Providers run after releasing the writer lock. The service reacquires the lock,
reloads the current root and fully revalidates the exact plan after signing.
Changes during provider interaction refuse before operation reservation or file
replacement. Relevant shared inputs are checked again during resume and before
commit via `Integration.revalidate_shared ~store ~loaded ~cursor`. That narrower
check binds the durable safety cursor, selected branch/basis, event/accepted
heads, floating selections and active authority. It deliberately avoids scanning
a partially applied tree; it cannot authorize starting a decoded proposal alone.

`Store.Local.Operation` owns private integration facts in the same authoritative
root. Nonempty operations select local-core schema 3:

```text
[3, empty_snapshot, selected_branch, record_pairs, positions,
 publication_root_or_null, operation_root]
```

Schemas 1/2 remain canonical when there are no operations. Operation pages use
namespace `local-integration-operations-v1\0` plus repository bytes, keyed by
128-bit operation token. Ordered value fields are:

```text
[1, plan_id, plan_object, branch, source_workspace, source_sequence,
 target_sequence, safety_snapshot, workspace_target, accepted_record,
 staged_record_pairs, physical_digest, expected_generation, expected_root,
 created_at, phase, serial, outbound_acknowledged]
phase = [0] Prepared | [1] Applying | [2] Materialized | [3] Committed
      | [4] Completed | [5, resumable_stage, reason] Paused
resumable_stage = 0 Prepared | 1 Applying | 2 Materialized
```

Identities/digests are raw bytes; pairs are logical-record/raw-object IDs sorted
by logical identity. Reasons are UTF-8 text, at most 4096 bytes. Each value is at
most 8192 bytes; page reconstruction allows at most 100000 rows and 64 MiB total
value bytes. The plan and signed-object readers additionally bound file input at
8 MiB before allocation through `Raw.get ?max_bytes`; callers cannot increase the
raw store's existing global bound. Plan cursor, working basis and protected
snapshots are derived/checked against the immutable plan, not separate mutable
claims in the operation row.

Tokens use the OS CSPRNG with three collision attempts across publication and
integration operations. A Plan ID has one immutable token association. Existing
intent cannot be changed or erased; phase facts/acknowledgements advance a
consecutive serial, while an identical repeat is unchanged. New operations begin
Prepared. Signed acceptance/event objects remain staged private references until
Committed; their historical signatures, exact parents/selections/event targets
and actual accepted-result semantics verify on reload. Reusing a known sole
accepted head for private catch-up stages no duplicate acceptance.

Prepared atomically retains an unsaved safety capture when needed and reserves
only the next sequence value in the operation. It does not allocate a target
history node or advance the monotonic counter. Incomplete application owns its
safety cursor/branch and blocks ordinary service writers. Store validation also
refuses allocating its reserved sequence to an intervening capture.
`History.record_exact ~expected` creates a distinct child even when bytes match,
consuming that sequence only in the actual commit root. Pure construction is not
durable allocation.

Physical IDs are SHA-256 of domain `yeokcham/integration-application/v1\0` plus
the operation token, rendered as lowercase hex for the P2 `Safe_apply` namespace.
Its raw 32-byte physical digest binds the staged pre/post images. Actual file
mutation reuses P2 identity checks and displaced-entry preservation. Unexpected
edits cause Paused; there is no automatic rollback. Materialized never reapplies
files. Accepted records, branch/basis, exact history child, operation Committed
fact and its pending outbound obligation publish in one state-root CAS. Unrelated
received records survive; remote acknowledgement is not required for local
success. Committed/Completed retries never create another acceptance/navigation.

`Gc.Integration_operation` independently protects observed, basis, known-present,
accepted and workspace output closures until Completed, including the Committed
cleanup gap. The service writes the existing verified restore proof when safety
and target differ before closing the journal; ordinary proof roots then protect
recovery contents. Completed metadata alone does not pin private history forever.
Staging/proofs remain private. Outbound acknowledgement is a separate monotonic
fact; automated transition tests are not native relay delivery evidence.

Forked tests exercise every operation phase, before/after all five root CAS
boundaries and actual before/after mutation/sync boundaries. They verify same-token
restart without a signer, one acceptance/history child, private D/E separation,
late edits after Materialized, external-edit pauses, unrelated receipt retention,
GC roots, stale confirmation, provider-time revalidation, absence of a writer
lock during provider callbacks and bounded token collision/entropy refusal.
Conflict resolution and native clone/exchange remain P3 requirements; these
service tests do not complete P3.


### P3 integration CLI consumer (in progress)

`integrate [CHANGE...]` resolves generated change IDs to their sole causal revision
or accepts explicit retained revision IDs. Omitted selection uses a sole eligible
change; multiple choices are listed with generated IDs/titles and require named
selection or `--all`. Already represented work is excluded from automatic
selection; an empty selection can follow a received accepted head. Concurrent
change revisions refuse, and divergent branch reconciliation requires explicit
`--reconcile ID` for the complete event/accepted head union. `--yes` never chooses
a divergent head. Dependencies and exact selected inputs pass through the actual
planner/graph/trust boundary.

`--preview`/`--dry-run` requires no signing provider and does not advance the root,
accepted history or ordinary files. `--plan ID` reviews or applies a retained
proposal, while completed operations can reload their immutable control without
an alias. Text output shows separate accepted and workspace changes, with the
same bounded text/opaque display as ordinary diff. `compare_immutable_snapshots`
verifies staged immutable snapshots without requiring a private checkpoint or
scanning live files; display remains separate from composition proof.

Confirmation defaults to cancel. JSON/noninteractive writes require `--yes` and
otherwise return choice-required exit 3 with the exact plan and next invocation.
The service revalidates after confirmation/provider interaction. Resumed and
repeated operations preserve tokens; already completed retries are schema-2
Unchanged rather than implying another acceptance. Fresh already-accepted
selection also reports no-op. Required new acceptance uses the enrolled signer;
no-op, catch-up to existing acceptance and recorded operation resume need no
additional signer. Outbound state is reported pending after offline local commit.

`operation show ID` reads the exact plan/phase, source/provisional target identity,
accepted-record intent, committed fact, pause reason and outbound state without a
live scan. `operation resume ID` continues the previously confirmed operation.
Status includes `integration_operations` separately from shared revisions and
publication receipts; partial application reports incomplete observation.
Plan/result JSON carries exact IDs, profile, conflicts, accepted/private snapshots,
separate path/text differences, operation facts and actionable next commands.
Exit categories reuse selection conventions: invalid 2, choice/stale 3, conflicts
4, unavailable 5, integrity 6, unsupported authority/policy 7, paused application 8.

Fresh-process disposable-signer journeys cover D/E separation, exact revision and
contextual/all selection, saved-plan confirmation, cancellation, provider-free
preview/retry/no-op, stale inputs, text/JSON diffs, operation show/resume and
status. They are local CLI evidence. Native relay exchange/clone, complete
conflict resolution are still unimplemented P3 scope;
legacy resolution/package commands do not satisfy those criteria.

### P3 private integration recovery (in progress)

`Local_service.Integrate.recover ~root ~operation ~dry_run ~mode ~replan
~expected_plan` returns `recovery_outcome` with exact recovery digest, operation,
observed/target snapshot identities and preview/resume facts. `mode` is optional
`Store.Local.Operation.Restore_safety` (default) or `Keep_current`. `resume`
continues an existing recovery without a signer. `forget_recovery_roots ~root
~operation` explicitly releases a completed recovery's extra roots and its owned
proof; it does not erase the operation or edit files/history.

Recovery can close an uncommitted integration, including Materialized, but cannot
unaccept a Committed operation. It captures the current tree as an explicit
recovery observation, not an ordinary partial-tree checkpoint. Preflight verifies
the complete chosen target and destination constraints before mutation. Preview
does not publish an intent or move refs. Confirmation occurs outside the writer
lock. The recovery digest is SHA-256 of domain
`yeokcham/integration-recovery-plan/v1\0` followed by canonical encoding of:

```text
[1, operation_token, integration_plan_id, branch, source_workspace,
 source_sequence, operation_serial, mode, original_safety, observed_snapshot,
 filesystem_observation_digest]
mode = 0 Restore_safety | 1 Keep_current
```

This private confirmation digest uses `Core.Digest`, not registry-46 `Plan_id`.
`Integration.observation_digest` supplies the existing filesystem-fact digest.
An altered observation or serial refuses an old confirmation. Each actual attempt
uses a fresh CSPRNG 128-bit execution token with three bounded collision attempts
across publications, integration tokens and every recovery attempt. Its physical
namespace is hex SHA-256 of `yeokcham/integration-recovery-application/v1\0` plus
the integration token and attempt token. Before-first-root staging left by a crash
cannot collide with a fresh attempt's physical namespace.

An operation with recovery uses ordered value schema 2, with the same seventeen
fields after the version as schema 1, followed by `recovery`. Values without
recovery retain schema 1 exactly. No new public envelope code is allocated:

```text
[2, plan_id, plan_object, branch, source_workspace, source_sequence,
 target_sequence, safety_snapshot, workspace_target, accepted_record,
 staged_record_pairs, physical_digest, expected_generation, expected_root,
 created_at, phase, serial, outbound_acknowledged, recovery]
recovery = [1, attempt_token, recovery_digest, observed_snapshot,
 physical_digest, started_at, progress, retained, mode, pause_reason_or_null,
 previous_attempt_root_or_null]
progress = 0 Prepared | 1 Applying | 2 Materialized | 3 Committed | 4 Completed
```

The existing row/page input bounds apply. Superseded attempts are canonical
one-row metadata pages (`attempt` key), namespaced by
`integration-recovery-history-v1\0` plus repository and integration token bytes.
Each page is bounded to one row/8192 value bytes/8192 total value bytes; traversal
rejects cycles/repetition and more than 100000 prior attempts. Derived
`previous_recoveries` caches are reconstructed, not mutable independent claims.
Unsupported versions/modes/phases, malformed IDs, negative timestamps,
committed pauses, inconsistent completion and duplicate attempt identities refuse.

Recovery facts advance the same consecutive operation serial. The original
primary phase remains until recovery Completed closes it. `Operation.committed`
is false for a recovered operation; `recovered` distinguishes successful private
recovery from shared acceptance. At recovery Committed, the original provisional
history sequence is consumed once for an actual child of the saved safety node,
containing safety or the explicitly chosen current observation. Shared basis and
the authoritative Core record pool stay unchanged. Retrying the old plan remains
closed; a fresh integration can use the new cursor.

P2 staging checks every changed image and all expected target paths before
Materialized, including unchanged files, while retaining noncolliding ignored
extras. External changes pause recovery. Explicit `--replan` freezes another
observation and links the prior exact attempt; it cannot replace a committed
recovery. Materialized retries finish metadata without replaying files over later
edits. A verified owned restore proof precedes Completed when observation and
chosen result differ.

Pending operations root all required proposals/observations. Completed recovered
operations keep their proposed target and current/prior observations until
explicit release. Release updates the state root before deleting the matching
proof; retries finish cleanup across that gap. A released cancelled operation
retains signed reference/identity/input checks but no longer requires the
discarded proposal's content composition to remain available. It cannot admit
those staged records; authoritative public records still receive their full
accepted-result validation. Actual GC of an unaccepted merged target followed by
reload/resume is tested.

`Service` accepts operation-protected snapshots for read-only diff and supported
restore/copy-out. A pending copy-out journal independently owns its target even
after operation-root release. `Gc.Recovery_contents` roots non-checkpoint journal
and proof snapshots and verifies their complete closure before collection.
This avoids fabricating ordinary checkpoints to retain recovery alternatives.

CLI commands are `operation recover ID [--preview|--yes] [--plan DIGEST]
[--keep-current] [--replan]` and `operation forget ID [--preview|--yes]
[--plan DIGEST]`. Noninteractive/JSON mutation requires explicit confirmation;
preview and terminal cancellation leave files/history unchanged. Schema-2 JSON
includes mode, observed/chosen identities, comparisons/availability, recovery
phase/pause, retention and prior-observation IDs. Completed historical retries
do not claim to inspect the current tree. These local recovery journeys do not
complete conflict resolution, Core exchange or the P3 two-person pilot.

### P3 public Core package boundary (in progress)

`Yeokcham_v1_package.Core` extends the existing package/artifact boundary. It
uses public Core records and paged inventories, independently of legacy
manifest-v1 packages. Registry envelope codes 41–46 are unchanged; package
manifest **version 2** is a canonical ordered control tuple, bounded to 8 MiB:

```text
[2, repository_bytes, selected_branch_bytes, record_root, authority_root,
 title_root, inventory_root]
```

Repository and object references contain 32 raw bytes; the branch contains 16.
`decode_manifest ~repository bytes` checks shape, version, scope, identity widths
and canonical bytes; it does not prove any closure. `encode_manifest`,
`manifest_repository`, `manifest_branch` and `metadata_roots` expose actual control
data. Courier manifest identity is plain SHA-256 of these bytes, as in the existing
signed transport publication; raw store identities retain their existing domain.
The unsigned manifest cannot grant authority or substitute for record validation.

Every inventory uses registry-45 pages and a namespace of
`core-public-ROLE-v1\0` followed by repository bytes:

| Role | Byte key | Value |
| --- | --- | --- |
| `records` | logical Core record ID | raw stored-object ID |
| `authority` | tag 0 plus certificate ID, or tag 1 plus epoch ID | existing canonical certificate/epoch bytes |
| `titles` | shared-revision ID | 1–1024 UTF-8 title bytes without NUL |
| `objects` | raw stored-object ID | canonical integer envelope byte length |

The object inventory describes record envelopes, public snapshot/tree/content
closures, exact edit-scope pages and the other three inventory closures. Its own
page closure is discovered separately to avoid self-reference. Each page/value
keeps existing bounds; individual raw objects are bounded to the store's 128-MiB
limit. Ordinary large files remain manifests/chunks, rather than a whole-file
buffer. Common directory-artifact iteration/lookups now bound each file before
reading; streamed import validates each canonical identity again.

`Core.create ~source ~destination ~authority ~records ~selected_branch ~titles`
verifies historical signatures, repository/reference consistency, exact declared
scopes and actual deterministic accepted results, then creates a new directory
artifact containing precisely that public closure. It traverses typed public
records, not `Local.encode`, private history or the whole object store. Titles
are courier display metadata; they do not change a signed revision's author,
identity or contents. Private observations, correspondence pages, plan controls,
operation rows, custody and unrelated blobs are excluded.

`Core.prepare ~package ~repository ~known_authority` reads the bounded control,
discovers metadata via `Pages.page_references`, then performs full canonical page,
authority, record, composition and exact-inventory validation in an isolated
temporary store. Extra object files or even an otherwise canonical inventory
containing an unselected private blob refuse. Known authority pins causal root
continuity; without it a caller must independently compare the root before using
the result for a new workspace. This never enrolls a device. Unsupported required
record semantics still refuse through the actual Core/trust boundary.

The opaque prepared value exposes artifact, authority, historical pure pool,
record map, public titles and selected branch. `import_prepared ~destination`
copies only previously verified immutable objects, with per-object revalidation.
It creates no project head and does not change ordinary files or private cursors.
Current new-record admission and atomic receipt are supplied by `Core_receive`
below. `Core_outbound` and `Sync.Core` supply native transfer and acknowledgement;
clone materialization remains required. Historical verification alone is not
new-record admission. Legacy `read_artifact`/materialization helpers
remain legacy-manifest APIs; shared iteration/lookups support either artifact.

Actual mixed-file tests exercise selected D/later private E through native share
and integration before export, retained executable/empty-directory/symlink/binary
data, private sentinel/control exclusion, immutable-only import, malicious extra
inventory, valid signatures over false accepted results, foreign authority roots
and malformed/missing data. Independent Python vectors cover manifest encoding,
courier identity and offset/stream hash bytes. These are public-package evidence,
not a completed native relay/clone loop.

The hash adapter now selects the existing pinned Digestif 1.3.1 C implementation
instead of its OCaml implementation. The SHA-256 algorithm, `Hash.S` interface,
envelope domains and identity bytes are unchanged; no format migration follows.
The C implementation is already part of the installed dependency and the project
already requires a native C toolchain. A debugger sample of the mixed Core
journey identified repeated OCaml SHA-256 work. Functional fixture timings are
diagnostics, not G01 measurements or native performance qualification. Independent
vectors and persistent-context/offset feed tests verify the native adapter.

### P3 atomic Core metadata receipt (in progress)

`Local_service.Core_receive` aliases `Native_receipt`. `receive ~root ~package`
first runs isolated `Package.Core.prepare` against the known authority root and
imports verified immutable bytes outside the workspace writer lock. It then
acquires the same `local-worktree.lock`, reloads current state, merges verified
authority with current membership/epochs and runs
`Store.Local.receive_records ~store ~authority ~records`. That API rechecks
logical/stored identities, performs current trust admission and actual public
composition proof. Historical verification alone never admits a new late record.

The service publishes the extended Core pool and authority through one existing
state-root CAS, preserving the current project, exact history/counter/cursor,
selected branch, working basis, private positions, publications, operation roots
and legacy transport data. It never scans/captures ordinary working files, signs,
integrates, runs project commands or claims transport acknowledgement. Incoming
metadata can arrive during an incomplete integration. The integration's usual
revalidation handles relevant changes; independent branches/records survive its
later commit. Identical receipt reports Unchanged and performs no extra CAS.

`Core_receive.outcome` exposes records/branches added, unchanged status, actual
`History_id`, selected branch/basis, known branch sets and resulting state-head ID.
Typed package errors preserve Core model/record/trust/graph failures.
`Local.receive_error` separately distinguishes invalid identity/reference data,
record decoding, current trust, composition and store failures. Required unsupported
policy remains a typed refusal, not successful approval.

Known shared branches have no invented private observation. When a public branch
lacks a private position, the canonical local wrapper selects schema 4:

```text
[4, empty_snapshot, selected_branch, record_pairs, private_positions,
 publication_root_or_null, operation_root_or_null]
```

Private positions are sorted/unique, reference known branches, and must include
selection. Schema 4 is canonical only when at least one branch is known without
a private position; complete-position states retain schema 1/2/3 exactly. Those
older schemas still reject lost positions. Update validation forbids dropping
any existing private position even when a schema-4 candidate can otherwise decode.
History allocation/namespace ownership is unchanged; receiving records allocates
no private history nodes or identifiers. All state stays under the same root.

`branch list` JSON includes `local_state` (`selected`, `private_saved`,
`known_shared`) and a nullable private position. Plain output identifies
known-only branches. Selecting one currently refuses explicitly before replacement
with `shared-branch-not-materialized`/exit 3; supported first materialization is
still required by the shared workflow. A private basis behind known accepted
heads similarly reports a required integration choice instead of an integrity
error. This does not retarget names or select divergent heads.

Forked receipt tests stop before/after actual root CAS and verify one complete
old/new record set, unchanged private history/files and no extra root on retry.
Other tests cover lost-position refusal, typed required-policy refusal, fresh
JSON/plain branch inspection and receipt during a Prepared integration followed
by successful resume without losing new records. These are actual service/root
consumers of public Core packages. Native relay fetching, frozen outbound
couriers/acknowledgements, clone, remote-branch materialization and complete
two-person/fault coverage remain open; no ordinary Core relay command is claimed.

### P3 frozen Core outbound batches (in progress)

`Local_service.Core_outbound` aliases `Native_outbound`. `prepare ~root ~remote
~endpoint ~signing_capability` exports the actual public Core pool through
`Package.Core.create`, with local publication titles as courier metadata. The
provider signs outside the workspace writer lock. The service reloads current
state and checks active courier authority, local certificate and retained public
records before freezing exact manifest/courier bytes through the existing state
root. Newer shared records and private observations remain in current state;
they do not retarget the frozen batch. No network request occurs in this API.

A pending batch requires no signer to resume. `Package.Core.restore_artifact
~source ~destination ~repository ~authority ~manifest` reconstructs its exact
inventory from immutable contents, then runs the normal isolated Core verifier.
It does not replace the frozen manifest with a current export. Public records
cannot be erased; their snapshot closure stays in shared GC roots, while registry
45 inventory pages retain the existing conservative metadata retention. Actual
GC/reconstruction tests cover this ownership. Temporary exports live inside the
mandatory-excluded metadata directory; caller disposal removes ordinary completed
exports. Interrupted exports are staging copies, not independent mutable state.

`Transport.Core_outbox` owns pure frozen-batch invariants in the existing
collaboration transport value. Legacy-only values retain exact schema 1. With
Core batches, transport local schema 2 has the ordered layout:

```text
[2, legacy_remote_rows, frozen_core_rows]
frozen_core_row = [remote_name, endpoint_sha256_hex, manifest_bytes,
                   signed_courier_bytes, acknowledged_bool]
```

Rows are sorted/unique by validated remote name, at most 64. Both control byte
strings are at most 8 MiB; complete transport state is at most 16 MiB, checked
before decoding. The courier's manifest SHA-256 must match exact bytes. Schema 2
without frozen rows is noncanonical. This is private state, with no new envelope
kind or registry number. `local_state_schema_version` remains the legacy default
1. Endpoint is SHA-256 of the configured HTTPS URL, never a bearer credential.
Changing an endpoint requires a distinct remote name; pending bytes are retained.

`Core_outbox.freeze` preserves identical retries, including an existing
acknowledgement. It refuses replacement of unacknowledged work.
`acknowledge` requires the exact frozen courier ID and atomically retains its
verified courier reference and announced manifest in the remote bookkeeping.
`validate_update ~previous` rejects erased batches, endpoint changes, replacement
of pending work, acknowledgement regression and lost acknowledgement evidence.
`Store.save_collaborative` applies this guard under its existing root-CAS boundary.
Legacy remote updates preserve the Core rows.

`Core_outbound.acknowledge ~root ~remote ~endpoint ~publication` is called only
after the actual relay accepts that courier. It records the transfer fact and
marks a committed integration acknowledged only when every exact staged record
appears in that frozen manifest's canonical `Package.Core.record_inventory`.
Later acceptances remain pending. It preserves history/files and does not accept
or capture work. Per-remote facts stay distinct in transport state; the existing
operation boolean means at least one exact transfer, not all configured remotes.
No-op integrations with no staged records are not marked as transferred.

The returned outbound value contains the frozen batch, temporary verified
artifact and whether it reused pending work. Caller disposes the artifact.
`For_test` exposes `Freeze_before/after` and `Acknowledge_before/after` at actual
state-root publication boundaries. Forked faults, fresh reconstruction without a
signer, provider lock probes, later public/private work, wrong acknowledgements,
endpoint changes, actual GC and exact acceptance acknowledgement are tested.
An independent CBOR fixture covers schema 2 alongside unchanged signed courier
bytes. `Sync.Core` supplies the actual HTTP/CLI exchange consumer below. Clone
remains required; local freeze/ack tests alone do not establish P3 completion.

### P3 native HTTPS exchange and courier catalogue (in progress)

`Yeokcham_v1_sync.Core` aliases `Native_sync`. `run ~root ~remote
~load_signing_capability` drives the actual `exchange NAME` CLI. It loads existing
configuration/credentials and authenticated Core state, checks the endpoint pin,
rescans the relay's bounded publication inventory and orders unknown couriers by
verified feed dependencies. Hash cursors order a page, not arrivals; a later hash
can sort earlier, so they are not reused as an arrival high-water mark. A run
refuses above 100000 couriers. Pages must be increasing, unique and at most 128.

Core manifest, authority/record/title/object inventories and pages are verified
before following their references. `Package.Core.declared_selected_snapshots`
checks historical signed metadata and pure reference closure only, returning
claimed selected accepted targets for transfer priority. It cannot prove their
actual composition or availability. The client fetches these targets first,
then the remaining advertised inventory. `Snapshot.Manifest.load_metadata` is a
canonical declaration reader for this traversal; full `Manifest.load` still
verifies chunks. Normal package preparation and current admission remain required
before any public root update. Legacy manifest-1 feeds retain their existing
receipt consumer; `sync` remains the older family-specific command.

`Transport_http.get ?max_bytes` applies a tighter curl response limit and checks
size before allocation; publication lists are bounded to 64 KiB. Metadata pages
use 1 MiB and manifests/couriers 8 MiB limits. Content uses existing V2 verified
ranges and explicit V1 fallback only when V2 is unavailable. Uploads use existing
missing-object inventories/resumable sessions. Verified bytes may be staged in
the existing immutable store; no second mutable store is introduced.

`Package.Core.public_object_ids ~source ~authority ~records` derives the exact
verified public record/scope/snapshot closure. Download reuse is restricted to
that closure. A new advertised data hash cannot borrow matching private local
contents when the relay has not supplied them. Scoped public metadata pages have
separate namespace verification. Unadmitted data staging may be downloaded again
after interruption; mere raw-store presence supplies no durable public-provenance
claim. A real TLS regression omits an advertised blob that already exists in the
receiver's private capture and verifies unavailable receipt, unchanged root/files/
history and no subsequent private-blob upload. Raw `Local.receive_records` callers
must independently establish delivered public closure; that low-level admission
API alone does not establish object provenance.

`Core_receive.receive_publication ~root ~remote ~endpoint ~cursor ~publication
~package` verifies courier/manifest binding, active unknown publishers and feed
references, then atomically publishes the public pool, merged authority and
courier provenance. Known verified couriers remain historical facts. Existing
private history, positions, working files and operations are preserved. An exact
repeat is unchanged. The same root update retains signed courier bytes, exact
manifest and remote/endpoint through `Transport.Core_inbox`. This catalogue also
retains locally issued couriers once actually acknowledged, so preparing a new
outgoing batch cannot erase earlier exact coverage evidence.

When catalogue rows exist, private transport schema 3 is canonical:

```text
[3, legacy_remote_rows, frozen_core_rows, verified_courier_rows]
verified_courier_row = [remote_name, endpoint_sha256_hex,
                        manifest_bytes, signed_courier_bytes]
```

Catalogue rows sort by remote then courier ID, are unique, and retain verified
feed references. At most 100000 rows and the existing 16 MiB total control bound
apply; control byte strings retain 8 MiB limits. Endpoint mismatches, replacement/
erasure of retained rows and missing courier references refuse. Schema 3 without
catalogue rows is noncanonical; states without them retain schema 1/2 encoding.
No envelope code is allocated. The root writer applies both inbox and outbox
update guards. Independent Python vectors cover pending schema 2 and acknowledged
schema 3 using the unchanged historical signed courier fixture.

`Core_receive.public_titles[_for_loaded]` returns revision/title/courier/remote
provenance. These are courier display labels, not author-signed record fields.
Outgoing manifests forward only unambiguous labels; conflicting labels fall back
to stable identities. Contextual integration choices use retained labels when
unambiguous. `Core_outbound.acknowledged_records_for_loaded` derives exact per-remote
record coverage from retained acknowledged manifests, including earlier batches
while later work is pending. `local_status.status_transfers` reports the result;
CLI publication rows expose acknowledged remotes or explicit unavailable status.
An integration that reuses an already known acceptance with no staged public
records reports transfer `not_required`.

`Local.initialize_received ~store ~authority ~records ~selected_branch ~cursor`
is the clone bootstrap prerequisite: current admission and full composition
verification, one event/accepted head and a unique empty accepted ancestor. It
creates only a private empty position, signs no second shared genesis and leaves
other branches known-only. The caller must initialize matching empty history and
use verified integration for materialization. `Sync.Clone` now supplies the native
consumer described below; the earlier exchange fixture still uses library bootstrap.

`Native_sync.report` contains received records/branches/publications, legacy
receipt count, known shared-record count and actual selected branch/basis/cursor.
Upload is `No_outgoing`, exact `Acknowledged` (courier, manifest, offered-object
count, reused flag), or `Pending` with an actionable error. Offered objects include
already-present missing-inventory hits, so the count is not claimed as newly
uploaded objects. JSON schema 2 distinguishes verified local closure, checked
relay inventory, unknown remote disclosure, foreground execution and outgoing
facts. A post-receive send failure returns incomplete JSON/exit 5; receipt does
not roll back. `For_test` exposes actual offered-object, sent-manifest, sent-courier
and recorded-acknowledgement boundaries. Lost acknowledgement testing stops after
the real HTTPS courier PUT and resumes the same signed identity in a fresh CLI
without a signer.

The controlled TLS journey uses separately enrolled Alice/Bob replicas and fresh
JSON/plain CLI processes for selected mixed-file sharing, exact courier retry,
receipt without files/history movement, D acceptance/private E preservation and
accepted-history exchange. It checks actual relay object bytes for both private
sentinels. Signers are disposable explicit test capabilities. Bob is initialized
through the library, so this is native exchange evidence, not clone, native
custody onboarding, human usability, broad performance qualification or complete
P3 acceptance. First selection of known-only branches, resolutions,
missing-content inspection and the full criterion/fault audit remain required.

### P3 verified native clone (in progress)

`Yeokcham_v1_sync.Clone` aliases `Native_clone`. `source : string -> (source,error)
result` parses `https://RELAY/v1/repositories/REPOSITORY_ID` into credential-free
HTTPS endpoint and typed repository ID. `default_directory` derives a useful
name; `check_new_destination` requires a new/empty nonsymlink directory and an
existing real parent. `run ~source ~destination ~branch ~token ~signing_capability
~verify_phrase ~expected_request ~preview` returns exact request/repository/branch/
accepted/snapshot IDs, counts, preview/resume facts and optional private cursor/
operation/uncaptured-work facts. Errors distinguish invalid input, blocked
authority, choice, exchange, store and application failures.

The consumer uses `Native_sync.Fetch.inventory/publication/order_feed/with_core`.
`Fetch.publications ~known` bounds accumulated canonical courier bytes by the same
`Transport.max_local_state_bytes` (16 MiB) used for durable control, stops at the
first excess, and skips known IDs. Clone checks its growing courier/manifest
catalogue with `Core_inbox.receive` before fetching each package's content. Thus
an unpersistable aggregate refuses during download, before destination creation;
individual packet/count limits are not the only accumulated-memory bound.
`with_core` owns the temporary package and calls an authority check before content
fetch. `Package.Core.metadata_authority` loads canonical metadata authority;
`verify_public_records` performs full historical signature/reference/composition
verification for the combined public map. Actual clone also requires current
courier authority, an enrolled active local device, a reconciled authority head
and a unique branch name/accepted/event head. The independent public root phrase
must match each verified authority root. A relay bearer cannot enroll a member.
Record/object unions are bounded at 100000/1000000; existing transport/page/control
bounds still apply. The reusable raw cache consists only of verified public closure.

`Safe_apply.check_target ~store ~target` verifies full materialization closure,
bounded symlink representation and reserved paths before workspace initialization.
Actual destination representation, observations and obstructions are still checked
by safe application. Clone copies only verified artifact IDs, not raw-store listing.
`Store.init_local_collaborative_with` generates a fresh workspace/history namespace;
`Local.initialize_received` imports the public graph with an empty private position,
without signing a second genesis. It generates a private member name/draft and
configures `origin`. A fully initialized sibling staging directory supplies metadata
through an exclusive native rename; parent/destination directories are fsynced.
An existing empty mount on another filesystem may refuse the rename; there is no
replacement or cross-filesystem copy fallback. Pre-attachment interruption leaves
no activated workspace and requires rerunning the original command. Staging is
outside the working root, so it cannot become a normal captured tree.

Private transport schema 4 is used exactly when a clone intent exists:

```text
[4, legacy_remote_rows, frozen_core_rows, verified_courier_rows, clone_intent]
clone_intent = [1, endpoint_url, repository_bytes32, root_certificate_bytes32,
                device_id_text, branch_bytes16, accepted_bytes32,
                [branch_event_bytes32], integration_plan_bytes32_or_null,
                complete_bool]
```

`Transport.Core_clone.create/find/id/initialize/bind_plan/finish/validate_update`
owns that control. Request identity is SHA-256 of `yeokcham/clone-intent/v1\0`
plus canonical intent bytes with null plan and false completion. The immutable
source selection binds endpoint, repository, root, device, branch, accepted head
and its one event head. Actual canonical integration plan 46 separately binds
workspace/cursor/observation and both output snapshots. No envelope code is added.
URLs are at most 4096 bytes and must be HTTPS without credentials/query/fragment
or control/whitespace characters. Typed IDs enforce lengths. Completion requires
a plan. Unknown versions, malformed fields and noncanonical state refuse.
Schemas 1/2/3 keep their previous canonical bytes when no clone intent exists.
Independent Python vectors cover schema 4 and the request digest.

The existing root writer rejects introduction of clone intent after initialization,
erasure, request retargeting, completion reversal and retargeting a started plan.
Only an unstarted plan may be refreshed. `Local_service.Clone_state` exposes the
intent/pending/recovered guards. Ordinary capture refuses pending clone; only its
bound application may run. `Integrate.prepare_clone ~root ~request` checks frozen
heads and prepares the existing integration plan. Plan retention precedes binding,
binding precedes the first application operation, and a pending clone owns the plan
until completion or explicit recovery. Integration completion skips early clone
plan release; clone marks completion under the root before releasing it. Resume
also retries that cleanup after an interrupted completion acknowledgement.

`Clone.resume ~root` uses only retained local objects and the recorded plan/operation;
no network or signing provider is needed. The integration engine reuses the known
accepted version with no new signed records. Private navigation occurs once when
needed. Prepared/Applying/Materialized/Committed/Completed facts, protected safety
roots and external-edit handling remain the ordinary integration protocol. A
recovered operation is closed and clone resume refuses to restart it. A completed
repeat reports current private observation truthfully instead of rewriting files.
`For_test.run/resume` expose verified, before/after metadata attachment, before/after
plan binding, actual integration application and before/after completion boundaries.

`Transport_credential.native_scope ~url ~repository` derives `native:` plus SHA-256
of `yeokcham/native-relay-credential/v1\0`, exact endpoint, NUL, and repository hex.
`load_for_repository/save_for_repository` use that realm through the existing
credential adapter. Native exchange no longer falls back to a remote-name-only
credential. Remote login saves both legacy and scoped realms. Clone prompts only
in interactive text mode or reads one bounded line with explicit `--token-stdin`.
Preview neither saves credentials nor initializes a destination. Actual clone
requires successful scoped credential persistence first. Test bypass remains
explicitly gated and is not native custody qualification.

Ordinary CLI `clone` emits schema-2 domain JSON or readable text, generated names,
exact source request ID, local closure and foreground coverage. `--request` refuses
a changed source selection after preview. `--resume DIRECTORY` is exclusive of
new-clone options. Failure data identifies whether metadata is attached and offers
an applicable local resume action only after attachment. Clone runs no project hooks.
Native branch switching, conflict resolution, missing-content inspection and the
remaining authority/error/fault matrix are still P3 work.
