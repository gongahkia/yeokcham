(** Pure V4 product transitions.

    This module deliberately models the user-visible V4 concepts without a
    filesystem, storage engine, clock, random source, signature implementation,
    or transport. Adapters provide those effects after these transitions have
    been verified. *)

type error =
  | Empty_identifier of string
  | Invalid_identifier of string
  | Empty_path
  | Unsafe_path_component of string
  | Invalid_span of { start_byte : int; end_byte : int }
  | Empty_edits
  | Empty_title
  | Invalid_project_state of string
  | Duplicate_draft
  | Duplicate_change
  | Duplicate_revision
  | Duplicate_delivery
  | Unknown_change
  | Unknown_decision
  | Decision_already_resolved
  | Unknown_revision
  | Active_draft_already_shared
  | Active_draft_not_shared
  | Revision_change_mismatch
  | Revision_author_mismatch
  | Revision_parent_mismatch
  | Initial_revision_has_parent
  | Received_revision_missing_parent
  | Resolution_base_mismatch
  | Active_change_withdrawal
  | Delivery_has_open_decisions
  | Delivery_includes_unknown_revision
  | Delivery_includes_duplicate_revision
  | Delivery_omits_active_change
  | Delivery_requires_shared_active_draft
  | Unknown_checkpoint
  | Not_pinned
  | Invalid_keep_recent

val error_to_string : error -> string

module type Identifier = sig
  type t

  val of_string : string -> (t, error) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module Snapshot_id : Identifier
module Draft_id : Identifier
module Change_id : Identifier
module Revision_id : Identifier
module Decision_id : Identifier
module Delivery_id : Identifier
module Device_id : Identifier

module Path : sig
  type t

  val of_components : string list -> (t, error) result
  val components : t -> string list
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val is_ancestor : ancestor:t -> descendant:t -> bool
  val to_string : t -> string
end

type span = { start_byte : int; end_byte : int }

val make_span : start_byte:int -> end_byte:int -> (span, error) result

type edit_kind = Text of span | Whole_path
type edit = { edit_path : Path.t; edit_kind : edit_kind }

type change_revision = {
  change : Change_id.t;
  revision : Revision_id.t;
  parent : Revision_id.t option;
  revision_author : Device_id.t;
  base_snapshot : Snapshot_id.t;
  result_snapshot : Snapshot_id.t;
  edits : edit list;
}

val make_change_revision :
  change:Change_id.t ->
  revision:Revision_id.t ->
  parent:Revision_id.t option ->
  author:Device_id.t ->
  base:Snapshot_id.t ->
  result:Snapshot_id.t ->
  edits:edit list ->
  (change_revision, error) result

type draft_state = Active | Closed

type draft = {
  draft_id : Draft_id.t;
  title : string;
  state : draft_state;
  latest_checkpoint : Snapshot_id.t;
  shared_change : Change_id.t option;
}

type checkpoint = { checkpoint_snapshot : Snapshot_id.t }

type shared_change = {
  change_id : Change_id.t;
  source_draft : Draft_id.t option;
  change_author : Device_id.t;
  revisions : change_revision list;
  withdrawn : bool;
}

type decision_kind = Stale_base | Edit_overlap

type edit_reference = {
  referenced_revision : Revision_id.t;
  referenced_edit_index : int;
}

type edit_candidate = {
  candidate_revision : change_revision;
  candidate_edit_index : int;
  candidate_edit : edit;
}

type decision = {
  decision_id : Decision_id.t;
  decision_kind : decision_kind;
  decision_paths : Path.t list;
  candidates : edit_candidate list;
}

type projection = {
  projection_baseline : Snapshot_id.t;
  applied : change_revision list;
  applied_edits : edit_candidate list;
  decisions : decision list;
}

type delivery = {
  delivery_id : Delivery_id.t;
  delivery_author : Device_id.t;
  delivery_snapshot : Snapshot_id.t;
  included : Revision_id.t list;
  created_at : int64;
}

type resolution = {
  resolved_decision : Decision_id.t;
  suppressed_edits : edit_reference list;
  replacement_revision : change_revision;
}

type state = {
  state_creator : Device_id.t;
  state_baseline : Snapshot_id.t;
  state_active_draft : Draft_id.t;
  state_drafts : draft list;
  state_checkpoints : checkpoint list;
  state_changes : shared_change list;
  state_resolutions : resolution list;
  state_deliveries : delivery list;
  state_pins : Snapshot_id.t list;
}

type project

val init :
  creator:Device_id.t ->
  initial_snapshot:Snapshot_id.t ->
  initial_draft:Draft_id.t ->
  title:string ->
  project

val creator : project -> Device_id.t
val active_draft : project -> draft
val drafts : project -> draft list
val checkpoints : project -> checkpoint list
val pins : project -> Snapshot_id.t list
val shared_changes : project -> shared_change list
val resolutions : project -> resolution list
val deliveries : project -> delivery list
val projection : project -> projection
val export : project -> state
val import : state -> (project, error) result
val checkpoint : project -> snapshot:Snapshot_id.t -> project
val pin : project -> snapshot:Snapshot_id.t -> (project, error) result
val unpin : project -> snapshot:Snapshot_id.t -> (project, error) result

type protection_reason =
  | Baseline
  | Draft
  | Shared_revision
  | Delivery
  | Resolution
  | Open_decision
  | Pin
  | Restore_journal
  | Recent

val protection_reason_to_string : protection_reason -> string

type compact_keep = {
  snapshot : Snapshot_id.t;
  reasons : protection_reason list;
}

type compact_result = {
  project : project;
  kept : compact_keep list;
  dropped : Snapshot_id.t list;
}

val default_keep_recent : int

val compact :
  project ->
  keep_recent:int ->
  journal_snapshots:Snapshot_id.t list ->
  (compact_result, error) result

val new_draft :
  project -> id:Draft_id.t -> title:string -> (project, error) result

val share_active : project -> change_revision -> (project, error) result
val amend_active : project -> change_revision -> (project, error) result
val receive : project -> change_revision -> (project, error) result
val withdraw : project -> change:Change_id.t -> (project, error) result

val resolve :
  project ->
  decision:Decision_id.t ->
  replacement:change_revision ->
  (project, error) result

val deliver :
  project ->
  id:Delivery_id.t ->
  author:Device_id.t ->
  snapshot:Snapshot_id.t ->
  included:Revision_id.t list ->
  next_draft:Draft_id.t ->
  next_title:string ->
  created_at:int64 ->
  (project, error) result
