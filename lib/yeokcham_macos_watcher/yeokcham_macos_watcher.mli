(** Advisory macOS FSEvents source. The source owns no V4 state and never scans
    or saves by itself; it only returns requests for the shared exact scanner.
*)

module Watcher = Yeokcham_watcher

type t

type raw_event =
  | Path_changed of string
  | Item_renamed of string
  | Must_scan_subdirs
  | Kernel_dropped
  | User_dropped
  | Client_overflow
  | Event_ids_wrapped
  | Root_changed
  | Unmounted

type error =
  | Root_not_directory of string
  | Root_is_symlink of string
  | Invalid_timeout of float
  | Closed
  | Needs_restart
  | Fsevents_unavailable of string
  | Io_error of { operation : string; path : string; message : string }
  | Normalization_error of Watcher.error

val max_pending_events : int
val max_pending_path_bytes : int
val error_to_string : error -> string

val start : root:string -> (t, error) result
(** [start] creates one disposable FSEvent stream for a non-symlink root. *)

val normalize :
  root:string -> raw_event list -> (Watcher.scan_request option, error) result
(** Converts native observations into conservative scan requests. Event paths
    outside the root or with unsafe components become a whole-root
    [Watcher_lost] request rather than a guessed path. *)

val poll : t -> timeout:float -> (Watcher.scan_request option, error) result
(** Waits for at most [timeout] seconds. Overflow and loss requests require the
    caller to restart the source after it has requested exact capture. *)

val close : t -> unit
(** Idempotently stops the native stream and releases its queue and pipe. *)

val retry_start : error -> bool
val restart_error : error -> bool
val closed_error : error -> bool
