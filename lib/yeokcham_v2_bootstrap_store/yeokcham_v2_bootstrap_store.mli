(** Durable local-bootstrap adapter.

    The only repository bytes owned here are a signed public bootstrap record
    and private same-directory staging files. Secret capabilities are injected
    by the caller and never written beneath [root]. *)

module Bootstrap = Yeokcham_v2_bootstrap

type repository
type initialization = Initialized | Already_initialized

type error =
  | Cutover_error of Yeokcham_cutover.error
  | Not_v2_root of Yeokcham_cutover.classification
  | Bootstrap_error of Bootstrap.error
  | Missing_bootstrap of string
  | Invalid_bootstrap_path of string
  | Unexpected_bootstrap_entry of string
  | Bootstrap_already_initialized of string
  | Io_error of { operation : string; path : string; message : string }
  | Temporary_name_exhausted of string

val error_to_string : error -> string
val filename : string
val bootstrap_path : root:string -> string

val initialize : root:string -> Bootstrap.t -> (initialization, error) result
(** Create-only publication. A concurrent or repeated identical bootstrap is
    [Already_initialized]; different or malformed prior bytes are never
    overwritten. *)

val read_bootstrap : root:string -> (Bootstrap.t, error) result
(** Reads and validates only the public bootstrap record. It never consults a
    key provider and therefore grants no repository access. *)

val open_repository :
  root:string -> capability:Bootstrap.capability -> (repository, error) result

val bootstrap : repository -> Bootstrap.t
val capability : repository -> Bootstrap.capability
