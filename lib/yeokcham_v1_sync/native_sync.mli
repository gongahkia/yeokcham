module Core = Yeokcham_v1_model.Core

type upload =
  | No_outgoing
  | Acknowledged of {
      publication : string;
      manifest : string;
      objects_offered : int;
      reused : bool;
    }
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
  | Authority_error of string
  | Invalid of string

val error_to_string : error -> string

val run :
  root:string ->
  remote:string ->
  load_signing_capability:
    (Yeokcham_v1_model.Device_id.t ->
    (Yeokcham_v1_trust.signing_capability, string) result) ->
  (report, error) result
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
  val collect_publications :
    max_bytes:int ->
    fetch:(string -> (Yeokcham_v1_transport.publication, error) result) ->
    known:string list ->
    string list ->
    (Yeokcham_v1_transport.publication list, error) result

  val run :
    observe:(boundary -> unit) ->
    root:string ->
    remote:string ->
    load_signing_capability:
      (Yeokcham_v1_model.Device_id.t ->
      (Yeokcham_v1_trust.signing_capability, string) result) ->
    (report, error) result
end

module Fetch : sig
  val publications :
    known:string list ->
    Yeokcham_v1_transport_http.client ->
    string ->
    string list ->
    (Yeokcham_v1_transport.publication list, error) result

  val inventory :
    Yeokcham_v1_transport_http.client -> string -> (string list, error) result

  val publication :
    Yeokcham_v1_transport_http.client ->
    string ->
    string ->
    (Yeokcham_v1_transport.publication, error) result

  val order_feed :
    known:Yeokcham_v1_transport.publication_reference list ->
    Yeokcham_v1_transport.publication list ->
    (Yeokcham_v1_transport.publication list, error) result

  val with_core :
    root:string ->
    client:Yeokcham_v1_transport_http.client ->
    repository:Core.Repository_id.t ->
    source:Yeokcham_store.repository ->
    known_authority:Yeokcham_v1_trust.authority option ->
    reusable:Yeokcham_store.Stored_object_id.t list ->
    check_authority:(Yeokcham_v1_trust.authority -> (unit, error) result) ->
    manifest:string ->
    (package:string -> Yeokcham_v1_package.Core.prepared -> ('a, error) result) ->
    ('a, error) result
  (** Owned temporary package lifetime. Only already verified public IDs may be
      supplied as reusable. No workspace, history, mutable head or files move.
  *)
end
