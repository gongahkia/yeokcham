type object_format = Sha1 | Sha256
type inspection = { bare : bool; object_format : object_format }
type object_id
type object_kind = Tree | Commit | Tag
type mapping_direction = Import | Export
type tag_target_kind = Tag_commit | Tag_tree | Tag_blob

type mapping_subject =
  | Imported_snapshot of Yeokcham_snapshot.Snapshot.id
  | Imported_transition of {
      transition : Yeokcham_id.Imported_transition_id.t;
      transition_object : Yeokcham_store.Stored_object_id.t;
    }
  | Imported_tag of {
      tag : Yeokcham_id.Imported_tag_id.t;
      tag_object : Yeokcham_store.Stored_object_id.t;
    }
  | Imported_revision of {
      capsule : Yeokcham_id.Capsule_id.t;
      revision : Yeokcham_id.Capsule_revision_id.t;
      revision_object : Yeokcham_store.Stored_object_id.t;
    }
  | Exported_release of {
      release : Yeokcham_id.Release_id.t;
      release_object : Yeokcham_store.Stored_object_id.t;
      final_snapshot : Yeokcham_snapshot.Snapshot.id;
    }
  | Exported_revision of {
      capsule : Yeokcham_id.Capsule_id.t;
      revision : Yeokcham_id.Capsule_revision_id.t;
      revision_object : Yeokcham_store.Stored_object_id.t;
      final_snapshot : Yeokcham_snapshot.Snapshot.id;
    }

type mapping
type imported_transition
type imported_tag
type archive
type archive_ref = { archive_ref_name : string; archive_ref_object : object_id }

type archive_capability = {
  archive_source_bare : bool;
  archive_source_object_format : object_format;
}

type import_result = {
  snapshot : Yeokcham_snapshot.Snapshot.id;
  mapping : mapping;
}

type commit_import_result = {
  imported_transition : imported_transition;
  commit_mapping : mapping;
}

type tag_import_result = { imported_tag : imported_tag; tag_mapping : mapping }
type git_identity = { git_identity_name : string; git_identity_email : string }

type release_export_metadata = {
  release_export_author : git_identity;
  release_export_committer : git_identity;
  release_export_message : string;
}

type release_export_result = {
  export_release : Yeokcham_id.Release_id.t;
  export_release_object : Yeokcham_store.Stored_object_id.t;
  export_snapshot : Yeokcham_snapshot.Snapshot.id;
  export_tree : object_id;
  export_commit : object_id;
  export_target_ref : string;
  export_mapping : mapping;
}

type revision_export_result = {
  revision_export_source : Yeokcham_capsule_store.revision_link;
  revision_export_snapshot : Yeokcham_snapshot.Snapshot.id;
  revision_export_tree : object_id;
  revision_export_commit : object_id;
  revision_export_mapping : mapping;
}

type revision_sequence_export_result = {
  revision_exports : revision_export_result list;
  revision_export_target_ref : string;
}

type export_failure_point =
  | Before_git_ref
  | Before_mapping_binding
  | Before_revision_mapping_binding of int

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
  max_export_commits : int;
  max_archive_bytes : int;
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
  ?max_export_commits:int ->
  ?max_archive_bytes:int ->
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
  | Capsule_error of Yeokcham_capsule_store.error
  | Release_error of Yeokcham_release.error
  | Injected_interruption of string
  | Snapshot_error of Yeokcham_snapshot.error
  | Mapping_error of string
  | Imported_transition_error of string
  | Imported_tag_error of string
  | Archive_error of string
  | Store_error of Yeokcham_store.error

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
  ?runner:(module Yeokcham_validation.Process_runner) ->
  configuration ->
  repository:string ->
  (inspection, error) result

val import_tree :
  ?runner:(module Yeokcham_validation.Process_runner) ->
  configuration ->
  store:Yeokcham_store.repository ->
  repository:string ->
  tree:object_id ->
  (import_result, error) result

val import_commit :
  ?runner:(module Yeokcham_validation.Process_runner) ->
  configuration ->
  store:Yeokcham_store.repository ->
  repository:string ->
  commit:object_id ->
  (commit_import_result, error) result

val import_tag :
  ?runner:(module Yeokcham_validation.Process_runner) ->
  configuration ->
  store:Yeokcham_store.repository ->
  repository:string ->
  tag:string ->
  (tag_import_result, error) result

