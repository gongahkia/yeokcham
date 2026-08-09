(** Pure platform-observation normalization. Scan requests are advisory inputs
    to an exact scanner; they are never checkpoints or canonical events. *)

type path = string list

type reason =
  | Path_change
  | Rename
  | Overflow
  | Watcher_lost
  | Path_budget_exceeded

type target = Whole_root | Paths of path list
type scan_request = { reason : reason; target : target }
type error = Invalid_path of path

val error_to_string : error -> string
val max_paths_per_request : int

module Linux : sig
  type event =
    | Created of path
    | Changed of path
    | Deleted of path
    | Moved of { source : path; destination : path }
    | Queue_overflow
    | Watch_lost

  val normalize : event list -> (scan_request option, error) result
end

module Macos : sig
  type event =
    | Item_created of path
    | Item_modified of path
    | Item_removed of path
    | Item_renamed of { source : path; destination : path }
    | Kernel_dropped
    | User_dropped
    | Root_changed

  val normalize : event list -> (scan_request option, error) result
end
