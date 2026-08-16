module Capsule_store = Yeokcham_capsule_store
module Workspace = Yeokcham_workspace

type parent_link = {
  parent_revision : Yeokcham_id.Workspace_revision_id.t;
  parent_object_id : Yeokcham_store.Stored_object_id.t;
}

type precedence_edge = {
  before : Yeokcham_id.Capsule_revision_id.t;
  after : Yeokcham_id.Capsule_revision_id.t;
}

type resolution_binding = {
  binding_conflict : Yeokcham_id.Conflict_id.t;
  binding_resolution : Yeokcham_id.Resolution_id.t;
  binding_object_id : Yeokcham_store.Stored_object_id.t;
}

type provenance =
  | Created
  | Enabled of Yeokcham_id.Capsule_revision_id.t
  | Disabled of Yeokcham_id.Capsule_revision_id.t
  | Reordered
  | Resolved of Yeokcham_id.Resolution_id.t

type conflict_kind =
  | Missing_or_ambiguous_precondition
  | Competing_edits
  | Delete_modify
  | Move_modify
  | Binary_conflict
  | Dependency_failure
  | Unsupported_or_uncertain_operation

type resolution_action = Skip_operation
type workspace
type workspace_revision
type workspace_attempt
type conflict
type resolution
type current_ref
type resolved

type attempt_outcome =
  | Attempt_applied_exactly of {
      capsule : Yeokcham_id.Capsule_id.t;
      revision : Yeokcham_id.Capsule_revision_id.t;
      operation_index : int;
    }
  | Attempt_already_satisfied of {
      capsule : Yeokcham_id.Capsule_id.t;
      revision : Yeokcham_id.Capsule_revision_id.t;
      operation_index : int;
    }
  | Attempt_persistent_conflict of Yeokcham_id.Conflict_id.t
  | Attempt_blocked_dependency of {
      capsule : Yeokcham_id.Capsule_id.t;
      revision : Yeokcham_id.Capsule_revision_id.t;
      operation_index : int;
      blocked_by : Yeokcham_id.Conflict_id.t;
    }
  | Attempt_rejected_operation of Yeokcham_id.Conflict_id.t
  | Attempt_resolved_explicitly of {
      capsule : Yeokcham_id.Capsule_id.t;
      revision : Yeokcham_id.Capsule_revision_id.t;
      operation_index : int;
    }

type error

val error_to_string : error -> string

val create_workspace :
  id:Yeokcham_id.Workspace_id.t ->
  created_at:int64 ->
  name:string option ->
  description:string option ->
  (workspace, error) result

val workspace_id : workspace -> Yeokcham_id.Workspace_id.t
val workspace_created_at : workspace -> int64
val workspace_name : workspace -> string option
val workspace_description : workspace -> string option
val workspace_payload : workspace -> (Yeokcham_encoding.t, error) result
val decode_workspace_payload : Yeokcham_encoding.t -> (workspace, error) result

val store_workspace :
  Yeokcham_store.repository ->
  workspace ->
  (Yeokcham_store.Stored_object_id.t, error) result

val load_workspace :
  Yeokcham_store.repository ->
  Yeokcham_store.Stored_object_id.t ->
  (workspace, error) result

val create_revision :
  workspace:Yeokcham_id.Workspace_id.t ->
  parent:parent_link option ->
  base:Yeokcham_snapshot.Snapshot.id ->
  selected:Capsule_store.revision_link list ->
  precedence:precedence_edge list ->
  resolved_order:Yeokcham_id.Capsule_revision_id.t list ->
  resolutions:resolution_binding list ->
  provenance:provenance ->
  created_at:int64 ->
  (workspace_revision, error) result

val revision_id : workspace_revision -> Yeokcham_id.Workspace_revision_id.t
val revision_workspace : workspace_revision -> Yeokcham_id.Workspace_id.t
val revision_parent : workspace_revision -> parent_link option
val revision_base : workspace_revision -> Yeokcham_snapshot.Snapshot.id
val revision_selected : workspace_revision -> Capsule_store.revision_link list
val revision_precedence : workspace_revision -> precedence_edge list

val revision_resolved_order :
  workspace_revision -> Yeokcham_id.Capsule_revision_id.t list

val revision_resolutions : workspace_revision -> resolution_binding list
val revision_provenance : workspace_revision -> provenance
val revision_created_at : workspace_revision -> int64
val revision_payload : workspace_revision -> (Yeokcham_encoding.t, error) result

val decode_revision_payload :
  Yeokcham_encoding.t -> (workspace_revision, error) result

val derive_revision_id :
  workspace_revision -> Yeokcham_id.Workspace_revision_id.t

val store_revision :
  Yeokcham_store.repository ->
  workspace_revision ->
  (Yeokcham_store.Stored_object_id.t, error) result

val load_revision :
  Yeokcham_store.repository ->
  Yeokcham_store.Stored_object_id.t ->
  (workspace_revision, error) result