val export_release :
  ?metadata:release_export_metadata ->
  ?runner:(module Yeokcham_validation.Process_runner) ->
  ?fail_at:export_failure_point ->
  configuration ->
  store:Yeokcham_store.repository ->
  repository:string ->
  release:Yeokcham_id.Release_id.t ->
  (release_export_result, error) result

val export_revisions :
  ?runner:(module Yeokcham_validation.Process_runner) ->
  ?fail_at:export_failure_point ->
  configuration ->
  store:Yeokcham_store.repository ->
  repository:string ->
  revisions:Yeokcham_capsule_store.revision_link list ->
  (revision_sequence_export_result, error) result

val archive_repository :
  ?runner:(module Yeokcham_validation.Process_runner) ->
  ?refs:string list ->
  configuration ->
  store:Yeokcham_store.repository ->
  repository:string ->
  (archive, error) result

val load_archive :
  Yeokcham_store.repository ->
  Yeokcham_id.Git_archive_id.t ->
  (archive, error) result

val list_archives : Yeokcham_store.repository -> (archive list, error) result

val exit_archive :
  ?runner:(module Yeokcham_validation.Process_runner) ->
  configuration ->
  store:Yeokcham_store.repository ->
  archive:Yeokcham_id.Git_archive_id.t ->
  destination:string ->
  (archive, error) result

val archive_id : archive -> Yeokcham_id.Git_archive_id.t
val archive_object_format : archive -> object_format
val archive_refs : archive -> archive_ref list
val archive_bundle : archive -> Yeokcham_snapshot.Content.id
val archive_capability : archive -> archive_capability option
val mapping_id : mapping -> Yeokcham_id.Git_mapping_id.t
val mapping_direction : mapping -> mapping_direction
val mapping_git_object : mapping -> object_id
val mapping_kind : mapping -> object_kind
val mapping_subject : mapping -> mapping_subject

val imported_transition_id :
  imported_transition -> Yeokcham_id.Imported_transition_id.t

val imported_transition_commit : imported_transition -> object_id
val imported_transition_tree : imported_transition -> object_id

val imported_transition_snapshot :
  imported_transition -> Yeokcham_snapshot.Snapshot.id

val imported_transition_parents : imported_transition -> object_id list
val imported_transition_author : imported_transition -> string option
val imported_transition_committer : imported_transition -> string option

val imported_transition_message :
  imported_transition -> Yeokcham_snapshot.Content.id option

module Legacy_format : sig
  val create_imported_transition_v1 :
    commit:object_id ->
    tree:object_id ->
    snapshot:Yeokcham_snapshot.Snapshot.id ->
    parents:object_id list ->
    (imported_transition, error) result

  val transition_envelope :
    imported_transition -> (Yeokcham_envelope.t, error) result

  val encode_transition_binding :
    Yeokcham_id.Imported_transition_id.t ->
    Yeokcham_store.Stored_object_id.t ->
    (string, error) result

  val create_mapping_v2 :
    direction:mapping_direction ->
    git_object:object_id ->
    git_kind:object_kind ->
    subject:mapping_subject ->
    (mapping, error) result

  val mapping_envelope : mapping -> (Yeokcham_envelope.t, error) result

  val encode_mapping_binding :
    Yeokcham_id.Git_mapping_id.t ->
    Yeokcham_store.Stored_object_id.t ->
    (string, error) result
end

val imported_tag_id : imported_tag -> Yeokcham_id.Imported_tag_id.t
val imported_tag_name : imported_tag -> string
val imported_tag_ref_object : imported_tag -> object_id
val imported_tag_target : imported_tag -> object_id
val imported_tag_target_kind : imported_tag -> tag_target_kind

val imported_tag_annotation :
  imported_tag -> Yeokcham_snapshot.Content.id option

val load_imported_transition :
  Yeokcham_store.repository ->
  Yeokcham_id.Imported_transition_id.t ->
  (imported_transition, error) result

val load_imported_tag :
  Yeokcham_store.repository ->
  Yeokcham_id.Imported_tag_id.t ->
  (imported_tag, error) result

val load_mapping :
  Yeokcham_store.repository ->
  Yeokcham_id.Git_mapping_id.t ->
  (mapping, error) result
