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
