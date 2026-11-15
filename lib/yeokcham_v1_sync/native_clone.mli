module Core = Yeokcham_v1_model.Core

type source = private { url : string; repository : Core.Repository_id.t }

type error =
  | Invalid of string
  | Blocked of string
  | Choice of string
  | Exchange_error of Native_sync.error
  | Store_error of Yeokcham_v1_store.error
  | Integration_error of Yeokcham_v1_local_service.Integrate.error

val error_to_string : error -> string
val source : string -> (source, error) result
val default_directory : source -> string
val check_new_destination : string -> (string, error) result

type outcome = {
  root : string;
  request : string;
  repository : Core.Repository_id.t;
  branch : Core.Branch_id.t;
  accepted : Core.Record_id.t;
  snapshot : Core.Object_id.t;
  records : int;
  branches : int;
  preview : bool;
  resumed : bool;
  cursor : Core.History_id.t option;
  operation : Core.Operation_id.t option;
  uncaptured : bool option;
}

val run :
  source:source ->
  destination:string ->
  branch:string ->
  token:string ->
  signing_capability:Yeokcham_v1_trust.signing_capability ->
  verify_phrase:string ->
  expected_request:Core.Digest.t option ->
  preview:bool ->
  (outcome, error) result

val resume : root:string -> (outcome, error) result
(** Uses the already verified local closure and recorded intent; no network or
    signing provider is required. A recovered operation is never restarted. *)

type boundary =
  | Object_requested of Yeokcham_store.Stored_object_id.t
  | Verified
  | Before_metadata_attach
  | After_metadata_attach
  | Before_plan_bind
  | After_plan_bind
  | Application of Yeokcham_v1_local_service.Integrate.boundary
  | Before_complete
  | After_complete

module For_test : sig
  val run :
    observe:(boundary -> unit) ->
    source:source ->
    destination:string ->
    branch:string ->
    token:string ->
    signing_capability:Yeokcham_v1_trust.signing_capability ->
    verify_phrase:string ->
    expected_request:Core.Digest.t option ->
    preview:bool ->
    (outcome, error) result

  val resume :
    observe:(boundary -> unit) -> root:string -> (outcome, error) result
end
