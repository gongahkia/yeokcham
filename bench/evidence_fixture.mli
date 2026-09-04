(** Deterministic external source-tree fixtures for EVIDENCE-001.

    This is benchmark support, not a V4 record or model value. It never opens a
    Yeokcham store, materialises a receipt, or infers user intent. *)

type profile = { requested_path_count : int; requested_logical_bytes : int64 }

type layout = {
  generated_directories : int;
  generated_files : int;
  generated_logical_bytes : int64;
}

type error =
  | Relative_root of string
  | Root_missing of string
  | Root_not_directory of string
  | Root_not_empty of string
  | Path_count_too_small of int
  | Logical_bytes_too_small of { bytes : int64; minimum : int }
  | Io_error of { path : string; operation : string; message : string }

val error_to_string : error -> string
val profile : path_count:int -> logical_bytes:int64 -> profile

val validate : profile -> (layout, error) result
(** A valid profile has at least one directory and one regular file. The exact
    generated entry count is [requested_path_count], and every file has at least
    one byte. *)

val directory_count : layout -> int
val file_count : layout -> int
val logical_bytes : layout -> int64

val generate : root:string -> profile -> (layout, error) result
(** [root] must be an absolute, existing, empty directory. Generation creates
    exactly the layout returned by [validate], with deterministic distinct file
    bytes whose total is [requested_logical_bytes]. *)
