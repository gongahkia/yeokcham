(** Local V4 saved-work transitions and verified offline-package receive.

    This adapter has no network transport or semantic merge behaviour. Command
    `status`, `changes`, and `save` scan exact snapshots when invoked. Linux
    `watch` lives in the CLI and only calls `save` after debounce; it is not
    part of this module. *)

type error =
  | Store_error of Yeokcham_v4_store.error
  | Snapshot_error of Yeokcham_snapshot.error
  | Materialize_error of Yeokcham_snapshot.Materialize.error
  | Restore_journal_error of Yeokcham_v4_restore_journal.error
  | Restore_proof_error of Yeokcham_v4_restore_proof.error
  | Model_error of Yeokcham_v4_model.error
  | Trust_error of Yeokcham_v4_trust.error
  | Package_error of Yeokcham_v4_package.error
  | Bootstrap_error of Yeokcham_v4_bootstrap.error
  | Recovery_error of Yeokcham_v4_recovery.error
  | Transport_error of Yeokcham_v4_transport.error
  | Workspace_error of Yeokcham_v4_workspace.error
  | Workspace_refusal of Yeokcham_v4_workspace.refusal
  | Proposal_error of Yeokcham_v4_proposal.tree_error
  | Proposal_refused of Yeokcham_v4_proposal.refusal list
  | Stale_proposal of {
      decision : Yeokcham_v4_model.Decision_id.t;
      left : Yeokcham_v4_model.Revision_id.t;
      right : Yeokcham_v4_model.Revision_id.t;
      reason : proposal_staleness;
    }
  | Invalid_proposal_tree of string
  | Proposal_destination_inside_worktree of string
  | Invalid_checkpoint_id of string
  | Unknown_checkpoint of Yeokcham_v4_model.Snapshot_id.t
  | Unchanged_share of Yeokcham_v4_model.Snapshot_id.t
  | Unsigned_project

and proposal_staleness =
  | Decision_not_open
  | Candidate_not_in_decision of Yeokcham_v4_model.Revision_id.t

type status = {
  creator : Yeokcham_v4_model.Device_id.t;
  active_draft : Yeokcham_v4_model.draft;
  checkpoint : Yeokcham_v4_model.Snapshot_id.t;
  shared_changes : Yeokcham_v4_model.shared_change list;
  shared_change_count : int;
  open_decisions : Yeokcham_v4_model.decision list;
  deliveries : Yeokcham_v4_model.delivery list;
  delivery_count : int;
  checkpoints : Yeokcham_v4_model.checkpoint list;
  usernames : Yeokcham_v4_model.username_registration list;
  uncaptured : bool;
}

type inspection_state = {
  inspection_project : Yeokcham_v4_model.project;
  inspection_signed_revisions : Yeokcham_v4_trust.signed_revision list;
  inspection_authority : Yeokcham_v4_trust.authority option;
  inspection_review_publications : string list;
}
(** A read-only projection input loaded from the current V4 state. It neither
    scans nor materialises the working tree. Deferred review references are
    intentionally opaque publication IDs, not remote status. *)

type identity = {
  repository : Yeokcham_v4_trust.Repository_id.t;
  device : Yeokcham_v4_trust.device;
  role : Yeokcham_v4_trust.role;
}

type materialized_candidate = {
  revision : Yeokcham_v4_model.Revision_id.t;
  author : Yeokcham_v4_model.Device_id.t;
  username : Yeokcham_v4_model.Username.t option;
  directory : string;
}
(** A read-only candidate tree created for an open decision. [directory] is a
    generated child of the requested destination, not an identifier-derived
    path. *)

type decision_proposal = Yeokcham_v4_proposal.t
(** Ephemeral, parser-free side information for one pair in an open decision. It
    is never a project-state, resolution, or delivery record. *)

type semantic_advice =
  | Semantic_not_configured
  | Semantic_multiple_servers of string list
  | Semantic_report of Yeokcham_v4_lsp_sidecar.report
      (** Session-local external-tool observations. They are not a semantic
          merge, decision transition, or persistent sidecar. *)

type inspected_decision_proposal = {
  exact_proposal : decision_proposal;
  semantic_advice : semantic_advice;
}

type materialized_proposal = {
  materialized_proposal : decision_proposal;
  proposal_directory : string;
}
(** A ready proposal materialised directly into the supplied empty directory.
    This does not resolve the decision or rewrite the live working tree. *)

