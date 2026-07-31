module Capsule_store = Paengi_capsule_store
module Workspace = Paengi_workspace

type parent_link = {
  parent_revision : Paengi_id.Workspace_revision_id.t;
  parent_object_id : Paengi_store.Stored_object_id.t;
}

type precedence_edge = {
  before : Paengi_id.Capsule_revision_id.t;
  after : Paengi_id.Capsule_revision_id.t;
}

type resolution_binding = {
  binding_conflict : Paengi_id.Conflict_id.t;
  binding_resolution : Paengi_id.Resolution_id.t;
  binding_object_id : Paengi_store.Stored_object_id.t;
}

type provenance =
  | Created
  | Enabled of Paengi_id.Capsule_revision_id.t
  | Disabled of Paengi_id.Capsule_revision_id.t
  | Reordered
  | Resolved of Paengi_id.Resolution_id.t

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
      capsule : Paengi_id.Capsule_id.t;
      revision : Paengi_id.Capsule_revision_id.t;
      operation_index : int;
    }
  | Attempt_already_satisfied of {
      capsule : Paengi_id.Capsule_id.t;
      revision : Paengi_id.Capsule_revision_id.t;
      operation_index : int;
    }
  | Attempt_persistent_conflict of Paengi_id.Conflict_id.t
  | Attempt_blocked_dependency of {
      capsule : Paengi_id.Capsule_id.t;
      revision : Paengi_id.Capsule_revision_id.t;
      operation_index : int;
      blocked_by : Paengi_id.Conflict_id.t;
    }
  | Attempt_rejected_operation of Paengi_id.Conflict_id.t
  | Attempt_resolved_explicitly of {
      capsule : Paengi_id.Capsule_id.t;
      revision : Paengi_id.Capsule_revision_id.t;
      operation_index : int;
    }

type error

val error_to_string : error -> string

val create_workspace :
  id:Paengi_id.Workspace_id.t ->
  created_at:int64 ->
  name:string option ->
  description:string option ->
  (workspace, error) result

val workspace_id : workspace -> Paengi_id.Workspace_id.t
val workspace_created_at : workspace -> int64
val workspace_name : workspace -> string option
val workspace_description : workspace -> string option
val workspace_payload : workspace -> (Paengi_encoding.t, error) result
val decode_workspace_payload : Paengi_encoding.t -> (workspace, error) result

val store_workspace :
  Paengi_store.repository ->
  workspace ->
  (Paengi_store.Stored_object_id.t, error) result

val load_workspace :
  Paengi_store.repository ->
  Paengi_store.Stored_object_id.t ->
  (workspace, error) result

val create_revision :
  workspace:Paengi_id.Workspace_id.t ->
  parent:parent_link option ->
  base:Paengi_snapshot.Snapshot.id ->
  selected:Capsule_store.revision_link list ->
  precedence:precedence_edge list ->
  resolved_order:Paengi_id.Capsule_revision_id.t list ->
  resolutions:resolution_binding list ->
  provenance:provenance ->
  created_at:int64 ->
  (workspace_revision, error) result

val revision_id : workspace_revision -> Paengi_id.Workspace_revision_id.t
val revision_workspace : workspace_revision -> Paengi_id.Workspace_id.t
val revision_parent : workspace_revision -> parent_link option
val revision_base : workspace_revision -> Paengi_snapshot.Snapshot.id
val revision_selected : workspace_revision -> Capsule_store.revision_link list
val revision_precedence : workspace_revision -> precedence_edge list

val revision_resolved_order :
  workspace_revision -> Paengi_id.Capsule_revision_id.t list

val revision_resolutions : workspace_revision -> resolution_binding list
val revision_provenance : workspace_revision -> provenance
val revision_created_at : workspace_revision -> int64
val revision_payload : workspace_revision -> (Paengi_encoding.t, error) result

val decode_revision_payload :
  Paengi_encoding.t -> (workspace_revision, error) result

val derive_revision_id : workspace_revision -> Paengi_id.Workspace_revision_id.t

val store_revision :
  Paengi_store.repository ->
  workspace_revision ->
  (Paengi_store.Stored_object_id.t, error) result

val load_revision :
  Paengi_store.repository ->
  Paengi_store.Stored_object_id.t ->
  (workspace_revision, error) result

val create_conflict :
  workspace:Paengi_id.Workspace_id.t ->
  workspace_revision:Paengi_id.Workspace_revision_id.t ->
  attempt:Paengi_id.Workspace_attempt_id.t option ->
  base:Paengi_snapshot.Snapshot.id ->
  capsule:Paengi_id.Capsule_id.t ->
  capsule_revision:Paengi_id.Capsule_revision_id.t ->
  operation_index:int ->
  kind:conflict_kind ->
  paths:Paengi_scratch.path list ->
  current:Paengi_scratch.entry option ->
  candidates:string list ->
  created_at:int64 ->
  (conflict, error) result

