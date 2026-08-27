(** Local V4 saved-work transitions.

    This adapter has no transport or semantic merge behaviour. Command `status`
    and `save` scan exact snapshots when invoked. Linux `watch` lives in the CLI
    and only calls `save` after debounce; it is not part of this module. *)

type error =
  | Store_error of Yeokcham_v4_store.error
  | Snapshot_error of Yeokcham_snapshot.error
  | Materialize_error of Yeokcham_snapshot.Materialize.error
  | Restore_journal_error of Yeokcham_v4_restore_journal.error
  | Model_error of Yeokcham_v4_model.error
  | Invalid_checkpoint_id of string
  | Unknown_checkpoint of Yeokcham_v4_model.Snapshot_id.t
  | Unchanged_share of Yeokcham_v4_model.Snapshot_id.t

type status = {
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

type materialized_candidate = {
  revision : Yeokcham_v4_model.Revision_id.t;
  author : Yeokcham_v4_model.Device_id.t;
  username : Yeokcham_v4_model.Username.t option;
  directory : string;
}
(** A read-only candidate tree created for an open decision. [directory] is a
    generated child of the requested destination, not an identifier-derived
    path. *)

type save_outcome = Unchanged of status | Saved of status

type compact_report = {
  kept : Yeokcham_v4_model.compact_keep list;
  dropped : Yeokcham_v4_model.Snapshot_id.t list;
  pruned_journals : string list;
  status : status;
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
  safety_checkpoint : Yeokcham_v4_model.Snapshot_id.t;
  restored_checkpoint : Yeokcham_v4_model.Snapshot_id.t;
  resumed : bool;
}

val error_to_string : error -> string

val init :
  root:string ->
  creator:Yeokcham_v4_model.Device_id.t ->
  username:Yeokcham_v4_model.Username.t ->
  initial_draft:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  (status, error) result

val save : root:string -> (save_outcome, error) result
val status : root:string -> (status, error) result

val register_username :
  root:string ->
  device:Yeokcham_v4_model.Device_id.t ->
  username:Yeokcham_v4_model.Username.t ->
  (status, error) result

val restore :
  root:string ->
  checkpoint:Yeokcham_v4_model.Snapshot_id.t ->
  destination:string ->
  (unit, error) result

val restore_in_place :
  root:string ->
  checkpoint:Yeokcham_v4_model.Snapshot_id.t ->
  (in_place_restore, error) result

val recover_in_place : root:string -> (in_place_restore option, error) result

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

val withdraw :
  root:string -> change:Yeokcham_v4_model.Change_id.t -> (status, error) result

val resolve :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  change:Yeokcham_v4_model.Change_id.t ->
  revision:Yeokcham_v4_model.Revision_id.t ->
  tree:string option ->
  (status, error) result

val open_decision :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  (Yeokcham_v4_model.decision, error) result

val materialize_decision :
  root:string ->
  decision:Yeokcham_v4_model.Decision_id.t ->
  destination:string ->
  (materialized_candidate list, error) result

val deliver :
  root:string ->
  id:Yeokcham_v4_model.Delivery_id.t ->
  next_draft:Yeokcham_v4_model.Draft_id.t ->
  next_title:string ->
  (status, error) result
