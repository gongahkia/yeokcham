(** Advisory local publication/reclamation coordination from ADR-063. *)

type mode = Shared | Exclusive

type error =
  | Io_error of { operation : string; path : string; message : string }
  | Invalid_lock_path of string
  | Reentrant_upgrade of string

val error_to_string : error -> string
val lock_path : root:string -> string

val with_guard : root:string -> mode:mode -> (unit -> 'a) -> ('a, error) result
(** Holds a shared lock for an already-admitted V2 publication operation and an
    exclusive lock for reclamation. The callback must not retain the lock
    descriptor. Root admission and corrupted-state reporting stay with the
    owning adapter. *)
