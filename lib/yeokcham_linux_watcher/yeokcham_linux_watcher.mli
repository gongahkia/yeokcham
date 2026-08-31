(** Advisory recursive Linux inotify source. Every output is normalized through
    [Yeokcham_watcher]; the source never scans or creates a checkpoint. The root
    [".yeokcham"] metadata subtree is excluded so daemon publication does not
    schedule itself. *)

module Watcher = Yeokcham_watcher

type t

type error =
  | Root_not_directory of string
  | Root_is_symlink of string
  | Invalid_timeout of float
  | Closed
  | Needs_restart
  | Watch_limit_exceeded of int
  | Io_error of { operation : string; path : string; message : string }
  | Normalization_error of Watcher.error

val error_to_string : error -> string
val retry_start : error -> bool
val restart_error : error -> bool
val closed_error : error -> bool
val max_watches : int

val start : root:string -> (t, error) result
(** Recursively watches a non-symlink root without following descendant
    symlinks. [start] only creates runtime kernel watches. *)

val poll : t -> timeout:float -> (Watcher.scan_request option, error) result
(** Reads one available inotify batch. Queue overflow, unmount, root loss, an
    unknown descriptor, or failure to watch a newly observed directory emits a
    whole-root watcher-loss request and requires the caller to restart it. *)

val close : t -> unit
