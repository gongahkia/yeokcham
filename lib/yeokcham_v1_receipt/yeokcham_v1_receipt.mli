(** Verified V1 receipt boundary.

    This library intentionally has no dependency on snapshot capture or
    materialization. Its only effects are immutable object import and one
    collaborative state-head update after complete package/feed validation. *)

type error =
  | Store_error of Yeokcham_v1_store.error
  | Model_error of Yeokcham_v1_model.error
  | Trust_error of Yeokcham_v1_trust.error
  | Package_error of Yeokcham_v1_package.error
  | Transport_error of Yeokcham_v1_transport.error
  | Unsigned_project

type status = {
  creator : Yeokcham_v1_model.Device_id.t;
  active_draft : Yeokcham_v1_model.draft;
  checkpoint : Yeokcham_v1_model.Snapshot_id.t;
  shared_changes : Yeokcham_v1_model.shared_change list;
  shared_change_count : int;
  open_decisions : Yeokcham_v1_model.decision list;
  deliveries : Yeokcham_v1_model.delivery list;
  delivery_count : int;
  checkpoints : Yeokcham_v1_model.checkpoint list;
  usernames : Yeokcham_v1_model.username_registration list;
  uncaptured : bool;
}

type transport_arrival = {
  publication : Yeokcham_v1_transport.publication;
  package : string;
}

type transport_receive = {
  discovered_publications : int;
  received_revisions : int;
  deferred_publications : int;
  created_decisions : int;
  transport_status : status;
}

val error_to_string : error -> string
val receive_package : root:string -> package:string -> (status, error) result

val receive_transport_batch :
  root:string ->
  remote:string ->
  cursor:string option ->
  transport_arrival list ->
  (transport_receive, error) result
