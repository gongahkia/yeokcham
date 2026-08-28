(** Local-only V4 relay aliases. These records are never signed or packaged. *)

type remote = { name : string; url : string }

type error =
  | Invalid_url of string
  | Duplicate_remote of string
  | Unknown_remote of string
  | Io_error of { path : string; operation : string; message : string }
  | Encoding_error of string

val error_to_string : error -> string
val path : root:string -> string
val list : root:string -> (remote list, error) result
val find : root:string -> name:string -> (remote, error) result
val add : root:string -> name:string -> url:string -> (unit, error) result
val remove : root:string -> name:string -> (unit, error) result