type snapshot_entry_kind = File | Directory

type snapshot_entry = {
  kind : snapshot_entry_kind;
  mode : Yeokcham_snapshot.file_mode option;
  content : string option;
}
(** A byte-safe description of one path in an exact snapshot. [content] is the
    canonical object identity of a file's bytes; it is absent for directories.
    No textual diff is attempted, so binary files remain inspectable. *)

type path_difference = {
  path : Yeokcham_v4_model.Path.t;
  before : snapshot_entry option;
  after : snapshot_entry option;
}

type working_tree_comparison = {
  saved_checkpoint : Yeokcham_v4_model.Snapshot_id.t;
  observed_snapshot : Yeokcham_v4_model.Snapshot_id.t;
  differences : path_difference list;
}
(** An exact comparison of the active draft's latest saved checkpoint against
    one current working-tree scan. The scan uses the same `.yeokcham` and `.git`
    exclusion boundary as [status]. It may store immutable unreferenced scan
    objects, but it never saves, changes the state head, writes source, signs,
    shares, resolves, delivers, imports, or contacts a relay. *)

type comparison_target =
  | Baseline
  | Candidate of Yeokcham_v4_model.Revision_id.t

type decision_comparison = {
  compared_decision : Yeokcham_v4_model.decision;
  compared_candidate : Yeokcham_v4_model.change_revision;
  against : Yeokcham_v4_model.Snapshot_id.t;
  differences : path_difference list;
}
(** An entirely read-only comparison between an open decision candidate and
    either the current projection baseline or another candidate in the same
    decision. *)

type inspected_candidate = {
  inspected_revision : Yeokcham_v4_model.change_revision;
  inspected_username : Yeokcham_v4_model.Username.t option;
}

type decision_inspection = {
  inspected_decision : Yeokcham_v4_model.decision;
  inspected_candidates : inspected_candidate list;
}

type package_review = {
  review_revision : Yeokcham_v4_model.Revision_id.t;
  review_author : Yeokcham_v4_model.Device_id.t;
  requires_adoption : bool;
}
(** Public, read-only package review data. A positive [requires_adoption] means
    a current authority head has revoked the historical signer, so this exact
    signed record cannot be received without an administrator's later adoption.
*)

type save_outcome = Unchanged of status | Saved of status

type compact_report = {
  kept : Yeokcham_v4_model.compact_keep list;
  dropped : Yeokcham_v4_model.Snapshot_id.t list;
  pruned_journals : string list;
  status : status;
}

type restore_proof = {
  proof_operation : string;
  proof_safety : Yeokcham_v4_model.Snapshot_id.t;
  proof_target : Yeokcham_v4_model.Snapshot_id.t;
}

type storage_root = {
  root_snapshot : Yeokcham_v4_model.Snapshot_id.t;
  root_reasons : Yeokcham_v4_model.protection_reason list;
}

type transport_arrival = {
  publication : Yeokcham_v4_transport.publication;
  package : string;
}

type transport_receive = {
  discovered_publications : int;
  received_revisions : int;
  deferred_publications : int;
  created_decisions : int;
  transport_status : status;
}

type transport_outbound = {
  outbound_publication : Yeokcham_v4_transport.publication;
  outbound_artifact : Yeokcham_v4_package.artifact;
  outbound_revisions : Yeokcham_v4_model.Revision_id.t list;
}

type bootstrap_outbound = {
  bootstrap_basis : Yeokcham_v4_bootstrap.basis;
  bootstrap_artifact : Yeokcham_v4_package.artifact;
}

module Capture_window : sig
  type t

  val empty : t
  val quiet_seconds : float
  val max_seconds : float
  val observe : t -> now:float -> t
  val due : t -> now:float -> bool
  val timeout : t -> now:float -> float
  val clear : t
end

type in_place_restore = {
  restore_operation : string;
  safety_checkpoint : Yeokcham_v4_model.Snapshot_id.t;
  restored_checkpoint : Yeokcham_v4_model.Snapshot_id.t;
  resumed : bool;
}

