module Core = Yeokcham_v1_model.Core

type upload =
  | No_outgoing
  | Acknowledged of { publication : string; manifest : string; objects_offered : int; reused : bool }
  | Pending of string

type report = {
  remote_publications : int;
  received_publications : int;
  received_records : int;
  received_branches : int;
  legacy_received_revisions : int;
  local_shared_records : int;
  selected_branch : Core.Branch_id.t;
  working_basis : Core.Record_id.t;
  cursor : Core.History_id.t;
  upload : upload;
}

type error =
  | Http_error of Yeokcham_v1_transport_http.error
  | Package_error of Yeokcham_v1_package.error
  | Receipt_error of Yeokcham_v1_local_service.Core_receive.error
  | Outbound_error of Yeokcham_v1_local_service.Core_outbound.error
  | Service_error of Yeokcham_v1_local_service.error
  | Store_error of Yeokcham_v1_store.error
  | Raw_error of Yeokcham_store.error
  | Transport_error of Yeokcham_v1_transport.error
  | Invalid of string

val error_to_string : error -> string

val run :
  root:string -> remote:string ->
  load_signing_capability:(Yeokcham_v1_model.Device_id.t ->
    (Yeokcham_v1_trust.signing_capability, string) result) -> (report, error) result
(** Foreground native exchange. Rescans the bounded relay inventory, verifies
    complete incoming packages and persists receipt without moving files/cursor.
    Publishes a frozen outgoing batch and records its exact acknowledgement.
    Successful coverage describes locally known shared closure and the exposed
    relay inventory; it cannot prove a relay disclosed every remote record. *)

type boundary =
  | Object_offered of string
  | Manifest_sent of string
  | Courier_sent of string
  | Acknowledgement_recorded of string

module For_test : sig
  val run :
    observe:(boundary -> unit) -> root:string -> remote:string ->
    load_signing_capability:(Yeokcham_v1_model.Device_id.t ->
      (Yeokcham_v1_trust.signing_capability, string) result) -> (report, error) result
end
