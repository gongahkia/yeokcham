(** Versioned, per-user runtime discovery for a single local V2 daemon.

    Runtime files are deliberately outside the repository's canonical V2 root. A
    capability in a mode-0600 discovery file authorizes only this daemon
    session; it is not a device credential or repository authority. *)

type operation = Ping | Shutdown
type runtime_location = Xdg_runtime of string | Fallback_runtime of string
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
  | Invalid_idle_timeout of float
  | Worker_error of string
  | Io_error of { operation : string; path : string; message : string }

type serve_result = Continue | Stopped

val error_to_string : error -> string
val runtime_path : runtime_location -> string

val default_runtime_location : unit -> (runtime_location, error) result
(** Uses a private [XDG_RUNTIME_DIR/yeokcham] when available. The fallback is a
    private per-user directory below the system temporary directory; callers
    must surface that weaker lifetime guarantee. *)

val endpoint : runtime_dir:string -> root:string -> (endpoint, error) result
val socket_path : endpoint -> string
val discovery_path : endpoint -> string

val start : root:string -> runtime_dir:string -> (daemon, error) result
(** [start] requires a V2 root, creates one private listener, and publishes a
    versioned 0600 discovery file. It never modifies repository history. *)

val start_for_validated_root :
  root:string -> runtime_dir:string -> (daemon, error) result
(** Starts the same private runtime without applying the V2-only root detector.
    The caller must already have validated the repository root for its own
    model. This keeps the socket/capability protocol reusable without changing
    the V2 contract of [start]. *)

val serve_once : daemon -> (serve_result, error) result
val serve : daemon -> (unit, error) result

val serve_with :
  daemon ->
  idle_timeout:float ->
  on_idle:(unit -> (unit, string) result) ->
  (unit, error) result
(** Runs [on_idle] before every bounded socket wait. The callback is the
    runtime-only hook used by a daemon worker; its failures stop the daemon and
    are returned as [Worker_error]. *)

val close : daemon -> unit
val ping : root:string -> runtime_dir:string -> (unit, error) result
val shutdown : root:string -> runtime_dir:string -> (unit, error) result

val recover_stale : root:string -> runtime_dir:string -> (unit, error) result
(** Removes a stale socket and matching discovery file only after connection
    refusal. A live or malformed endpoint is left untouched. *)