val conflict_id : conflict -> Paengi_id.Conflict_id.t
val conflict_workspace : conflict -> Paengi_id.Workspace_id.t
val conflict_workspace_revision : conflict -> Paengi_id.Workspace_revision_id.t
val conflict_attempt : conflict -> Paengi_id.Workspace_attempt_id.t option
val conflict_capsule : conflict -> Paengi_id.Capsule_id.t
val conflict_capsule_revision : conflict -> Paengi_id.Capsule_revision_id.t
val conflict_operation_index : conflict -> int
val conflict_kind : conflict -> conflict_kind
val conflict_paths : conflict -> Paengi_scratch.path list
val conflict_current : conflict -> Paengi_scratch.entry option
val conflict_candidates : conflict -> string list
val conflict_payload : conflict -> (Paengi_encoding.t, error) result
val decode_conflict_payload : Paengi_encoding.t -> (conflict, error) result

val store_conflict :
  Paengi_store.repository ->
  conflict ->
  (Paengi_store.Stored_object_id.t, error) result

val load_conflict :
  Paengi_store.repository ->
  Paengi_store.Stored_object_id.t ->
  (conflict, error) result

val create_resolution :
  conflict:conflict ->
  action:resolution_action ->
  expected_current:Paengi_scratch.entry option ->
  created_at:int64 ->
  (resolution, error) result

val resolution_id : resolution -> Paengi_id.Resolution_id.t
val resolution_conflict : resolution -> Paengi_id.Conflict_id.t

val resolution_workspace_revision :
  resolution -> Paengi_id.Workspace_revision_id.t

val resolution_action : resolution -> resolution_action
val resolution_expected_current : resolution -> Paengi_scratch.entry option
val resolution_payload : resolution -> (Paengi_encoding.t, error) result
val decode_resolution_payload : Paengi_encoding.t -> (resolution, error) result

val store_resolution :
  Paengi_store.repository ->
  resolution ->
  (Paengi_store.Stored_object_id.t, error) result

val load_resolution :
  Paengi_store.repository ->
  Paengi_store.Stored_object_id.t ->
  (resolution, error) result

val derive_attempt_id :
  workspace:Paengi_id.Workspace_id.t ->
  workspace_revision:Paengi_id.Workspace_revision_id.t ->
  base:Paengi_snapshot.Snapshot.id ->
  ordered:Capsule_store.revision_link list ->
  starting_checkpoint:Paengi_scratch.Checkpoint_id.t ->
  starting_snapshot:Paengi_snapshot.Snapshot.id ->
  Paengi_id.Workspace_attempt_id.t

val create_attempt :
  id:Paengi_id.Workspace_attempt_id.t ->
  workspace:Paengi_id.Workspace_id.t ->
  workspace_revision:Paengi_id.Workspace_revision_id.t ->
  base:Paengi_snapshot.Snapshot.id ->
  ordered:Capsule_store.revision_link list ->
  starting_checkpoint:Paengi_scratch.Checkpoint_id.t ->
  starting_snapshot:Paengi_snapshot.Snapshot.id ->
  outcomes:attempt_outcome list ->
  resulting_snapshot:Paengi_snapshot.Snapshot.id ->
  conflicts:Paengi_id.Conflict_id.t list ->
  created_at:int64 ->
  (workspace_attempt, error) result

val attempt_id : workspace_attempt -> Paengi_id.Workspace_attempt_id.t
val attempt_workspace : workspace_attempt -> Paengi_id.Workspace_id.t

val attempt_workspace_revision :
  workspace_attempt -> Paengi_id.Workspace_revision_id.t

val attempt_base : workspace_attempt -> Paengi_snapshot.Snapshot.id
val attempt_ordered : workspace_attempt -> Capsule_store.revision_link list

val attempt_starting_checkpoint :
  workspace_attempt -> Paengi_scratch.Checkpoint_id.t

val attempt_starting_snapshot : workspace_attempt -> Paengi_snapshot.Snapshot.id
val attempt_outcomes : workspace_attempt -> attempt_outcome list

val attempt_resulting_snapshot :
  workspace_attempt -> Paengi_snapshot.Snapshot.id

val attempt_conflicts : workspace_attempt -> Paengi_id.Conflict_id.t list
val attempt_payload : workspace_attempt -> (Paengi_encoding.t, error) result

val decode_attempt_payload :
  Paengi_encoding.t -> (workspace_attempt, error) result

