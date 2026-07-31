module Capsule_store = Paengi_capsule_store
module Validation = Paengi_validation
module Workspace_store = Paengi_workspace_store

type attempt_link = {
  attempt_id : Paengi_id.Workspace_attempt_id.t;
  attempt_object_id : Paengi_store.Stored_object_id.t;
}

type evidence_link = {
  evidence_id : Paengi_id.Validation_id.t;
  evidence_object_id : Paengi_store.Stored_object_id.t;
}

type release
type binding

type error

val error_to_string : error -> string

val create_release :
  parents:Paengi_id.Release_id.t list ->
  workspace:Paengi_id.Workspace_id.t ->
  workspace_revision:Paengi_id.Workspace_revision_id.t ->
  workspace_revision_object:Paengi_store.Stored_object_id.t ->
  attempt:attempt_link option ->
  base:Paengi_snapshot.Snapshot.id ->
  capsules:Capsule_store.revision_link list ->
  resolutions:Workspace_store.resolution_binding list ->
  final_snapshot:Paengi_snapshot.Snapshot.id ->
  evidence:evidence_link list ->
  message:string option ->
  created_at:int64 ->
  (release, error) result

val release_id : release -> Paengi_id.Release_id.t
val release_parents : release -> Paengi_id.Release_id.t list
val release_workspace : release -> Paengi_id.Workspace_id.t
val release_workspace_revision : release -> Paengi_id.Workspace_revision_id.t
val release_workspace_revision_object : release -> Paengi_store.Stored_object_id.t
val release_attempt : release -> attempt_link option
val release_base : release -> Paengi_snapshot.Snapshot.id
val release_capsules : release -> Capsule_store.revision_link list
val release_resolutions : release -> Workspace_store.resolution_binding list
val release_final_snapshot : release -> Paengi_snapshot.Snapshot.id
val release_evidence : release -> evidence_link list
val release_message : release -> string option
val release_created_at : release -> int64

val release_payload : release -> (Paengi_encoding.t, error) result
val decode_release_payload : Paengi_encoding.t -> (release, error) result
val store_release :
  Paengi_store.repository -> release -> (Paengi_store.Stored_object_id.t, error) result
val load_release :
  Paengi_store.repository -> Paengi_store.Stored_object_id.t -> (release, error) result

val binding_release : binding -> Paengi_id.Release_id.t
val binding_object : binding -> Paengi_store.Stored_object_id.t
val encode_binding : binding -> string
val decode_binding : string -> (binding, error) result
val binding_components : Paengi_id.Release_id.t -> string list

module Parent_resolver : sig
  type t = Paengi_id.Release_id.t -> (Paengi_id.Release_id.t list, string) result

  val verify_acyclic : t -> Paengi_id.Release_id.t -> (unit, string) result

  val contains :
    t ->
    base:Paengi_id.Release_id.t ->
    required:Paengi_id.Release_id.t ->
    (bool, string) result
end

module Durable : sig
  type failure_point = Before_release_binding

  val read :
    Paengi_store.repository -> Paengi_id.Release_id.t -> (release, error) result

  val list : Paengi_store.repository -> (release list, error) result

  val verify :
    Paengi_store.repository -> Paengi_id.Release_id.t -> (release, error) result

  val create :
    ?runner:(module Validation.Process_runner) ->
    store:Paengi_store.repository ->
    workspace:Paengi_id.Workspace_id.t ->
    parents:Paengi_id.Release_id.t list ->
    commands:Validation.command list ->
    message:string option ->
    observed_at:int64 ->
    created_at:int64 ->
    ?fail_at:failure_point ->
    unit ->
    (release, error) result
end