type workspace_materialization = {
  workspace_basis : Yeokcham_v4_workspace.projection_basis;
  workspace_receipt : Yeokcham_v4_workspace.workspace_projection_receipt;
  workspace_safety_checkpoint : Yeokcham_v4_model.Snapshot_id.t option;
  workspace_restore_proof : string option;
}
(** The local receipt and, when exact replacement was necessary, the durable
    safety checkpoint/proof created before ordinary source bytes changed. *)

type workspace_update =
  | Workspace_already_current of
      Yeokcham_v4_workspace.workspace_projection_receipt
  | Workspace_updated of workspace_materialization

val error_to_string : error -> string
val recovery_package_path : string -> string

val init :
  root:string ->
  creator:Yeokcham_v4_model.Device_id.t ->
  username:Yeokcham_v4_model.Username.t ->
  initial_draft:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  (status, error) result

val init_signed :
  root:string ->
  username:Yeokcham_v4_model.Username.t ->
  initial_draft:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  repository:Yeokcham_v4_trust.Repository_id.t ->
  device:Yeokcham_v4_trust.device ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** Initializes a collaboration-capable V4 state. [device] is the initial
    administrator and [signing_capability] is supplied by an external local
    signer provider; it is never persisted by this module. *)

val init_signed_with_recovery :
  root:string ->
  username:Yeokcham_v4_model.Username.t ->
  initial_draft:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  repository:Yeokcham_v4_trust.Repository_id.t ->
  device:Yeokcham_v4_trust.device ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  recovery_device:Yeokcham_v4_trust.device ->
  recovery_capability:Yeokcham_v4_trust.signing_capability ->
  (status * Yeokcham_v4_recovery.ceremony, error) result
(** Creates the root authority epoch and its initial encrypted recovery package
    before publishing the first V4 state. The caller must present the returned
    24-word mnemonic to the user exactly once and persist or export the package
    through an explicit adapter. *)

val init_collaboration :
  root:string ->
  username:Yeokcham_v4_model.Username.t ->
  initial_draft:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  device:Yeokcham_v4_trust.device ->
  membership:Yeokcham_v4_trust.membership ->
  local_certificate:string ->
  (status, error) result
(** Initializes an already enrolled device from public collaboration state. The
    caller keeps the corresponding private signing capability outside V4 project
    objects. *)

val init_authority_collaboration :
  root:string ->
  username:Yeokcham_v4_model.Username.t ->
  initial_draft:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  device:Yeokcham_v4_trust.device ->
  authority:Yeokcham_v4_trust.authority ->
  local_certificate:string ->
  (status, error) result
(** Initializes an already-enrolled device using a verified V4 authority
    closure. It is intended for a peer that has compared the root phrase and
    obtained the public enrollment closure out of band. *)

val bootstrap_from_package :
  root:string ->
  repository:Yeokcham_v4_trust.Repository_id.t ->
  package:string ->
  basis:string ->
  verify_phrase:string ->
  username:Yeokcham_v4_model.Username.t ->
  initial_draft:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  device:Yeokcham_v4_trust.device ->
  local_certificate:string ->
  (status, error) result
(** Verifies an immutable bootstrap basis and creates a fresh local V4 state. It
    never scans or materializes the working tree. The root phrase is checked
    before any destination object or state is created. *)

val save : root:string -> (save_outcome, error) result
val status : root:string -> (status, error) result
val inspection_state : root:string -> (inspection_state, error) result
val identity : root:string -> (identity, error) result

val register_username :
  root:string ->
  device:Yeokcham_v4_model.Device_id.t ->
  username:Yeokcham_v4_model.Username.t ->
  (status, error) result

val enroll_device :
  parent:string option ->
  root:string ->
  subject:Yeokcham_v4_trust.device ->
  role:Yeokcham_v4_trust.role ->
  username:Yeokcham_v4_model.Username.t ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** An already authorized administrator enrols [subject]. On an authority fork,
    [parent] must name the single current head this branch-local action
    advances. The username is only local display registration made alongside,
    never certificate data. *)

val revoke_device :
  parent:string option ->
  root:string ->
  device:Yeokcham_v4_model.Device_id.t ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** Advances one authority head. On a fork, [parent] must explicitly name that
    current head. Historical records remain verifiable; new records by the
    revoked device do not. A local device must use rotation rather than revoking
    itself. *)

val rotate_local_device :
  parent:string option ->
  root:string ->
  replacement:Yeokcham_v4_trust.device ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** Atomically enrolls [replacement], revokes the current local device, and
    changes the local certificate in one selected branch. On a fork, [parent]
    must name that current head. The replacement private key must already be in
    the platform signer. *)

