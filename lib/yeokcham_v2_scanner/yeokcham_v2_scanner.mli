(** Exact V2 working-tree scanner with no persistence or key access. *)

module Model = Yeokcham_model

type error =
  | Root_not_directory of string
  | Io_error of { operation : string; path : string; message : string }
  | File_too_large of { path : string; size : int; limit : int }
  | Snapshot_too_large of { size : int; limit : int }
  | Unsupported_file_type of { path : string; kind : string }
  | Invalid_ignore_path of { line : int; path : string }
  | Path_error of { path : string; error : Model.Path.error }
  | Snapshot_error of Model.construction_error

val error_to_string : error -> string
val max_ignore_bytes : int
val max_snapshot_bytes : int

val scan : root:string -> (Model.Snapshot.t, error) result
(** Recursively scans one real directory using [lstat]. It excludes only the
    root [.yeokcham] metadata directory, supports exact safe [.yeokchamignore]
    path-prefix rules, preserves regular bytes/executable mode and
    symlink-target bytes, and follows no symlinks. It never writes a snapshot,
    object, cache, or ref. *)
