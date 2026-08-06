module Capsule_store = Yeokcham_capsule_store
module Validation = Yeokcham_validation
module Workspace_store = Yeokcham_workspace_store

type attempt_link = {
  attempt_id : Yeokcham_id.Workspace_attempt_id.t;
  attempt_object_id : Yeokcham_store.Stored_object_id.t;
}

type evidence_link = {
  evidence_id : Yeokcham_id.Validation_id.t;
  evidence_object_id : Yeokcham_store.Stored_object_id.t;
}

type release
type binding
type attestation

module type Signer = sig
  val signer_identity : string
  val algorithm : string
  val sign : Yeokcham_id.Release_id.t -> string
end

module Deterministic_test_signer : Signer

type error =
  | Store_error of Yeokcham_store.error
  | Envelope_error of Yeokcham_envelope.creation_error
  | Encoding_error of Yeokcham_encoding.construction_error
  | Decode_error of string
  | Unsupported_schema_version of int64
  | Unexpected_object_type of {
      expected : Yeokcham_envelope.object_type;
      actual : Yeokcham_envelope.object_type;
    }
  | Invalid_identity_length of { kind : string; length : int }
  | Invalid_release of string
  | Logical_identity_mismatch
  | Invalid_binding_checksum
  | Invalid_attestation of string
  | Release_missing of Yeokcham_id.Release_id.t
  | Binding_release_mismatch
  | Conflicting_release_id_reuse of Yeokcham_id.Release_id.t
  | Workspace_error of Yeokcham_workspace_store.error
  | Validation_error of Yeokcham_validation.error
  | Snapshot_error of Yeokcham_snapshot.error
  | Workspace_attempt_missing of Yeokcham_id.Workspace_id.t
  | Unresolved_conflicts of Yeokcham_id.Workspace_attempt_id.t
  | Required_validation_failed of Yeokcham_id.Validation_id.t
  | Release_reproduction_mismatch
  | Parent_error of string
  | Injected_interruption of string

val error_to_string : error -> string

val create_release :
  parents:Yeokcham_id.Release_id.t list ->
  workspace:Yeokcham_id.Workspace_id.t ->
  workspace_revision:Yeokcham_id.Workspace_revision_id.t ->
  workspace_revision_object:Yeokcham_store.Stored_object_id.t ->
  attempt:attempt_link option ->
  base:Yeokcham_snapshot.Snapshot.id ->
  capsules:Capsule_store.revision_link list ->
  resolutions:Workspace_store.resolution_binding list ->
  final_snapshot:Yeokcham_snapshot.Snapshot.id ->
  evidence:evidence_link list ->
  message:string option ->
  created_at:int64 ->
  (release, error) result

val release_id : release -> Yeokcham_id.Release_id.t
val release_parents : release -> Yeokcham_id.Release_id.t list
val release_workspace : release -> Yeokcham_id.Workspace_id.t
val release_workspace_revision : release -> Yeokcham_id.Workspace_revision_id.t

val release_workspace_revision_object :
  release -> Yeokcham_store.Stored_object_id.t

val release_attempt : release -> attempt_link option
val release_base : release -> Yeokcham_snapshot.Snapshot.id
val release_capsules : release -> Capsule_store.revision_link list
val release_resolutions : release -> Workspace_store.resolution_binding list
val release_final_snapshot : release -> Yeokcham_snapshot.Snapshot.id
val release_evidence : release -> evidence_link list
val release_message : release -> string option
val release_created_at : release -> int64
val release_payload : release -> (Yeokcham_encoding.t, error) result
val decode_release_payload : Yeokcham_encoding.t -> (release, error) result

val store_release :
  Yeokcham_store.repository ->
  release ->
  (Yeokcham_store.Stored_object_id.t, error) result

val load_release :
  Yeokcham_store.repository ->
  Yeokcham_store.Stored_object_id.t ->
  (release, error) result

val binding_release : binding -> Yeokcham_id.Release_id.t
val binding_object : binding -> Yeokcham_store.Stored_object_id.t

val make_binding :
  release:Yeokcham_id.Release_id.t ->
  object_id:Yeokcham_store.Stored_object_id.t ->
  binding

val encode_binding : binding -> string
val decode_binding : string -> (binding, error) result
val binding_components : Yeokcham_id.Release_id.t -> string list
val publish_binding : Yeokcham_store.repository -> binding -> (unit, error) result

val create_attestation :
  release:Yeokcham_id.Release_id.t ->
  signer_identity:string ->
  algorithm:string ->
  signature:string ->
  signed_at:int64 ->
  (attestation, error) result

val attest :
  signer:(module Signer) ->
  release:Yeokcham_id.Release_id.t ->
  signed_at:int64 ->
  (attestation, error) result

val attestation_release : attestation -> Yeokcham_id.Release_id.t
val attestation_signer_identity : attestation -> string
val attestation_algorithm : attestation -> string
val attestation_signature : attestation -> string
val attestation_signed_at : attestation -> int64
val attestation_payload : attestation -> (Yeokcham_encoding.t, error) result

val decode_attestation_payload :
  Yeokcham_encoding.t -> (attestation, error) result

val store_attestation :
  Yeokcham_store.repository ->
  attestation ->
  (Yeokcham_store.Stored_object_id.t, error) result

val load_attestation :
  Yeokcham_store.repository ->
  Yeokcham_store.Stored_object_id.t ->
  (attestation, error) result

module Parent_resolver : sig
  type t =
    Yeokcham_id.Release_id.t -> (Yeokcham_id.Release_id.t list, string) result

  val verify_acyclic : t -> Yeokcham_id.Release_id.t -> (unit, string) result

  val contains :
    t ->
    base:Yeokcham_id.Release_id.t ->
    required:Yeokcham_id.Release_id.t ->
    (bool, string) result
end

module Requires_release : sig
  val satisfied :
    Parent_resolver.t ->
    base:Yeokcham_id.Release_id.t ->
    required:Yeokcham_id.Release_id.t ->
    (bool, string) result
end

module Durable : sig
  type failure_point = Before_release_binding

  val read :
    Yeokcham_store.repository -> Yeokcham_id.Release_id.t -> (release, error) result

  val list : Yeokcham_store.repository -> (release list, error) result

  val verify :
    Yeokcham_store.repository -> Yeokcham_id.Release_id.t -> (release, error) result

  val create :
    ?runner:(module Validation.Process_runner) ->
    store:Yeokcham_store.repository ->
    workspace:Yeokcham_id.Workspace_id.t ->
    parents:Yeokcham_id.Release_id.t list ->
    commands:Validation.command list ->
    message:string option ->
    observed_at:int64 ->
    created_at:int64 ->
    ?fail_at:failure_point ->
    unit ->
    (release, error) result
end
