# Core-workflow foundation interfaces (P1)

These are implemented pure interfaces, not a clone, integration executor or
persistent accepted-head store. Read the actual signatures in
[model Core](../../lib/yeokcham_v1_model/core.mli),
[record Core](../../lib/yeokcham_v1_record/core_record.mli) and
[trust Core](../../lib/yeokcham_v1_trust/yeokcham_v1_trust.mli).
The existing V1 CLI, project-state wrapper, package and transport formats are
unchanged. The new records are consumed through the model/trust boundary below;
they are not yet wired into those adapters. TC01/TC02/TC06 remain the design
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

**Durability belongs to the future local store/journal adapter.** It must create
and retain the workspace namespace, acquire the repository writer lock, reserve
the sequence, append the node and publish the returned counter/cursor under one
atomic metadata-root update. Failed/retried writes must reuse the committed
operation or leave the reservation unpublished. P1's pure `allocate` function
does not perform that transaction. No CLI or existing integer undo IDs have been
migrated. A copied workspace needs a new namespace; its first node can name the
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