val store_attempt :
  Paengi_store.repository ->
  workspace_attempt ->
  (Paengi_store.Stored_object_id.t, error) result

val load_attempt :
  Paengi_store.repository ->
  Paengi_store.Stored_object_id.t ->
  (workspace_attempt, error) result

val make_current_ref :
  generation:int64 ->
  workspace:Paengi_id.Workspace_id.t ->
  workspace_object:Paengi_store.Stored_object_id.t ->
  revision:Paengi_id.Workspace_revision_id.t ->
  revision_object:Paengi_store.Stored_object_id.t ->
  latest_attempt:
    (Paengi_id.Workspace_attempt_id.t * Paengi_store.Stored_object_id.t) option ->
  (current_ref, error) result

val current_generation : current_ref -> int64
val current_workspace : current_ref -> Paengi_id.Workspace_id.t
val current_workspace_object : current_ref -> Paengi_store.Stored_object_id.t
val current_revision : current_ref -> Paengi_id.Workspace_revision_id.t
val current_revision_object : current_ref -> Paengi_store.Stored_object_id.t

val current_latest_attempt :
  current_ref ->
  (Paengi_id.Workspace_attempt_id.t * Paengi_store.Stored_object_id.t) option

val encode_current_ref : current_ref -> string
val decode_current_ref : string -> (current_ref, error) result
val current_ref_components : Paengi_id.Workspace_id.t -> string list
val resolved_workspace : resolved -> workspace
val resolved_workspace_object : resolved -> Paengi_store.Stored_object_id.t
val resolved_revision : resolved -> workspace_revision
val resolved_revision_object : resolved -> Paengi_store.Stored_object_id.t
val resolved_current_ref : resolved -> current_ref

module Durable : sig
  type materialisation = {
    attempt : workspace_attempt;
    attempt_object : Paengi_store.Stored_object_id.t;
    conflicts : (conflict * Paengi_store.Stored_object_id.t) list;
    actions : Paengi_scratch.operation list;
    scratch_checkpoint : Paengi_scratch.Checkpoint_id.t option;
    partial : bool;
  }

  val create :
    store:Paengi_store.repository ->
    id:Paengi_id.Workspace_id.t ->
    base:Paengi_snapshot.Snapshot.id ->
    name:string option ->
    description:string option ->
    created_at:int64 ->
    (resolved, error) result

  val read_current :
    Paengi_store.repository ->
    Paengi_id.Workspace_id.t ->
    (resolved, error) result

  val list : Paengi_store.repository -> (resolved list, error) result

  val enable_current_capsule :
    store:Paengi_store.repository ->
    workspace:Paengi_id.Workspace_id.t ->
    capsule:Paengi_id.Capsule_id.t ->
    expected_generation:int64 option ->
    created_at:int64 ->
    (resolved, error) result

  val enable_revision :
    store:Paengi_store.repository ->
    workspace:Paengi_id.Workspace_id.t ->
    revision:Paengi_id.Capsule_revision_id.t ->
    expected_generation:int64 option ->
    created_at:int64 ->
    (resolved, error) result

  val disable_capsule :
    store:Paengi_store.repository ->
    workspace:Paengi_id.Workspace_id.t ->
    capsule:Paengi_id.Capsule_id.t ->
    expected_generation:int64 option ->
    created_at:int64 ->
    (resolved, error) result

  val reorder :
    store:Paengi_store.repository ->
    workspace:Paengi_id.Workspace_id.t ->
    order:Paengi_id.Capsule_revision_id.t list ->
    expected_generation:int64 option ->
    created_at:int64 ->
    (resolved, error) result

  val explain_order :
    Paengi_store.repository ->
    Paengi_id.Workspace_id.t ->
    (Workspace.order, error) result

  val materialise :
    store:Paengi_store.repository ->
    scratch:Paengi_scratch.repository ->
    root:string ->
    workspace:Paengi_id.Workspace_id.t ->
    observed_at:int64 ->
    created_at:int64 ->
    dry_run:bool ->
    ?before_apply:(unit -> unit) ->
    unit ->
    (materialisation, error) result

  val list_conflicts :
    Paengi_store.repository ->
    Paengi_id.Workspace_id.t ->
    (conflict list, error) result

  val show_conflict :
    Paengi_store.repository ->
    Paengi_id.Conflict_id.t ->
    (conflict, error) result

  val resolve_skip :
    store:Paengi_store.repository ->
    workspace:Paengi_id.Workspace_id.t ->
    conflict:Paengi_id.Conflict_id.t ->
    expected_generation:int64 option ->
    created_at:int64 ->
    (resolved, error) result
end
