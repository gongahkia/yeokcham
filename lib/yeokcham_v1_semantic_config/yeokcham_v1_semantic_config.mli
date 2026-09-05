(** Local-only configuration for optional external LSP inspection.

    These records select an already-installed executable. They are never V1
    project state, signed data, package content, or relay input. *)

type match_scope =
  | Extensions of string list
  | Path_globs of string list
  | All_files

type overlap_sensitivity = Same_symbol | Nearby_ranges | References

type server = {
  name : string;
  program : string;
  arguments : string list;
  enabled : bool;
  match_scope : match_scope;
  overlap_sensitivity : overlap_sensitivity;
}

type error =
  | Invalid_name of string
  | Invalid_program of string
  | Invalid_argument of string
  | Invalid_extension of string
  | Invalid_glob of string
  | Invalid_match_scope of string
  | Duplicate_server of string
  | Unknown_server of string
  | Io_error of { path : string; operation : string; message : string }
  | Encoding_error of string

val error_to_string : error -> string
val path : root:string -> string
val encode : server list -> (string, error) result
val decode : string -> (server list, error) result
val list : root:string -> (server list, error) result
val find : root:string -> name:string -> (server, error) result
val add : root:string -> server:server -> (unit, error) result
val remove : root:string -> name:string -> (unit, error) result

val set_enabled :
  root:string -> name:string -> enabled:bool -> (unit, error) result

val configure :
  root:string ->
  name:string ->
  match_scope:match_scope ->
  overlap_sensitivity:overlap_sensitivity ->
  (unit, error) result

val matches_path : server -> string -> bool
(** [matches_path server path] accepts a repository-relative slash-separated
    file path only. Invalid paths and malformed stored globs do not match. *)

val match_scope_to_string : match_scope -> string
val overlap_sensitivity_to_string : overlap_sensitivity -> string
