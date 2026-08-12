(** Canonical immutable V2 validation-evidence and release records from ADR-062.
*)

module Capsule = Yeokcham_v2_capsule
module V2_model = Yeokcham_v2_model
module Workspace_record = Yeokcham_v2_workspace_record

type validation_status = Passed | Failed
type validation_evidence
type validation_evidence_link
type workspace_attempt_link
type release
type release_link

type error =
  | Invalid_check_name of Yeokcham_encoding.construction_error
  | Invalid_message of Yeokcham_encoding.construction_error
  | Invalid_payload of string
  | Invalid_identity of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Noncanonical_record

val error_to_string : error -> string
val current_schema_version : int64
val supported_mandatory_features : int64

val make_validation_evidence :
  snapshot:Capsule.snapshot_link ->
  check_name:string ->
  status:validation_status ->
  observed_at:int64 ->
  (validation_evidence, error) result

val validation_evidence_id : validation_evidence -> V2_model.Validation_id.t
val validation_evidence_snapshot : validation_evidence -> Capsule.snapshot_link
val validation_evidence_check_name : validation_evidence -> string
val validation_evidence_status : validation_evidence -> validation_status
val validation_evidence_observed_at : validation_evidence -> int64
val encode_validation_evidence : validation_evidence -> string
val decode_validation_evidence : string -> (validation_evidence, error) result

val make_validation_evidence_link :
  id:V2_model.Validation_id.t ->
  object_ref:V2_model.Opaque_object_ref.t ->
  validation_evidence_link

val validation_evidence_link_id :
  validation_evidence_link -> V2_model.Validation_id.t

val validation_evidence_link_ref :
  validation_evidence_link -> V2_model.Opaque_object_ref.t

val make_workspace_attempt_link :
  id:V2_model.Workspace_attempt_id.t ->
  object_ref:V2_model.Opaque_object_ref.t ->
  workspace_attempt_link

val workspace_attempt_link_id :
  workspace_attempt_link -> V2_model.Workspace_attempt_id.t

val workspace_attempt_link_ref :
  workspace_attempt_link -> V2_model.Opaque_object_ref.t

val make_release :
  parents:release_link list ->
  workspace:Workspace_record.workspace_revision_link ->
  attempt:workspace_attempt_link ->
  base:Capsule.snapshot_link ->
  capsules:Capsule.revision_link list ->
  resolutions:Workspace_record.resolution_binding list ->
  final_snapshot:Capsule.snapshot_link ->
  evidence:validation_evidence_link list ->
  message:string option ->
  created_at:int64 ->
  (release, error) result

val release_id : release -> V2_model.Release_id.t
val release_parents : release -> release_link list
val release_workspace : release -> Workspace_record.workspace_revision_link
val release_attempt : release -> workspace_attempt_link
val release_base : release -> Capsule.snapshot_link
val release_capsules : release -> Capsule.revision_link list
val release_resolutions : release -> Workspace_record.resolution_binding list
val release_final_snapshot : release -> Capsule.snapshot_link
val release_evidence : release -> validation_evidence_link list
val release_message : release -> string option
val release_created_at : release -> int64
val encode_release : release -> string
val decode_release : string -> (release, error) result

val make_release_link :
  id:V2_model.Release_id.t ->
  object_ref:V2_model.Opaque_object_ref.t ->
  release_link

val release_link_id : release_link -> V2_model.Release_id.t
val release_link_ref : release_link -> V2_model.Opaque_object_ref.t
