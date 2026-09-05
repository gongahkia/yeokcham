(** Atomic local storage for the canonical [hooks-v1] registry. *)

type error =
  | Hook_error of Yeokcham_v1_hook.error
  | Metadata_missing of string
  | Invalid_metadata_path of string
  | Io_error of { operation : string; path : string; message : string }

val error_to_string : error -> string
val directory : root:string -> string
val path : root:string -> string
val load : root:string -> (Yeokcham_v1_hook.registry, error) result
val save : root:string -> Yeokcham_v1_hook.registry -> (unit, error) result
