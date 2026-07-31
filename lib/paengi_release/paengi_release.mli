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
type attestation

module type Signer = sig
  val signer_identity : string
  val algorithm : string
  val sign : Paengi_id.Release_id.t -> string
end

module Deterministic_test_signer : Signer

type error =
  | Store_error of Paengi_store.error
  | Envelope_error of Paengi_envelope.creation_error
  | Encoding_error of Paengi_encoding.construction_error
  | Decode_error of string
  | Unsupported_schema_version of int64
  | Unexpected_object_type of {
      expected : Paengi_envelope.object_type;
      actual : Paengi_envelope.object_type;
    }
  | Invalid_identity_length of { kind : string; length : int }
  | Invalid_release of string
  | Logical_identity_mismatch
  | Invalid_binding_checksum
  | Invalid_attestation of string
  | Release_missing of Paengi_id.Release_id.t
  | Binding_release_mismatch
  | Conflicting_release_id_reuse of Paengi_id.Release_id.t
  | Workspace_error of Paengi_workspace_store.error
  | Validation_error of Paengi_validation.error
  | Snapshot_error of Paengi_snapshot.error
  | Workspace_attempt_missing of Paengi_id.Workspace_id.t
  | Unresolved_conflicts of Paengi_id.Workspace_attempt_id.t
  | Required_validation_failed of Paengi_id.Validation_id.t
  | Release_reproduction_mismatch
  | Parent_error of string
  | Injected_interruption of string

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

val release_workspace_revision_object :
  release -> Paengi_store.Stored_object_id.t

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
  Paengi_store.repository ->
  release ->
  (Paengi_store.Stored_object_id.t, error) result

val load_release :
  Paengi_store.repository ->
  Paengi_store.Stored_object_id.t ->
  (release, error) result

val binding_release : binding -> Paengi_id.Release_id.t
val binding_object : binding -> Paengi_store.Stored_object_id.t

val make_binding :
  release:Paengi_id.Release_id.t ->
  object_id:Paengi_store.Stored_object_id.t ->
  binding

val encode_binding : binding -> string
val decode_binding : string -> (binding, error) result
val binding_components : Paengi_id.Release_id.t -> string list
val publish_binding : Paengi_store.repository -> binding -> (unit, error) result

val create_attestation :
  release:Paengi_id.Release_id.t ->
  signer_identity:string ->
  algorithm:string ->
  signature:string ->
  signed_at:int64 ->
  (attestation, error) result

val attest :
  signer:(module Signer) ->
  release:Paengi_id.Release_id.t ->
  signed_at:int64 ->
  (attestation, error) result

val attestation_release : attestation -> Paengi_id.Release_id.t
val attestation_signer_identity : attestation -> string
val attestation_algorithm : attestation -> string
val attestation_signature : attestation -> string
val attestation_signed_at : attestation -> int64
val attestation_payload : attestation -> (Paengi_encoding.t, error) result

val decode_attestation_payload :
  Paengi_encoding.t -> (attestation, error) result

val store_attestation :
  Paengi_store.repository ->
  attestation ->
  (Paengi_store.Stored_object_id.t, error) result

val load_attestation :
  Paengi_store.repository ->
  Paengi_store.Stored_object_id.t ->
  (attestation, error) result

module Parent_resolver : sig
  type t =
    Paengi_id.Release_id.t -> (Paengi_id.Release_id.t list, string) result

  val verify_acyclic : t -> Paengi_id.Release_id.t -> (unit, string) result

  val contains :
    t ->
    base:Paengi_id.Release_id.t ->
    required:Paengi_id.Release_id.t ->
    (bool, string) result
end

module Requires_release : sig
  val satisfied :
    Parent_resolver.t ->
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
