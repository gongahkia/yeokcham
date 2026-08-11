(** Canonical immutable V2 workspace records from ADR-060. *)

module Capsule = Yeokcham_v2_capsule
module Model = Yeokcham_model
module V2_model = Yeokcham_v2_model
module Workspace = Yeokcham_v2_workspace

type workspace
type workspace_revision
type workspace_revision_link
type conflict
type conflict_link
type resolution
type resolution_link
type workspace_attempt
type resolution_binding

type attempt_outcome =
  | Attempt_applied_exactly of {
      revision : Capsule.revision_link;
      operation_index : int;
    }
  | Attempt_skipped_explicitly of {
      revision : Capsule.revision_link;
      operation_index : int;
    }
  | Attempt_conflict of conflict_link
  | Attempt_blocked_by_conflict of {
      revision : Capsule.revision_link;
      operation_index : int;
      blocked_by : conflict_link;
    }

type resolution_action =
  | Skip_operation of {
      revision : Capsule.revision_link;
      operation_index : int;
    }

type error =
  | Invalid_title of Yeokcham_encoding.construction_error
  | Invalid_description of Yeokcham_encoding.construction_error
  | Invalid_payload of string
  | Invalid_identity of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Noncanonical_record
  | Invalid_resolution_target

val error_to_string : error -> string
val current_schema_version : int64
val supported_mandatory_features : int64

val make_workspace :
  id:V2_model.Workspace_id.t ->
  title:string ->
  description:string ->
  created_at:int64 ->
  (workspace, error) result

val workspace_id : workspace -> V2_model.Workspace_id.t
val workspace_title : workspace -> string
val workspace_description : workspace -> string
val workspace_created_at : workspace -> int64
val encode_workspace : workspace -> string
val decode_workspace : string -> (workspace, error) result

val make_workspace_revision_link :
  workspace_id:V2_model.Workspace_id.t ->
  revision_id:V2_model.Workspace_revision_id.t ->
  revision_ref:V2_model.Opaque_object_ref.t ->
  workspace_revision_link

val workspace_revision_link_workspace_id :
  workspace_revision_link -> V2_model.Workspace_id.t

val workspace_revision_link_revision_id :
  workspace_revision_link -> V2_model.Workspace_revision_id.t

val workspace_revision_link_ref :
  workspace_revision_link -> V2_model.Opaque_object_ref.t

val make_resolution_binding :
  conflict:conflict_link -> resolution:resolution_link -> resolution_binding

val resolution_binding_conflict : resolution_binding -> conflict_link
val resolution_binding_resolution : resolution_binding -> resolution_link

val make_workspace_revision :
  workspace:workspace ->
  workspace_ref:V2_model.Opaque_object_ref.t ->
  parent:workspace_revision_link option ->
  base:Capsule.snapshot_link ->
  selected:Capsule.revision_link list ->
  precedence:Workspace.precedence list ->
  resolved_order:Capsule.revision_link list ->
  resolutions:resolution_binding list ->
  created_at:int64 ->
  (workspace_revision, error) result

val workspace_revision_id :
  workspace_revision -> V2_model.Workspace_revision_id.t

val workspace_revision_workspace_id :
  workspace_revision -> V2_model.Workspace_id.t

val workspace_revision_workspace_ref :
  workspace_revision -> V2_model.Opaque_object_ref.t

val workspace_revision_parent :
  workspace_revision -> workspace_revision_link option

val workspace_revision_base : workspace_revision -> Capsule.snapshot_link

val workspace_revision_selected :
  workspace_revision -> Capsule.revision_link list

val workspace_revision_precedence :
  workspace_revision -> Workspace.precedence list

val workspace_revision_resolved_order :
  workspace_revision -> Capsule.revision_link list

val workspace_revision_resolutions :
  workspace_revision -> resolution_binding list

val workspace_revision_created_at : workspace_revision -> int64
val encode_workspace_revision : workspace_revision -> string
val decode_workspace_revision : string -> (workspace_revision, error) result

val make_conflict_link :
  id:V2_model.Conflict_id.t ->
  object_ref:V2_model.Opaque_object_ref.t ->
  conflict_link

val conflict_link_id : conflict_link -> V2_model.Conflict_id.t
val conflict_link_ref : conflict_link -> V2_model.Opaque_object_ref.t

val make_conflict :
  workspace:workspace_revision_link ->
  attempt:V2_model.Workspace_attempt_id.t ->
  source:Workspace.conflict ->
  created_at:int64 ->
  (conflict, error) result

val conflict_id : conflict -> V2_model.Conflict_id.t
val conflict_workspace : conflict -> workspace_revision_link
val conflict_attempt : conflict -> V2_model.Workspace_attempt_id.t
val conflict_revision : conflict -> Capsule.revision_link
val conflict_operation_index : conflict -> int
val conflict_paths : conflict -> Model.Path.t list
val conflict_cause : conflict -> Model.transition_error
val conflict_created_at : conflict -> int64
val encode_conflict : conflict -> string
val decode_conflict : string -> (conflict, error) result

val make_resolution_link :
  id:V2_model.Resolution_id.t ->
  object_ref:V2_model.Opaque_object_ref.t ->
  resolution_link

val resolution_link_id : resolution_link -> V2_model.Resolution_id.t
val resolution_link_ref : resolution_link -> V2_model.Opaque_object_ref.t

val make_resolution :
  conflict:conflict_link ->
  source:conflict ->
  workspace:workspace_revision_link ->
  action:resolution_action ->
  created_at:int64 ->
  (resolution, error) result

val resolution_id : resolution -> V2_model.Resolution_id.t
val resolution_conflict : resolution -> conflict_link
val resolution_workspace : resolution -> workspace_revision_link
val resolution_action : resolution -> resolution_action
val resolution_created_at : resolution -> int64
val encode_resolution : resolution -> string
val decode_resolution : string -> (resolution, error) result

val derive_attempt_id :
  workspace:workspace_revision_link ->
  base:Capsule.snapshot_link ->
  ordered:Capsule.revision_link list ->
  V2_model.Workspace_attempt_id.t

val make_workspace_attempt :
  id:V2_model.Workspace_attempt_id.t ->
  workspace:workspace_revision_link ->
  base:Capsule.snapshot_link ->
  ordered:Capsule.revision_link list ->
  resulting_snapshot:Capsule.snapshot_link ->
  outcomes:attempt_outcome list ->
  conflicts:conflict_link list ->
  created_at:int64 ->
  (workspace_attempt, error) result

val workspace_attempt_id : workspace_attempt -> V2_model.Workspace_attempt_id.t
val workspace_attempt_workspace : workspace_attempt -> workspace_revision_link
val workspace_attempt_base : workspace_attempt -> Capsule.snapshot_link
val workspace_attempt_ordered : workspace_attempt -> Capsule.revision_link list

val workspace_attempt_resulting_snapshot :
  workspace_attempt -> Capsule.snapshot_link

val workspace_attempt_outcomes : workspace_attempt -> attempt_outcome list
val workspace_attempt_conflicts : workspace_attempt -> conflict_link list
val workspace_attempt_created_at : workspace_attempt -> int64
val encode_workspace_attempt : workspace_attempt -> string
val decode_workspace_attempt : string -> (workspace_attempt, error) result
