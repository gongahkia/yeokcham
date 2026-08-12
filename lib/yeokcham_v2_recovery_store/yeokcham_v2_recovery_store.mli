(** Durable, local-only persistence for encrypted recovery packages.

    This adapter stores only the canonical encrypted package. Recovery secrets,
    verification phrases, and recovered private keys are never accepted or
    returned by this module. *)

module Recovery = Yeokcham_v2_recovery

type initialization = Initialized | Already_initialized

type error =
  | Cutover_error of Yeokcham_cutover.error
  | Not_v2_root of Yeokcham_cutover.classification
  | Recovery_error of Recovery.error
  | Missing_recovery_package of string
  | Invalid_recovery_path of string
  | Unexpected_recovery_entry of string
  | Recovery_already_initialized of string
  | Io_error of { operation : string; path : string; message : string }
  | Temporary_name_exhausted of string

val error_to_string : error -> string
val filename : string
val recovery_path : root:string -> string

val initialize :
  root:string -> Recovery.package -> (initialization, error) result
(** Publishes one recovery package with create-only, same-directory durable
    staging. A repeated identical package is [Already_initialized]; divergent or
    malformed bytes are never replaced. *)

val read_package : root:string -> (Recovery.package, error) result
(** Reads exactly one canonical encrypted recovery package. *)