val create_conflict :
  workspace:Yeokcham_id.Workspace_id.t ->
  workspace_revision:Yeokcham_id.Workspace_revision_id.t ->
  attempt:Yeokcham_id.Workspace_attempt_id.t option ->
  base:Yeokcham_snapshot.Snapshot.id ->
  capsule:Yeokcham_id.Capsule_id.t ->
  capsule_revision:Yeokcham_id.Capsule_revision_id.t ->
  operation_index:int ->
  kind:conflict_kind ->
  paths:Yeokcham_scratch.path list ->
  current:Yeokcham_scratch.entry option ->
  candidates:string list ->
  created_at:int64 ->
  (conflict, error) result

val conflict_id : conflict -> Yeokcham_id.Conflict_id.t
val conflict_workspace : conflict -> Yeokcham_id.Workspace_id.t

val conflict_workspace_revision :
  conflict -> Yeokcham_id.Workspace_revision_id.t

val conflict_attempt : conflict -> Yeokcham_id.Workspace_attempt_id.t option
val conflict_capsule : conflict -> Yeokcham_id.Capsule_id.t
val conflict_capsule_revision : conflict -> Yeokcham_id.Capsule_revision_id.t
val conflict_operation_index : conflict -> int
val conflict_kind : conflict -> conflict_kind
val conflict_paths : conflict -> Yeokcham_scratch.path list
val conflict_current : conflict -> Yeokcham_scratch.entry option
val conflict_candidates : conflict -> string list
val conflict_payload : conflict -> (Yeokcham_encoding.t, error) result
val decode_conflict_payload : Yeokcham_encoding.t -> (conflict, error) result

val store_conflict :
  Yeokcham_store.repository ->
  conflict ->
  (Yeokcham_store.Stored_object_id.t, error) result

val load_conflict :
  Yeokcham_store.repository ->
  Yeokcham_store.Stored_object_id.t ->
  (conflict, error) result

val create_resolution :
  conflict:conflict ->
  action:resolution_action ->
  expected_current:Yeokcham_scratch.entry option ->
  created_at:int64 ->
  (resolution, error) result

val resolution_id : resolution -> Yeokcham_id.Resolution_id.t
val resolution_conflict : resolution -> Yeokcham_id.Conflict_id.t

val resolution_workspace_revision :
  resolution -> Yeokcham_id.Workspace_revision_id.t

val resolution_action : resolution -> resolution_action
val resolution_expected_current : resolution -> Yeokcham_scratch.entry option
val resolution_payload : resolution -> (Yeokcham_encoding.t, error) result

val decode_resolution_payload :
  Yeokcham_encoding.t -> (resolution, error) result

val store_resolution :
  Yeokcham_store.repository ->
  resolution ->
  (Yeokcham_store.Stored_object_id.t, error) result

val load_resolution :
  Yeokcham_store.repository ->
  Yeokcham_store.Stored_object_id.t ->
  (resolution, error) result

val derive_attempt_id :
  workspace:Yeokcham_id.Workspace_id.t ->
  workspace_revision:Yeokcham_id.Workspace_revision_id.t ->
  base:Yeokcham_snapshot.Snapshot.id ->
  ordered:Capsule_store.revision_link list ->
  starting_checkpoint:Yeokcham_scratch.Checkpoint_id.t ->
  starting_snapshot:Yeokcham_snapshot.Snapshot.id ->
  Yeokcham_id.Workspace_attempt_id.t

val create_attempt :
  id:Yeokcham_id.Workspace_attempt_id.t ->
  workspace:Yeokcham_id.Workspace_id.t ->
  workspace_revision:Yeokcham_id.Workspace_revision_id.t ->
  base:Yeokcham_snapshot.Snapshot.id ->
  ordered:Capsule_store.revision_link list ->
  starting_checkpoint:Yeokcham_scratch.Checkpoint_id.t ->
  starting_snapshot:Yeokcham_snapshot.Snapshot.id ->
  outcomes:attempt_outcome list ->
  resulting_snapshot:Yeokcham_snapshot.Snapshot.id ->
  conflicts:Yeokcham_id.Conflict_id.t list ->
  created_at:int64 ->
  (workspace_attempt, error) result

val attempt_id : workspace_attempt -> Yeokcham_id.Workspace_attempt_id.t
val attempt_workspace : workspace_attempt -> Yeokcham_id.Workspace_id.t

val attempt_workspace_revision :
  workspace_attempt -> Yeokcham_id.Workspace_revision_id.t

val attempt_base : workspace_attempt -> Yeokcham_snapshot.Snapshot.id
val attempt_ordered : workspace_attempt -> Capsule_store.revision_link list

val attempt_starting_checkpoint :
  workspace_attempt -> Yeokcham_scratch.Checkpoint_id.t

val attempt_starting_snapshot :
  workspace_attempt -> Yeokcham_snapshot.Snapshot.id

val attempt_outcomes : workspace_attempt -> attempt_outcome list

val attempt_resulting_snapshot :
  workspace_attempt -> Yeokcham_snapshot.Snapshot.id

val attempt_conflicts : workspace_attempt -> Yeokcham_id.Conflict_id.t list
val attempt_payload : workspace_attempt -> (Yeokcham_encoding.t, error) result

val decode_attempt_payload :
  Yeokcham_encoding.t -> (workspace_attempt, error) result

