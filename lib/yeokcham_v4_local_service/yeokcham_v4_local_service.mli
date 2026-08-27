(** Local V4 saved-work transitions.

    This adapter has no watcher, transport, or semantic merge behaviour. It
    scans exact snapshots only when a user invokes a command. *)

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
}

type save_outcome = Unchanged of status | Saved of status

type in_place_restore = {
  safety_checkpoint : Yeokcham_v4_model.Snapshot_id.t;
  restored_checkpoint : Yeokcham_v4_model.Snapshot_id.t;
  resumed : bool;
}

val error_to_string : error -> string

val init :
  root:string ->
  creator:Yeokcham_v4_model.Device_id.t ->
  initial_draft:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  (status, error) result

val save : root:string -> (save_outcome, error) result
val status : root:string -> (status, error) result

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
  (status, error) result

val deliver :
  root:string ->
  id:Yeokcham_v4_model.Delivery_id.t ->
  next_draft:Yeokcham_v4_model.Draft_id.t ->
  next_title:string ->
  (status, error) result
