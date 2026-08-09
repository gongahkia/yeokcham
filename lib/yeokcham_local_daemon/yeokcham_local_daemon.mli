(** Versioned, per-user runtime discovery for a single local V2 daemon.

    Runtime files are deliberately outside the repository's canonical V2 root. A
    capability in a mode-0600 discovery file authorizes only this daemon
    session; it is not a device credential or repository authority. *)

type operation = Ping | Shutdown
type endpoint
type daemon

type error =
  | Root_unavailable of string
  | Runtime_path_rejected of string
  | Endpoint_busy of string
  | Stale_endpoint of string
  | Discovery_invalid of string
  | Protocol_invalid of string
  | Unauthorized
  | Io_error of { operation : string; path : string; message : string }

type serve_result = Continue | Stopped

val error_to_string : error -> string
val endpoint : runtime_dir:string -> root:string -> (endpoint, error) result
val socket_path : endpoint -> string
val discovery_path : endpoint -> string

val start : root:string -> runtime_dir:string -> (daemon, error) result
(** [start] requires a V2 root, creates one private listener, and publishes a
    versioned 0600 discovery file. It never modifies repository history. *)

val serve_once : daemon -> (serve_result, error) result
val serve : daemon -> (unit, error) result
val close : daemon -> unit
val ping : root:string -> runtime_dir:string -> (unit, error) result
val shutdown : root:string -> runtime_dir:string -> (unit, error) result

val recover_stale : root:string -> runtime_dir:string -> (unit, error) result
(** Removes a stale socket and matching discovery file only after connection
    refusal. A live or malformed endpoint is left untouched. *)