val reconcile_authority :
  root:string ->
  parents:string list ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** Explicitly creates a multi-parent authority successor. [parents] must be a
    strictly sorted, duplicate-free list of at least two current heads. It
    leaves every unselected concurrent head active. The local device must be an
    administrator active in every named parent. *)

val recover_authority :
  root:string ->
  package:string ->
  mnemonic:string ->
  output:string ->
  replacement:Yeokcham_v4_trust.device ->
  replaced:Yeokcham_v4_model.Device_id.t ->
  (status * Yeokcham_v4_recovery.ceremony, error) result
(** Uses an encrypted recovery package to enroll [replacement] as an
    administrator, revoke [replaced], and rotate recovery material in one
    recovery successor epoch. [output] is written exclusively before the state
    head advances; callers must store the returned mnemonic offline. *)

val refresh_recovery_package :
  root:string ->
  package:string ->
  mnemonic:string ->
  output:string ->
  (unit, error) result
(** Produces an additional, exclusively-created encrypted recovery package for
    the current authority closure without rotating identity or authority. The
    existing 24-word mnemonic is required and remains unchanged. *)

val authority_heads : root:string -> (string list, error) result

val review_package :
  root:string -> package:string -> (package_review list, error) result
(** Verifies a V2 package manifest and reports its signed records without
    importing objects or modifying the model or working tree. *)

val adopt_package_revision :
  authority_epoch:string option ->
  root:string ->
  package:string ->
  revision:Yeokcham_v4_model.Revision_id.t ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** Records a current-head administrator's one-time adoption for one exact,
    currently review-required package record. On an authority fork,
    [authority_epoch] must select the current head issuing the adoption. The
    record and authority closure are persisted, but package objects and model
    revisions are not imported; call [receive_package] afterwards. *)

val restore :
  root:string ->
  checkpoint:Yeokcham_v4_model.Snapshot_id.t ->
  destination:string ->
  (unit, error) result

val restore_in_place :
  root:string ->
  checkpoint:Yeokcham_v4_model.Snapshot_id.t ->
  (in_place_restore, error) result

val workspace_activate :
  root:string -> (workspace_materialization, error) result
(** Explicitly materialises the verified imported projection into a root that
    has no ordinary source entries. Bootstrap, receive, sync, and daemon paths
    never call this operation. *)

val workspace_update :
  root:string -> replace:bool -> (workspace_update, error) result
(** Explicitly refreshes an activated workspace. Without [replace], an exact
    tree mismatch is a [Dirty_workspace] refusal. [replace] retains a safety
    checkpoint and proof before it changes ordinary source bytes. *)

val recover_in_place : root:string -> (in_place_restore option, error) result

val restore_proofs : root:string -> (restore_proof list, error) result
(** Lists local durable recovery records without touching the working tree. *)

val retain_restore_proof :
  root:string -> operation:string -> (restore_proof, error) result
(** Explicitly creates a durable proof for a legacy published journal after
    validating its two exact snapshot closures. *)

val forget_restore_proof :
  root:string -> operation:string -> (unit, error) result
(** The sole operation that removes a restore's durable compaction root. *)

val storage_roots : root:string -> (storage_root list, error) result
(** Validates and explains every non-recent compaction root. *)

val pin :
  root:string ->
  checkpoint:Yeokcham_v4_model.Snapshot_id.t ->
  (status, error) result

val unpin :
  root:string ->
  checkpoint:Yeokcham_v4_model.Snapshot_id.t ->
  (status, error) result

val compact :
  root:string ->
  keep_recent:int ->
  dry_run:bool ->
  (compact_report, error) result

val new_draft :
  root:string ->
  id:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  (status, error) result

val share :
  root:string ->
  change:Yeokcham_v4_model.Change_id.t ->
  revision:Yeokcham_v4_model.Revision_id.t ->
  (status, error) result

val share_signed :
  authority_epoch:string option ->
  root:string ->
  change:Yeokcham_v4_model.Change_id.t ->
  revision:Yeokcham_v4_model.Revision_id.t ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** When authority has multiple current heads, [authority_epoch] must select the
    current head recorded in the revision signature. *)

