(** Strict local operator configuration for the development relay.

    This configuration is not V1 project state, an object, a package, or a
    receipt. It contains no bearer secret. *)

type log_level = Error_log | Warn | Info | Debug
type t

type error =
  | Invalid_syntax of string
  | Unknown_key of string
  | Duplicate_key of string
  | Missing_key of string
  | Invalid_value of { key : string; value : string }
  | Noncanonical
  | Io_error of { path : string; operation : string; message : string }

val schema_version : int
val default : t
val error_to_string : error -> string

val create :
  storage_root:string ->
  listen:string ->
  health_listen:string ->
  metrics_listen:string ->
  credential_registry_root:string ->
  project_quota_bytes:int ->
  session_expiry_seconds:int ->
  log_level:log_level ->
  (t, error) result

val storage_root : t -> string
val listen : t -> string
val health_listen : t -> string
val metrics_listen : t -> string
val credential_registry_root : t -> string
val project_quota_bytes : t -> int
val session_expiry_seconds : t -> int
val log_level : t -> log_level
val encode : t -> string
val decode : string -> (t, error) result
val load : path:string -> (t, error) result

val override_environment : t -> (string * string) list -> (t, error) result
(** Applies only documented [YEOKCHAM_RELAY_*] names. An unknown name with that
    prefix or a duplicate documented name is refused. Other environment values
    are deliberately ignored. *)
