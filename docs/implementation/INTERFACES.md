# Core-workflow interfaces (P1 and current P2 checkpoints)

These are implemented pure interfaces, not a clone, integration executor or
persistent accepted-head store. Read the actual signatures in
[model Core](../../lib/yeokcham_v1_model/core.mli),
[record Core](../../lib/yeokcham_v1_record/core_record.mli) and
[trust Core](../../lib/yeokcham_v1_trust/yeokcham_v1_trust.mli).
P1 left the V1 CLI, project-state wrapper, package and transport formats
unchanged. The current P2 checkpoints below add native ignore/capture behavior
and persisted workspace/history identity to the existing local-state wrapper.
Signed core branch records still await their durable local adapter; the P1
model/trust boundary and current causal-head projection are described below. TC01/TC02/TC06 remain the design
authority in [Technical contracts](../TECHNICAL_CONTRACTS.md).

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

`Model.Core.Workspace_id`, `Branch_id`, and `Change_id` are distinct abstract
types implementing `Random_id`. Each exposes `of_raw`, `to_raw`, `of_hex`,
`to_hex`, `equal`, `compare`, and:

```ocaml
generate : random_bytes:(int -> (string, string) result) -> unit -> (t, error) result
```

The adapter supplies an OS CSPRNG; exactly 16 bytes are requested. Short/error/
exceptional entropy is rejected. Hex parsing accepts exactly the lowercase
representation. `Repository_id`, `Record_id`, `Object_id`, and `Digest` use
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

This checkpoint does not establish P2 completion, capture consistency, safe
replacement, durable workspace/branch state or the remaining ordinary CLI journeys.

### P2 capture consistency checkpoint (in progress)

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

### P2 durable history identity checkpoint (in progress)

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

Initialization now stores history immediately in the existing
`["yeokcham-local-state", 1, inner_project_bytes, history_bytes]` wrapper under
`v1-project-state`; there is no second mutable history head. The store generates
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
reload/retry. These are metadata publication tests, not materialization-journal
acceptance or completed branch support.


### P2 causal branch projection checkpoint (in progress)

`Yeokcham_v1_model.Core.branch_states : pool -> branch_state list` projects
verified retained records. Each row contains `branch_id`, `event_heads`,
`accepted_heads` and `display_names`. Event ancestry supersedes earlier events;
rename events inherit accepted targets through that ancestry. Accepted-parent
ancestry removes superseded target records while preserving incomparable
alternatives, even when their result snapshots match. Concurrent names remain
a set. IDs order presentation only; display times and receipt order never
choose a winner. Traversal visits each causal record once per projection pass.

The adapter must still refuse ambiguous branch names/heads and verify actual
snapshot closure and accepted-result semantics. This pure projection neither
persists selection nor authorizes file replacement. Three signed-record cases
exercise rename inheritance, all six receipt permutations of concurrent events,
explicit target reconciliation and independent branch identities. No P3 exchange,
composition or CLI branch success is claimed by this checkpoint.

### P2 authenticated local branch state (adapter checkpoint, in progress)

`Yeokcham_v1_store.Local` aliases `Local_core`. Its concrete signatures are in
[local_core.mli](../../lib/yeokcham_v1_store/local_core.mli). It creates signed
empty accepted genesis and a generated `main` branch, creates named forks of the
selected accepted version, resolves names conservatively and retains a private
`{ branch; cursor; basis }` position per branch. Duplicate names, identity
collisions, exhausted collision retries, ambiguous event/accepted/name sets,
unknown positions and unsupported acceptance refuse explicitly. `select` only
prepares metadata; a service must materialize safely before publishing it.
There is no branch/switch CLI claim at this checkpoint.

`initialize` stores a canonical empty snapshot and signs it through
`Trust.Core.sign`/`receive`. It never accepts existing worktree files. The local
adapter currently admits only empty genesis and forks with at most one accepted
parent, no chosen revisions/resolutions/review/policy and the canonical empty
result. Other acceptance requires the actual P3 integration proof. Historical
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

Seven adapter cases cover signed/private initialization, metadata selection in a
fresh process, duplicate names, missing objects/positions, bounded identity
collision and entropy failure, logical/physical identity mismatch, invalid
signatures, unsupported acceptance, historical/current admission and unselected
private work surviving compaction/GC planning. Materialization and CLI branch
journeys remain outstanding.


### P2 private-init and branch CLI checkpoint (in progress)

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

This checkpoint does not implement switch. The legacy V1 share/deliver path is
not native core acceptance; P3 must connect explicit publication/integration
through its real policy/composition boundary. Existing proposal CLI fixtures
now explicitly share/deliver their initial V1 baseline, rather than relying on
initialization to accept private files. Their substantive conflict/provenance,
no-acceptance and recovery assertions remain intact.

### P2 bounded inspection prerequisite (in progress)

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

### P2 local inspection domain checkpoint (in progress)

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
contents, compaction and pending recovery without a partial capture. CLI rendering
and target structured outcomes remain outstanding at this checkpoint.

### P2 inspection CLI and domain JSON checkpoint (in progress)

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
Eight branch cases additionally cover actual creation outcomes and unavailable
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
The existing destructive restore path is not yet replaced by these primitives.

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
semantics refuse explicitly. This checkpoint does not yet connect the engine to
the restore journal or CLI; the existing restore path remains outstanding.

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
environment setting enables those hooks. CLI switch, complete preview and
copy-out hardening remain outstanding at this checkpoint.
