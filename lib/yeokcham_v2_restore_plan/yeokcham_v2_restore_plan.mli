(** Pure planning for guarded materialisation of exact V2 scratch snapshots.

    This module neither reads nor writes a working tree. Its [observed] snapshot
    is the exact precondition an adapter must re-scan before applying the
    ordered actions. *)

module Model = Yeokcham_model

type action =
  | Remove_file of Model.Path.t
  | Remove_directory of Model.Path.t
  | Ensure_directory of Model.Path.t
  | Write_file of {
      path : Model.Path.t;
      content : string;
      mode : Model.file_mode;
    }
  | Create_symlink of { path : Model.Path.t; target : string }
  | Set_file_mode of { path : Model.Path.t; mode : Model.file_mode }

type t
type replay_error = Invalid_action of string

val replay_error_to_string : replay_error -> string

val build : observed:Model.Snapshot.t -> target:Model.Snapshot.t -> t
(** [build] is deterministic. An unequal target requires [observed] as its
    safety snapshot before an effectful adapter can apply [actions]. *)

val observed : t -> Model.Snapshot.t
val target : t -> Model.Snapshot.t
val safety_snapshot : t -> Model.Snapshot.t option
val actions : t -> action list
val is_noop : t -> bool
val action_to_string : action -> string

val replay : t -> (Model.Snapshot.t, replay_error) result
(** Applies [actions] to [observed] in the pure model. A successful replay is
    exactly [target]; the effectful adapter has to enforce the same
    preconditions against the working tree. *)

(** Actions are ordered as follows: removals are deepest path first, target
    directories are shallowest first, then target file and symlink operations
    are path-ascending. A symlink replacement always has an explicit removal;
    raw symlink targets are never interpreted as paths. *)
