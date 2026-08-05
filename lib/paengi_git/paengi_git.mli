type object_format = Sha1 | Sha256
type inspection = { bare : bool; object_format : object_format }
type object_id
type object_kind = Tree | Commit | Tag
type mapping_direction = Import | Export
type tag_target_kind = Tag_commit | Tag_tree | Tag_blob

type mapping_subject =
  | Imported_snapshot of Paengi_snapshot.Snapshot.id
  | Imported_transition of {
      transition : Paengi_id.Imported_transition_id.t;
      transition_object : Paengi_store.Stored_object_id.t;
    }
  | Imported_tag of {
      tag : Paengi_id.Imported_tag_id.t;
      tag_object : Paengi_store.Stored_object_id.t;
    }
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
type imported_transition
type imported_tag

type import_result = {
  snapshot : Paengi_snapshot.Snapshot.id;
  mapping : mapping;
}

type commit_import_result = {
  imported_transition : imported_transition;
  commit_mapping : mapping;
}

type tag_import_result = { imported_tag : imported_tag; tag_mapping : mapping }

type release_export_result = {
  export_release : Paengi_id.Release_id.t;
  export_release_object : Paengi_store.Stored_object_id.t;
  export_snapshot : Paengi_snapshot.Snapshot.id;
  export_tree : object_id;
  export_commit : object_id;
  export_target_ref : string;
  export_mapping : mapping;
}

type export_failure_point = Before_git_ref | Before_mapping_binding

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
  max_commit_bytes : int;
  max_commit_parents : int;
  max_tag_bytes : int;
  max_tag_name_bytes : int;
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
  ?max_commit_bytes:int ->
  ?max_commit_parents:int ->
  ?max_tag_bytes:int ->
  ?max_tag_name_bytes:int ->
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
  | Invalid_commit of { identity : object_id; detail : string }
  | Invalid_tag of string
  | Unsupported_tree_mode of { identity : object_id; mode : string }
  | Invalid_symlink_target of { identity : object_id }
  | Unexpected_object_type of {
      identity : object_id;
      expected : string;
      actual : string;
    }
  | Import_limit_exceeded of { resource : string; limit : int; actual : int }
  | Export_limit_exceeded of { resource : string; limit : int; actual : int }
  | Unsupported_export_representation of string
  | Export_error of string
  | Release_error of Paengi_release.error
  | Injected_interruption of string
  | Snapshot_error of Paengi_snapshot.error
  | Mapping_error of string
  | Imported_transition_error of string
  | Imported_tag_error of string
  | Store_error of Paengi_store.error

val error_to_string : error -> string
val object_format_to_string : object_format -> string
val inspection_bare : inspection -> bool
val inspection_object_format : inspection -> object_format
val object_id_of_hex : object_format -> string -> (object_id, error) result
val object_id_to_hex : object_id -> string
val bytes_to_hex : string -> string
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

val import_commit :
  ?runner:(module Paengi_validation.Process_runner) ->
  configuration ->
  store:Paengi_store.repository ->
  repository:string ->
  commit:object_id ->
  (commit_import_result, error) result

val import_tag :
  ?runner:(module Paengi_validation.Process_runner) ->
  configuration ->
  store:Paengi_store.repository ->
  repository:string ->
  tag:string ->
  (tag_import_result, error) result

val export_release :
  ?runner:(module Paengi_validation.Process_runner) ->
  ?fail_at:export_failure_point ->
  configuration ->
  store:Paengi_store.repository ->
  repository:string ->
  release:Paengi_id.Release_id.t ->
  (release_export_result, error) result

val mapping_id : mapping -> Paengi_id.Git_mapping_id.t
val mapping_direction : mapping -> mapping_direction
val mapping_git_object : mapping -> object_id
val mapping_kind : mapping -> object_kind
val mapping_subject : mapping -> mapping_subject

val imported_transition_id :
  imported_transition -> Paengi_id.Imported_transition_id.t

val imported_transition_commit : imported_transition -> object_id
val imported_transition_tree : imported_transition -> object_id

val imported_transition_snapshot :
  imported_transition -> Paengi_snapshot.Snapshot.id

val imported_transition_parents : imported_transition -> object_id list
val imported_transition_author : imported_transition -> string option
val imported_transition_committer : imported_transition -> string option

val imported_transition_message :
  imported_transition -> Paengi_snapshot.Content.id option

val imported_tag_id : imported_tag -> Paengi_id.Imported_tag_id.t
val imported_tag_name : imported_tag -> string
val imported_tag_ref_object : imported_tag -> object_id
val imported_tag_target : imported_tag -> object_id
val imported_tag_target_kind : imported_tag -> tag_target_kind
val imported_tag_annotation : imported_tag -> Paengi_snapshot.Content.id option

val load_imported_transition :
  Paengi_store.repository ->
  Paengi_id.Imported_transition_id.t ->
  (imported_transition, error) result

val load_imported_tag :
  Paengi_store.repository ->
  Paengi_id.Imported_tag_id.t ->
  (imported_tag, error) result

val load_mapping :
  Paengi_store.repository ->
  Paengi_id.Git_mapping_id.t ->
  (mapping, error) result
