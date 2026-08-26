(** Local V4 saved-work transitions.

    This adapter has no watcher, transport, or semantic merge behaviour. It
    scans exact snapshots only when a user invokes a command. *)

type error =
  | Store_error of Yeokcham_v4_store.error
  | Snapshot_error of Yeokcham_snapshot.error
  | Model_error of Yeokcham_v4_model.error

type save_outcome = Unchanged of status | Saved of status

and status = {
  active_draft : Yeokcham_v4_model.draft;
  checkpoint : Yeokcham_v4_model.Snapshot_id.t;
  shared_change_count : int;
  open_decisions : Yeokcham_v4_model.decision list;
  delivery_count : int;
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

val new_draft :
  root:string ->
  id:Yeokcham_v4_model.Draft_id.t ->
  title:string ->
  (status, error) result