val store_attempt :
  Yeokcham_store.repository ->
  workspace_attempt ->
  (Yeokcham_store.Stored_object_id.t, error) result

val load_attempt :
  Yeokcham_store.repository ->
  Yeokcham_store.Stored_object_id.t ->
  (workspace_attempt, error) result

val make_current_ref :
  generation:int64 ->
  workspace:Yeokcham_id.Workspace_id.t ->
  workspace_object:Yeokcham_store.Stored_object_id.t ->
  revision:Yeokcham_id.Workspace_revision_id.t ->
  revision_object:Yeokcham_store.Stored_object_id.t ->
  latest_attempt:
    (Yeokcham_id.Workspace_attempt_id.t * Yeokcham_store.Stored_object_id.t)
    option ->
  (current_ref, error) result

val current_generation : current_ref -> int64
val current_workspace : current_ref -> Yeokcham_id.Workspace_id.t
val current_workspace_object : current_ref -> Yeokcham_store.Stored_object_id.t
val current_revision : current_ref -> Yeokcham_id.Workspace_revision_id.t
val current_revision_object : current_ref -> Yeokcham_store.Stored_object_id.t

val current_latest_attempt :
  current_ref ->
  (Yeokcham_id.Workspace_attempt_id.t * Yeokcham_store.Stored_object_id.t)
  option

val encode_current_ref : current_ref -> string
val decode_current_ref : string -> (current_ref, error) result
val current_ref_components : Yeokcham_id.Workspace_id.t -> string list
val resolved_workspace : resolved -> workspace
val resolved_workspace_object : resolved -> Yeokcham_store.Stored_object_id.t
val resolved_revision : resolved -> workspace_revision
val resolved_revision_object : resolved -> Yeokcham_store.Stored_object_id.t
val resolved_current_ref : resolved -> current_ref

module Durable : sig
  type materialisation = {
    attempt : workspace_attempt;
    attempt_object : Yeokcham_store.Stored_object_id.t;
    conflicts : (conflict * Yeokcham_store.Stored_object_id.t) list;
    actions : Yeokcham_scratch.operation list;
    scratch_checkpoint : Yeokcham_scratch.Checkpoint_id.t option;
    partial : bool;
  }

  val create :
    store:Yeokcham_store.repository ->
    id:Yeokcham_id.Workspace_id.t ->
    base:Yeokcham_snapshot.Snapshot.id ->
    name:string option ->
    description:string option ->
    created_at:int64 ->
    (resolved, error) result

  val read_current :
    Yeokcham_store.repository ->
    Yeokcham_id.Workspace_id.t ->
    (resolved, error) result

  val list : Yeokcham_store.repository -> (resolved list, error) result

  val enable_current_capsule :
    store:Yeokcham_store.repository ->
    workspace:Yeokcham_id.Workspace_id.t ->
    capsule:Yeokcham_id.Capsule_id.t ->
    expected_generation:int64 option ->
    created_at:int64 ->
    (resolved, error) result

  val enable_revision :
    store:Yeokcham_store.repository ->
    workspace:Yeokcham_id.Workspace_id.t ->
    revision:Yeokcham_id.Capsule_revision_id.t ->
    expected_generation:int64 option ->
    created_at:int64 ->
    (resolved, error) result

  val disable_capsule :
    store:Yeokcham_store.repository ->
    workspace:Yeokcham_id.Workspace_id.t ->
    capsule:Yeokcham_id.Capsule_id.t ->
    expected_generation:int64 option ->
    created_at:int64 ->
    (resolved, error) result

  val reorder :
    store:Yeokcham_store.repository ->
    workspace:Yeokcham_id.Workspace_id.t ->
    order:Yeokcham_id.Capsule_revision_id.t list ->
    expected_generation:int64 option ->
    created_at:int64 ->
    (resolved, error) result

  val explain_order :
    Yeokcham_store.repository ->
    Yeokcham_id.Workspace_id.t ->
    (Workspace.order, error) result

  val verify_attempt :
    store:Yeokcham_store.repository ->
    revision:workspace_revision ->
    attempt:workspace_attempt ->
    (unit, error) result

  val materialise :
    store:Yeokcham_store.repository ->
    scratch:Yeokcham_scratch.repository ->
    root:string ->
    workspace:Yeokcham_id.Workspace_id.t ->
    observed_at:int64 ->
    created_at:int64 ->
    dry_run:bool ->
    ?before_apply:(unit -> unit) ->
    ?on_progress:(completed:int -> total:int -> unit) ->
    unit ->
    (materialisation, error) result

  val list_conflicts :
    Yeokcham_store.repository ->
    Yeokcham_id.Workspace_id.t ->
    (conflict list, error) result

  val show_conflict :
    Yeokcham_store.repository ->
    Yeokcham_id.Conflict_id.t ->
    (conflict, error) result

  val resolve_skip :
    store:Yeokcham_store.repository ->
    workspace:Yeokcham_id.Workspace_id.t ->
    conflict:Yeokcham_id.Conflict_id.t ->
    expected_generation:int64 option ->
    created_at:int64 ->
    (resolved, error) result
end