val withdraw :
  root:string -> change:Yeokcham_v4_model.Change_id.t -> (status, error) result

val resolve :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  change:Yeokcham_v4_model.Change_id.t ->
  revision:Yeokcham_v4_model.Revision_id.t ->
  tree:string option ->
  (status, error) result

val resolve_signed :
  authority_epoch:string option ->
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  change:Yeokcham_v4_model.Change_id.t ->
  revision:Yeokcham_v4_model.Revision_id.t ->
  tree:string option ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (status, error) result
(** When authority has multiple current heads, [authority_epoch] must select the
    current head recorded in the resolution signature. *)

val create_package : root:string -> destination:string -> (unit, error) result

val receive_package : root:string -> package:string -> (status, error) result
(** Imports only verified immutable objects and then atomically advances the
    collaborative V4 state. It does not materialize or otherwise touch the
    working tree. *)

val receive_transport_batch :
  root:string ->
  remote:string ->
  cursor:string option ->
  transport_arrival list ->
  (transport_receive, error) result
(** Receives a fully fetched relay batch. Every publication/feed/package is
    validated before any immutable destination object or state update. This
    adapter has no network I/O and never mutates the working tree. *)

val prepare_transport_outbound :
  root:string ->
  remote:string ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (transport_outbound option, error) result
(** Builds a verified immutable package and its signed publication without
    changing local transport state. The caller uploads objects, then the
    manifest, then the publication; only an acknowledged publication may be
    recorded with [record_transport_outbound]. *)

val prepare_bootstrap_outbound :
  root:string ->
  signing_capability:Yeokcham_v4_trust.signing_capability ->
  (bootstrap_outbound, error) result
(** Produces a signed immutable bootstrap basis with the complete verified
    shared-history closure. It has no working-tree effect. *)

val record_transport_outbound :
  root:string ->
  remote:string ->
  publication:Yeokcham_v4_transport.publication ->
  revisions:Yeokcham_v4_model.Revision_id.t list ->
  (unit, error) result
(** Atomically records a relay-acknowledged publication and its announced
    revision identities with the V4 collaborative state. *)

val transport_cursor :
  root:string -> remote:string -> (string option, error) result
(** Returns the last fully received publication cursor for a local remote. *)

val open_decision :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  (Yeokcham_v4_model.decision, error) result

val materialize_decision :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  destination:string ->
  (materialized_candidate list, error) result

val proposal_pairs :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  ( (Yeokcham_v4_model.Revision_id.t * Yeokcham_v4_model.Revision_id.t) list,
    error )
  result
(** Lists canonical revision pairs in a currently open decision. It performs no
    snapshot comparison and changes no state. *)

val propose_decision :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  left:Yeokcham_v4_model.Revision_id.t ->
  right:Yeokcham_v4_model.Revision_id.t ->
  (decision_proposal, error) result
(** Recomputes one exact proposal from the current open decision. A returned
    proposal may be refused; refusal is inspectable side information, not an
    error or a durable rejection. *)

val inspect_decision_proposal :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  left:Yeokcham_v4_model.Revision_id.t ->
  right:Yeokcham_v4_model.Revision_id.t ->
  semantic_server:string option ->
  (inspected_decision_proposal, error) result
(** Recomputes the ordinary byte-exact proposal and, only when exactly one
    configured server matches or [semantic_server] explicitly selects one,
    obtains a bounded session-local LSP report from disposable snapshots. A
    missing, malformed, or failing server leaves the exact proposal usable. *)

val materialize_decision_proposal :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  left:Yeokcham_v4_model.Revision_id.t ->
  right:Yeokcham_v4_model.Revision_id.t ->
  destination:string ->
  (materialized_proposal, error) result
(** Recomputes and revalidates a ready exact proposal, then writes it only to an
    empty supplied destination. It never resolves the decision, records proposal
    acceptance, or writes the working tree. *)

val inspect_decision :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  (decision_inspection, error) result

val compare_decision :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  candidate:Yeokcham_v4_model.Revision_id.t ->
  against:comparison_target ->
  (decision_comparison, error) result

val inspect_working_tree :
  root:string -> (working_tree_comparison, error) result

val deliver :
  root:string ->
  id:Yeokcham_v4_model.Delivery_id.t ->
  next_draft:Yeokcham_v4_model.Draft_id.t ->
  next_title:string ->
  (status, error) result
