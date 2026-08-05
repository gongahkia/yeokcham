type object_format = Sha1 | Sha256
type inspection = { bare : bool; object_format : object_format }

type object_id
type object_kind = Tree | Commit
type mapping_direction = Import | Export

type mapping_subject =
  | Imported_snapshot of Paengi_snapshot.Snapshot.id
  | Imported_revision of {
      capsule : Paengi_id.Capsule_id.t;
      revision : Paengi_id.Capsule_revision_id.t;
      revision_object : Paengi_store.Stored_object_id.t;
    }
  | Exported_release of {
      release : Paengi_id.Release_id.t;
      release_object : Paengi_store.Stored_object_id.t;
      final_snapshot : Paengi_snapshot.Snapshot.id;
    }
  | Exported_revision of {
      capsule : Paengi_id.Capsule_id.t;
      revision : Paengi_id.Capsule_revision_id.t;
      revision_object : Paengi_store.Stored_object_id.t;
      final_snapshot : Paengi_snapshot.Snapshot.id;
    }

type mapping

type import_result = {
  snapshot : Paengi_snapshot.Snapshot.id;
  mapping : mapping;
}

type configuration = {
  git : string;
  timeout_ms : int64;
  max_stdout_bytes : int;
  max_stderr_bytes : int;
  max_tree_bytes : int;
  max_total_tree_bytes : int;
  max_blob_bytes : int;
  max_total_blob_bytes : int;
  max_tree_entries : int;
  max_depth : int;
}

val default_configuration : configuration

val configuration_with :
  ?git:string ->
  ?timeout_ms:int64 ->
  ?max_stdout_bytes:int ->
  ?max_stderr_bytes:int ->
  ?max_tree_bytes:int ->
  ?max_total_tree_bytes:int ->
  ?max_blob_bytes:int ->
  ?max_total_blob_bytes:int ->
  ?max_tree_entries:int ->
  ?max_depth:int ->
  configuration ->
  configuration

type error =
  | Invalid_configuration of string
  | Invalid_repository_path of string
  | Git_missing of string
  | Process_failed of {
      operation : string;
      status : string;
      exit_code : int option;
      signal : int option;
      message : string option;
      stderr : string;
    }
  | Output_exceeded of { operation : string; stream : string; limit : int }
  | Malformed_output of { operation : string; detail : string }
  | Invalid_object_id of { format : object_format; value : string }
  | Invalid_tree of { identity : object_id; detail : string }
  | Unsupported_tree_mode of { identity : object_id; mode : string }
  | Import_limit_exceeded of { resource : string; limit : int; actual : int }
  | Snapshot_error of Paengi_snapshot.error
  | Mapping_error of string
  | Store_error of Paengi_store.error

val error_to_string : error -> string
val object_format_to_string : object_format -> string
val inspection_bare : inspection -> bool
val inspection_object_format : inspection -> object_format

val object_id_of_hex : object_format -> string -> (object_id, error) result
val object_id_to_hex : object_id -> string
val object_id_format : object_id -> object_format
val object_id_raw : object_id -> string

val inspect :
  ?runner:(module Paengi_validation.Process_runner) ->
  configuration ->
  repository:string ->
  (inspection, error) result

val import_tree :
  ?runner:(module Paengi_validation.Process_runner) ->
  configuration ->
  store:Paengi_store.repository ->
  repository:string ->
  tree:object_id ->
  (import_result, error) result

val mapping_id : mapping -> Paengi_id.Git_mapping_id.t
val mapping_direction : mapping -> mapping_direction
val mapping_git_object : mapping -> object_id
val mapping_kind : mapping -> object_kind
val mapping_subject : mapping -> mapping_subject

val load_mapping :
  Paengi_store.repository ->
  Paengi_id.Git_mapping_id.t ->
  (mapping, error) result
