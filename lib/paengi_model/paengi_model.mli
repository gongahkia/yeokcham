module Path : sig
  type t

  type error =
    | Empty_path
    | Empty_component of int
    | Dot_component of int
    | Dot_dot_component of int
    | Separator_in_component of int
    | Nul_in_component of int

  val error_to_string : error -> string
  val of_components : string list -> (t, error) result
  val to_components : t -> string list
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val to_string : t -> string
end

type file_mode = Regular | Executable | Symlink
type file_entry = { mode : file_mode; content : string }
type tree
type tree_entry = File of file_entry | Directory of tree

type initial_entry =
  | Directory_path of Path.t
  | File_path of Path.t * file_entry

type construction_error =
  | Duplicate_initial_path of Path.t
  | Missing_initial_parent of Path.t
  | Initial_parent_is_file of Path.t

val construction_error_to_string : construction_error -> string

type scratch_operation =
  | Create_file of { path : Path.t; content : string; mode : file_mode }
  | Modify_file of {
      path : Path.t;
      expected_content : string;
      replacement_content : string;
    }
  | Delete_path of { path : Path.t; prior : tree_entry }
  | Move_path of { source : Path.t; destination : Path.t; prior : tree_entry }
  | Change_mode of {
      path : Path.t;
      expected_mode : file_mode;
      replacement_mode : file_mode;
    }

type transition_error =
  | Path_not_found of Path.t
  | Path_already_exists of Path.t
  | Parent_not_found of Path.t
  | Parent_is_file of Path.t
  | Expected_entry_mismatch of Path.t
  | Expected_content_mismatch of Path.t
  | Expected_mode_mismatch of Path.t
  | Move_into_descendant of { source : Path.t; destination : Path.t }

val transition_error_to_string : transition_error -> string

type replay_error = { operation_index : int; cause : transition_error }

val replay_error_to_string : replay_error -> string

type observation_source = Explicit | Scan

type retention_reason =
  | User_pinned
  | Capsule_boundary of Paengi_id.Capsule_id.t
  | Release_boundary of Paengi_id.Release_id.t
  | Validation_passed of Paengi_id.Validation_id.t
  | Periodic_retention
  | Recent_window
  | Conflict_reference of Paengi_id.Conflict_id.t

val retention_reason_to_string : retention_reason -> string

module Snapshot : sig
  type t

  val empty : t
  val of_entries : initial_entry list -> (t, construction_error) result
  val entries : t -> initial_entry list
  val find : t -> Path.t -> tree_entry option
  val equal : t -> t -> bool
  val canonical_bytes : t -> string
  val id : t -> Paengi_id.Snapshot_id.t
  val apply_operation : t -> scratch_operation -> (t, transition_error) result
  val apply_operations : t -> scratch_operation list -> (t, replay_error) result
end

type scratch_event
type checkpoint

type event_transition_error =
  | Event_parent_mismatch of {
      expected_parent : Paengi_id.Checkpoint_id.t;
      actual_parent : Paengi_id.Checkpoint_id.t;
    }
  | Event_operation_rejected of replay_error

val event_transition_error_to_string : event_transition_error -> string

module Scratch_event : sig
  val create :
    parent:Paengi_id.Checkpoint_id.t ->
    operations:scratch_operation list ->
    observed_at:int64 ->
    source:observation_source ->
    scratch_event

  val id : scratch_event -> Paengi_id.Operation_id.t
  val parent : scratch_event -> Paengi_id.Checkpoint_id.t
  val operations : scratch_event -> scratch_operation list
  val observed_at : scratch_event -> int64
  val source : scratch_event -> observation_source
end

module Checkpoint : sig
  val initial :
    snapshot:Snapshot.t ->
    created_at:int64 ->
    retention:retention_reason list ->
    checkpoint

  val id : checkpoint -> Paengi_id.Checkpoint_id.t
  val parent : checkpoint -> Paengi_id.Checkpoint_id.t option
  val snapshot : checkpoint -> Snapshot.t
  val event : checkpoint -> Paengi_id.Operation_id.t option
  val created_at : checkpoint -> int64
  val retention : checkpoint -> retention_reason list
end

module Scratch : sig
  val apply_event :
    parent:checkpoint ->
    created_at:int64 ->
    retention:retention_reason list ->
    scratch_event ->
    (checkpoint, event_transition_error) result
end

type repository

type repository_error =
  | Snapshot_identity_mismatch of {
      supplied : Paengi_id.Snapshot_id.t;
      computed : Paengi_id.Snapshot_id.t;
    }
  | Event_identity_mismatch of {
      supplied : Paengi_id.Operation_id.t;
      computed : Paengi_id.Operation_id.t;
    }
  | Checkpoint_identity_mismatch of {
      supplied : Paengi_id.Checkpoint_id.t;
      computed : Paengi_id.Checkpoint_id.t;
    }
  | Conflicting_snapshot of Paengi_id.Snapshot_id.t
  | Conflicting_event of Paengi_id.Operation_id.t
  | Conflicting_checkpoint of Paengi_id.Checkpoint_id.t
  | Missing_snapshot of Paengi_id.Snapshot_id.t
  | Missing_event of Paengi_id.Operation_id.t
  | Missing_checkpoint of Paengi_id.Checkpoint_id.t
  | Event_parent_missing of Paengi_id.Checkpoint_id.t
  | Incoherent_checkpoint of Paengi_id.Checkpoint_id.t
  | Replay_operation_rejected of replay_error
  | Target_not_descended_from of {
      ancestor : Paengi_id.Checkpoint_id.t;
      target : Paengi_id.Checkpoint_id.t;
    }

val repository_error_to_string : repository_error -> string

module Repository : sig
  type t = repository

  val empty : t
  val scratch_head : t -> Paengi_id.Checkpoint_id.t option
  val find_snapshot : t -> Paengi_id.Snapshot_id.t -> Snapshot.t option
  val find_event : t -> Paengi_id.Operation_id.t -> scratch_event option
  val find_checkpoint : t -> Paengi_id.Checkpoint_id.t -> checkpoint option

  val insert_snapshot :
    t ->
    id:Paengi_id.Snapshot_id.t ->
    Snapshot.t ->
    (t, repository_error) result

  val add_snapshot : t -> Snapshot.t -> (t, repository_error) result

  val insert_event :
    t ->
    id:Paengi_id.Operation_id.t ->
    scratch_event ->
    (t, repository_error) result

  val add_event : t -> scratch_event -> (t, repository_error) result

  val insert_checkpoint :
    t ->
    id:Paengi_id.Checkpoint_id.t ->
    checkpoint ->
    (t, repository_error) result

  val add_checkpoint : t -> checkpoint -> (t, repository_error) result

  val replay :
    t ->
    ancestor:Paengi_id.Checkpoint_id.t ->
    target:Paengi_id.Checkpoint_id.t ->
    (Snapshot.t, repository_error) result
end
