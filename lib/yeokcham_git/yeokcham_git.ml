module Validation = Yeokcham_validation
module Capsule_store = Yeokcham_capsule_store
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Hash = Yeokcham_hash.Sha256
module Id = Yeokcham_id
module Release = Yeokcham_release
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

let ( let* ) = Result.bind

type object_format = Sha1 | Sha256
type inspection = { bare : bool; object_format : object_format }

let object_format_to_string = function Sha1 -> "sha1" | Sha256 -> "sha256"

type object_id = { format : object_format; raw : string }
type object_kind = Tree | Commit | Tag
type mapping_direction = Import | Export
type tag_target_kind = Tag_commit | Tag_tree | Tag_blob

let raw_to_hex raw =
  let digits = "0123456789abcdef" in
  let encoded = Bytes.create (String.length raw * 2) in
  String.iteri
    (fun index character ->
      let value = Char.code character in
      Bytes.set encoded (index * 2) digits.[value lsr 4];
      Bytes.set encoded ((index * 2) + 1) digits.[value land 0x0f])
    raw;
  Bytes.unsafe_to_string encoded

let object_id_to_hex identity = raw_to_hex identity.raw
let bytes_to_hex = raw_to_hex

type mapping_subject =
  | Imported_snapshot of Snapshot.Snapshot.id
  | Imported_transition of {
      transition : Id.Imported_transition_id.t;
      transition_object : Store.Stored_object_id.t;
    }
  | Imported_tag of {
      tag : Id.Imported_tag_id.t;
      tag_object : Store.Stored_object_id.t;
    }
  | Imported_revision of {
      capsule : Id.Capsule_id.t;
      revision : Id.Capsule_revision_id.t;
      revision_object : Store.Stored_object_id.t;
    }
  | Exported_release of {
      release : Id.Release_id.t;
      release_object : Store.Stored_object_id.t;
      final_snapshot : Snapshot.Snapshot.id;
    }
  | Exported_revision of {
      capsule : Id.Capsule_id.t;
      revision : Id.Capsule_revision_id.t;
      revision_object : Store.Stored_object_id.t;
      final_snapshot : Snapshot.Snapshot.id;
    }

type mapping = {
  version : int;
  id : Id.Git_mapping_id.t;
  direction : mapping_direction;
  git_object : object_id;
  git_kind : object_kind;
  subject : mapping_subject;
}

type import_result = { snapshot : Snapshot.Snapshot.id; mapping : mapping }

type transition_metadata = {
  author : string;
  committer : string;
  message : Snapshot.Content.id;
}

type imported_transition = {
  transition_id : Id.Imported_transition_id.t;
  transition_commit : object_id;
  transition_tree : object_id;
  transition_snapshot : Snapshot.Snapshot.id;
  transition_parents : object_id list;
  transition_metadata : transition_metadata option;
}

type commit_import_result = {
  imported_transition : imported_transition;
  commit_mapping : mapping;
}

type imported_tag = {
  tag_id : Id.Imported_tag_id.t;
  tag_name : string;
  tag_ref_object : object_id;
  tag_target : object_id;
  tag_target_kind : tag_target_kind;
  tag_annotation : Snapshot.Content.id option;
}

type tag_import_result = { imported_tag : imported_tag; tag_mapping : mapping }
type archive_ref = { archive_ref_name : string; archive_ref_object : object_id }

type archive_capability = {
  archive_source_bare : bool;
  archive_source_object_format : object_format;
}

type archive = {
  archive_version : int;
  archive_identity : Id.Git_archive_id.t;
  archive_format : object_format;
  archive_source_capability : archive_capability option;
  archive_content : Snapshot.Content.id;
  archive_ref_inventory : archive_ref list;
}

type adoption = {
  adoption_identity : Id.Git_adoption_id.t;
  adoption_archive : Id.Git_archive_id.t;
  adoption_format : object_format;
  adoption_commit : object_id;
  adoption_parent : object_id option;
  adoption_transition : Id.Imported_transition_id.t;
  adoption_mapping : Id.Git_mapping_id.t;
  adoption_parent_transition : Id.Imported_transition_id.t option;
  adoption_parent_mapping : Id.Git_mapping_id.t option;
  adoption_capsule : Id.Capsule_id.t;
  adoption_revision : Id.Capsule_revision_id.t;
  adoption_source : Scratch.Checkpoint_id.t;
  adoption_target : Scratch.Checkpoint_id.t;
}

type lineage_node = {
  lineage_node_identity : Id.Git_lineage_node_id.t;
  lineage_node_archive : Id.Git_archive_id.t;
  lineage_node_format : object_format;
  lineage_node_commit : object_id;
  lineage_node_transition : Id.Imported_transition_id.t;
  lineage_node_mapping : Id.Git_mapping_id.t;
  lineage_node_snapshot : Snapshot.Snapshot.id;
  lineage_node_parents : Id.Git_lineage_node_id.t list;
}

type lineage_ref = {
  lineage_ref_name : string;
  lineage_ref_object : object_id;
  lineage_ref_head : Id.Git_lineage_node_id.t option;
}

type lineage = {
  lineage_identity : Id.Git_lineage_id.t;
  lineage_archive : Id.Git_archive_id.t;
  lineage_format : object_format;
  lineage_refs : lineage_ref list;
}

type lineage_result = {
  lineage : lineage;
  lineage_nodes : lineage_node list;
}

type git_identity = { git_identity_name : string; git_identity_email : string }

type release_export_metadata = {
  release_export_author : git_identity;
  release_export_committer : git_identity;
  release_export_message : string;
}

type release_export_result = {
  export_release : Id.Release_id.t;
  export_release_object : Store.Stored_object_id.t;
  export_snapshot : Snapshot.Snapshot.id;
  export_tree : object_id;
  export_commit : object_id;
  export_target_ref : string;
  export_mapping : mapping;
}

type revision_export_result = {
  revision_export_source : Capsule_store.revision_link;
  revision_export_snapshot : Snapshot.Snapshot.id;
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

let default_configuration =
  {
    git = "git";
    timeout_ms = 5_000L;
    max_stdout_bytes = 1_024;
    max_stderr_bytes = 4_096;
    max_tree_bytes = 8 * 1024 * 1024;
    max_total_tree_bytes = 64 * 1024 * 1024;
    max_blob_bytes = Store.max_object_bytes;
    max_total_blob_bytes = 2 * Store.max_object_bytes;
    max_tree_entries = 100_000;
    max_depth = 256;
    max_commit_bytes = 8 * 1024 * 1024;
    max_commit_parents = 4_096;
    max_tag_bytes = 8 * 1024 * 1024;
    max_tag_name_bytes = 1_024;
    max_export_commits = 4_096;
    max_archive_bytes = 256 * 1024 * 1024;
  }

let configuration_with ?git ?timeout_ms ?max_stdout_bytes ?max_stderr_bytes
    ?max_tree_bytes ?max_total_tree_bytes ?max_blob_bytes ?max_total_blob_bytes
    ?max_tree_entries ?max_depth ?max_commit_bytes ?max_commit_parents
    ?max_tag_bytes ?max_tag_name_bytes ?max_export_commits ?max_archive_bytes
    configuration =
  {
    git = Option.value ~default:configuration.git git;
    timeout_ms = Option.value ~default:configuration.timeout_ms timeout_ms;
    max_stdout_bytes =
      Option.value ~default:configuration.max_stdout_bytes max_stdout_bytes;
    max_stderr_bytes =
      Option.value ~default:configuration.max_stderr_bytes max_stderr_bytes;
    max_tree_bytes =
      Option.value ~default:configuration.max_tree_bytes max_tree_bytes;
    max_total_tree_bytes =
      Option.value ~default:configuration.max_total_tree_bytes
        max_total_tree_bytes;
    max_blob_bytes =
      Option.value ~default:configuration.max_blob_bytes max_blob_bytes;
    max_total_blob_bytes =
      Option.value ~default:configuration.max_total_blob_bytes
        max_total_blob_bytes;
    max_tree_entries =
      Option.value ~default:configuration.max_tree_entries max_tree_entries;
    max_depth = Option.value ~default:configuration.max_depth max_depth;
    max_commit_bytes =
      Option.value ~default:configuration.max_commit_bytes max_commit_bytes;
    max_commit_parents =
      Option.value ~default:configuration.max_commit_parents max_commit_parents;
    max_tag_bytes =
      Option.value ~default:configuration.max_tag_bytes max_tag_bytes;
    max_tag_name_bytes =
      Option.value ~default:configuration.max_tag_name_bytes max_tag_name_bytes;
    max_export_commits =
      Option.value ~default:configuration.max_export_commits max_export_commits;
    max_archive_bytes =
      Option.value ~default:configuration.max_archive_bytes max_archive_bytes;
  }

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
  | Capsule_error of Capsule_store.error
  | Release_error of Release.error
  | Injected_interruption of string
  | Snapshot_error of Snapshot.error
  | Mapping_error of string
  | Imported_transition_error of string
  | Imported_tag_error of string
  | Archive_error of string
  | Adoption_error of string
  | Lineage_error of string
  | Store_error of Store.error

let error_to_string = function
  | Invalid_configuration detail -> "invalid Git configuration: " ^ detail
  | Invalid_repository_path detail -> "invalid Git repository path: " ^ detail
  | Git_missing executable -> "Git executable is unavailable: " ^ executable
  | Process_failed { operation; status; exit_code; signal; message; stderr } ->
      Printf.sprintf "Git %s failed (%s exit=%s signal=%s message=%s stderr=%S)"
        operation status
        (Option.fold ~none:"none" ~some:string_of_int exit_code)
        (Option.fold ~none:"none" ~some:string_of_int signal)
        (Option.value ~default:"none" message)
        stderr
  | Output_exceeded { operation; stream; limit } ->
      Printf.sprintf "Git %s %s exceeded %d bytes" operation stream limit
  | Malformed_output { operation; detail } ->
      Printf.sprintf "Git %s returned malformed output: %s" operation detail
  | Invalid_object_id { format; value } ->
      Printf.sprintf "invalid %s Git object ID: %S"
        (object_format_to_string format)
        value
  | Invalid_tree { identity; detail } ->
      Printf.sprintf "invalid Git tree %s: %s"
        (object_id_to_hex identity)
        detail
  | Invalid_commit { identity; detail } ->
      Printf.sprintf "invalid Git commit %s: %s"
        (object_id_to_hex identity)
        detail
  | Invalid_tag detail -> "invalid Git tag: " ^ detail
  | Unsupported_tree_mode { identity; mode } ->
      Printf.sprintf "unsupported Git tree mode %S in %s" mode
        (object_id_to_hex identity)
  | Invalid_symlink_target { identity } ->
      Printf.sprintf "Git symlink target contains NUL bytes: %s"
        (object_id_to_hex identity)
  | Unexpected_object_type { identity; expected; actual } ->
      Printf.sprintf "Git object %s has type %s, expected %s"
        (object_id_to_hex identity)
        actual expected
  | Import_limit_exceeded { resource; limit; actual } ->
      Printf.sprintf "Git import %s limit exceeded (%d > %d)" resource actual
        limit
  | Export_limit_exceeded { resource; limit; actual } ->
      Printf.sprintf "Git export %s limit exceeded (%d > %d)" resource actual
        limit
  | Unsupported_export_representation detail ->
      "unsupported Git export representation: " ^ detail
  | Export_error detail -> "Git export error: " ^ detail
  | Capsule_error error -> Capsule_store.error_to_string error
  | Release_error error -> Release.error_to_string error
  | Injected_interruption point -> "injected interruption: " ^ point
  | Snapshot_error error -> Snapshot.error_to_string error
  | Mapping_error detail -> "Git mapping error: " ^ detail
  | Imported_transition_error detail -> "imported transition error: " ^ detail
  | Imported_tag_error detail -> "imported tag error: " ^ detail
  | Archive_error detail -> "Git archive error: " ^ detail
  | Adoption_error detail -> "Git adoption error: " ^ detail
  | Lineage_error detail -> "Git lineage error: " ^ detail
  | Store_error error -> Store.error_to_string error

let inspection_bare inspection = inspection.bare
let inspection_object_format inspection = inspection.object_format
let maximum_repository_path_bytes = 4_096

let executable_path executable =
  if String.contains executable '/' then
    try
      Unix.access executable [ Unix.X_OK ];
      Some executable
    with Unix.Unix_error _ -> None
  else
    match Sys.getenv_opt "PATH" with
    | None -> None
    | Some path ->
        String.split_on_char ':' path
        |> List.find_map (fun directory ->
            let candidate = Filename.concat directory executable in
            try
              Unix.access candidate [ Unix.X_OK ];
              Some candidate
            with Unix.Unix_error _ -> None)

let validate_configuration configuration =
  if
    String.is_empty configuration.git
    || String.contains configuration.git '\000'
  then
    Error
      (Invalid_configuration
         "git executable must be nonempty and contain no NUL")
  else if Int64.compare configuration.timeout_ms 0L <= 0 then
    Error (Invalid_configuration "timeout must be positive")
  else if
    configuration.max_stdout_bytes <= 0 || configuration.max_stderr_bytes < 0
  then Error (Invalid_configuration "output limits are invalid")
  else if
    configuration.max_tree_bytes <= 0
    || configuration.max_total_tree_bytes <= 0
    || configuration.max_blob_bytes <= 0
    || configuration.max_total_blob_bytes <= 0
    || configuration.max_tree_entries <= 0
    || configuration.max_depth <= 0
    || configuration.max_commit_bytes <= 0
    || configuration.max_commit_parents <= 0
    || configuration.max_tag_bytes <= 0
    || configuration.max_tag_name_bytes <= 0
    || configuration.max_export_commits <= 0
    || configuration.max_archive_bytes <= 0
  then Error (Invalid_configuration "Git import limits must be positive")
  else if configuration.max_blob_bytes > Store.max_object_bytes then
    Error
      (Invalid_configuration
         (Printf.sprintf
            "Git blob limit exceeds Yeokcham object limit (%d > %d)"
            configuration.max_blob_bytes Store.max_object_bytes))
  else if configuration.max_total_tree_bytes < configuration.max_tree_bytes then
    Error
      (Invalid_configuration
         "total Git tree limit must be at least the single-tree limit")
  else if configuration.max_total_blob_bytes < configuration.max_blob_bytes then
    Error
      (Invalid_configuration
         "total Git blob limit must be at least the single-blob limit")
  else Ok configuration

let validate_repository_path repository =
  if String.is_empty repository then
    Error (Invalid_repository_path "path is empty")
  else if String.length repository > maximum_repository_path_bytes then
    Error
      (Invalid_repository_path
         (Printf.sprintf "path exceeds %d bytes" maximum_repository_path_bytes))
  else if String.contains repository '\000' then
    Error (Invalid_repository_path "path contains NUL")
  else if Filename.is_relative repository then
    Error (Invalid_repository_path "path must be absolute")
  else
    try
      if (Unix.stat repository).Unix.st_kind <> Unix.S_DIR then
        Error (Invalid_repository_path "path is not a directory")
      else Ok repository
    with Unix.Unix_error (error, _, _) ->
      Error (Invalid_repository_path (Unix.error_message error))

let status_to_string status =
  if status = Validation.Passed then "passed"
  else if status = Validation.Failed then "failed"
  else if status = Validation.Timed_out then "timed-out"
  else if status = Validation.Execution_error then "execution-error"
  else "unknown"

let single_line ~operation output =
  let length = String.length output in
  let end_ =
    if length > 0 && Char.equal output.[length - 1] '\n' then length - 1
    else length
  in
  let end_ =
    if end_ > 0 && Char.equal output.[end_ - 1] '\r' then end_ - 1 else end_
  in
  let line = String.sub output 0 end_ in
  if String.is_empty line then
    Error (Malformed_output { operation; detail = "empty line" })
  else if
    String.contains line '\000'
    || String.contains line '\n' || String.contains line '\r'
  then Error (Malformed_output { operation; detail = "expected one text line" })
  else Ok line

let command ?(environment = []) configuration executable repository arguments =
  {
    Validation.executable;
    arguments = "-C" :: repository :: arguments;
    working_directory = [];
    timeout_ms = configuration.timeout_ms;
    max_stdout_bytes = configuration.max_stdout_bytes;
    max_stderr_bytes = configuration.max_stderr_bytes;
    environment_policy = Validation.Empty;
    environment =
      List.sort
        (fun (left, _) (right, _) -> String.compare left right)
        environment;
    retain_output = false;
    format_version = 1L;
    mandatory_features = 0L;
  }

let run ?(runner = (module Validation.Unix_runner : Validation.Process_runner))
    ?(environment = []) configuration executable repository ~operation arguments
    =
  let module Runner = (val runner : Validation.Process_runner) in
  let result =
    Runner.run
      (command ~environment configuration executable repository arguments)
      ~working_directory:"/"
  in
  if result.Validation.runner_stdout.Validation.truncated then
    Error
      (Output_exceeded
         {
           operation;
           stream = "stdout";
           limit = configuration.max_stdout_bytes;
         })
  else if result.Validation.runner_stderr.Validation.truncated then
    Error
      (Output_exceeded
         {
           operation;
           stream = "stderr";
           limit = configuration.max_stderr_bytes;
         })
  else if result.Validation.runner_status = Validation.Passed then
    Ok result.Validation.runner_stdout.Validation.retained
  else
    Error
      (Process_failed
         {
           operation;
           status = status_to_string result.Validation.runner_status;
           exit_code = result.Validation.runner_exit_code;
           signal = result.Validation.runner_signal;
           message = result.Validation.runner_execution_error;
           stderr = result.Validation.runner_stderr.Validation.retained;
         })

let parse_boolean ~operation = function
  | "true" -> Ok true
  | "false" -> Ok false
  | _ ->
      Error (Malformed_output { operation; detail = "expected true or false" })

let parse_object_format ~operation = function
  | "sha1" -> Ok Sha1
  | "sha256" -> Ok Sha256
  | _ ->
      Error (Malformed_output { operation; detail = "expected sha1 or sha256" })

let inspect ?runner configuration ~repository =
  let ( let* ) = Result.bind in
  let* configuration = validate_configuration configuration in
  let* repository = validate_repository_path repository in
  let* executable =
    match executable_path configuration.git with
    | Some executable -> Ok executable
    | None -> Error (Git_missing configuration.git)
  in
  let* bare =
    let* output =
      run ?runner configuration executable repository
        ~operation:"is-bare-repository"
        [ "rev-parse"; "--is-bare-repository" ]
    in
    let* line = single_line ~operation:"is-bare-repository" output in
    parse_boolean ~operation:"is-bare-repository" line
  in
  let* object_format =
    let* output =
      run ?runner configuration executable repository
        ~operation:"show-object-format"
        [ "rev-parse"; "--show-object-format" ]
    in
    let* line = single_line ~operation:"show-object-format" output in
    parse_object_format ~operation:"show-object-format" line
  in
  Ok { bare; object_format }

let object_id_length = function Sha1 -> 20 | Sha256 -> 32

let object_id_of_raw format raw =
  if String.length raw = object_id_length format then Ok { format; raw }
  else Error (Invalid_object_id { format; value = raw_to_hex raw })

let hex_nibble = function
  | '0' .. '9' as character -> Some (Char.code character - Char.code '0')
  | 'a' .. 'f' as character -> Some (Char.code character - Char.code 'a' + 10)
  | 'A' .. 'F' as character -> Some (Char.code character - Char.code 'A' + 10)
  | _ -> None

let object_id_of_hex format hex =
  let expected = object_id_length format * 2 in
  if String.length hex <> expected then
    Error (Invalid_object_id { format; value = hex })
  else
    let raw = Bytes.create (expected / 2) in
    let rec decode offset =
      if offset = expected then Ok { format; raw = Bytes.unsafe_to_string raw }
      else
        match (hex_nibble hex.[offset], hex_nibble hex.[offset + 1]) with
        | Some high, Some low ->
            Bytes.set raw (offset / 2) (Char.chr ((high lsl 4) lor low));
            decode (offset + 2)
        | None, _ -> Error (Invalid_object_id { format; value = hex })
        | _, None -> Error (Invalid_object_id { format; value = hex })
    in
    decode 0

let object_id_format identity = identity.format
let object_id_raw identity = identity.raw

let run_bytes
    ?(runner = (module Validation.Unix_runner : Validation.Process_runner))
    ?(environment = []) configuration executable repository ~operation
    ~max_stdout_bytes arguments =
  let module Runner = (val runner : Validation.Process_runner) in
  let command =
    {
      Validation.executable;
      arguments = "-C" :: repository :: arguments;
      working_directory = [];
      timeout_ms = configuration.timeout_ms;
      max_stdout_bytes;
      max_stderr_bytes = configuration.max_stderr_bytes;
      environment_policy = Validation.Empty;
      environment =
        List.sort
          (fun (left, _) (right, _) -> String.compare left right)
          environment;
      retain_output = false;
      format_version = 1L;
      mandatory_features = 0L;
    }
  in
  let result = Runner.run command ~working_directory:"/" in
  if result.Validation.runner_stdout.Validation.truncated then
    Error
      (Output_exceeded
         { operation; stream = "stdout"; limit = max_stdout_bytes })
  else if result.Validation.runner_stderr.Validation.truncated then
    Error
      (Output_exceeded
         {
           operation;
           stream = "stderr";
           limit = configuration.max_stderr_bytes;
         })
  else if result.Validation.runner_status = Validation.Passed then
    Ok result.Validation.runner_stdout.Validation.retained
  else
    Error
      (Process_failed
         {
           operation;
           status = status_to_string result.Validation.runner_status;
           exit_code = result.Validation.runner_exit_code;
           signal = result.Validation.runner_signal;
           message = result.Validation.runner_execution_error;
           stderr = result.Validation.runner_stderr.Validation.retained;
         })

let verify_exact_object_type ?runner configuration executable repository
    ~identity ~kind =
  let* type_output =
    run ?runner configuration executable repository ~operation:"cat-file-type"
      [ "--no-replace-objects"; "cat-file"; "-t"; object_id_to_hex identity ]
  in
  let* actual = single_line ~operation:"cat-file-type" type_output in
  if not (String.equal actual kind) then
    Error (Unexpected_object_type { identity; expected = kind; actual })
  else Ok ()

let read_exact_object ?runner configuration executable repository ~identity
    ~kind ~limit =
  let* () =
    verify_exact_object_type ?runner configuration executable repository
      ~identity ~kind
  in

  run_bytes ?runner configuration executable repository
    ~operation:("cat-file-" ^ kind) ~max_stdout_bytes:limit
    [ "--no-replace-objects"; "cat-file"; kind; object_id_to_hex identity ]

type tree_entry = { mode : string; name : string; object_id : object_id }

let rec find_byte input character offset =
  if offset >= String.length input then None
  else if Char.equal input.[offset] character then Some offset
  else find_byte input character (offset + 1)

let tree_key entry =
  entry.name ^ if String.equal entry.mode "40000" then "/" else "\000"

let valid_tree_name name =
  (not (String.is_empty name))
  && (not (String.equal name "."))
  && (not (String.equal name ".."))
  && (not (String.contains name '/'))
  && not (String.contains name '\000')

let parse_tree_entries ~max_entries identity bytes =
  let length = String.length bytes in
  let object_id_bytes = object_id_length identity.format in
  let rec parse offset count previous_name previous_key reversed =
    if offset = length then Ok (List.rev reversed)
    else if count = max_entries then
      Error
        (Import_limit_exceeded
           {
             resource = "tree entries";
             limit = max_entries;
             actual = count + 1;
           })
    else
      match find_byte bytes ' ' offset with
      | None ->
          Error
            (Invalid_tree
               { identity; detail = "entry mode is not terminated by a space" })
      | Some mode_end -> (
          let mode = String.sub bytes offset (mode_end - offset) in
          let name_start = mode_end + 1 in
          match find_byte bytes '\000' name_start with
          | None ->
              Error
                (Invalid_tree
                   { identity; detail = "entry name is not NUL-terminated" })
          | Some name_end ->
              let name = String.sub bytes name_start (name_end - name_start) in
              let object_start = name_end + 1 in
              let next = object_start + object_id_bytes in
              if String.is_empty mode then
                Error
                  (Invalid_tree { identity; detail = "entry mode is empty" })
              else if not (valid_tree_name name) then
                Error
                  (Invalid_tree
                     {
                       identity;
                       detail = Printf.sprintf "unsafe entry name %S" name;
                     })
              else if next > length then
                Error
                  (Invalid_tree
                     { identity; detail = "entry object ID is truncated" })
              else
                let raw = String.sub bytes object_start object_id_bytes in
                let entry =
                  { mode; name; object_id = { format = identity.format; raw } }
                in
                let key = tree_key entry in
                let* () =
                  match previous_name with
                  | Some previous when String.equal previous name ->
                      Error
                        (Invalid_tree
                           {
                             identity;
                             detail =
                               Printf.sprintf "duplicate entry name %S" name;
                           })
                  | _ -> Ok ()
                in
                let* () =
                  match previous_key with
                  | Some previous when String.compare previous key >= 0 ->
                      Error
                        (Invalid_tree
                           {
                             identity;
                             detail =
                               "entries are not in canonical Git tree order";
                           })
                  | _ -> Ok ()
                in
                parse next (count + 1) (Some name) (Some key) (entry :: reversed)
          )
  in
  parse 0 0 None None []

let mapping_domain = function
  | 1 -> "yeokcham:git-mapping:v1\000"
  | 2 -> "yeokcham:git-mapping:v2\000"
  | 3 -> "yeokcham:git-mapping:v3\000"
  | _ -> assert false

let mapping_binding_domain = function
  | 1 -> "yeokcham:git-mapping-binding:v1\000"
  | 2 -> "yeokcham:git-mapping-binding:v2\000"
  | 3 -> "yeokcham:git-mapping-binding:v3\000"
  | _ -> assert false

let mapping_array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Mapping_error (Encoding.construction_error_to_string error))

let mapping_identity_value label raw =
  if String.length raw = 32 then Ok (Encoding.bytes raw)
  else
    Error
      (Mapping_error
         (Printf.sprintf "%s must be exactly 32 bytes, got %d" label
            (String.length raw)))

let mapping_object_id_value identity =
  let format = match identity.format with Sha1 -> 1L | Sha256 -> 2L in
  mapping_array [ Encoding.integer format; Encoding.bytes identity.raw ]

let mapping_subject_value = function
  | Imported_snapshot snapshot ->
      let* snapshot =
        mapping_identity_value "imported snapshot ID"
          (Snapshot.Snapshot.stored_object_id snapshot
          |> Store.Stored_object_id.to_raw_bytes)
      in
      mapping_array [ Encoding.integer 0L; snapshot ]
  | Imported_transition { transition; transition_object } ->
      let* transition =
        mapping_identity_value "imported transition ID"
          (Id.Imported_transition_id.to_bytes transition)
      in
      let* transition_object =
        mapping_identity_value "imported transition object ID"
          (Store.Stored_object_id.to_raw_bytes transition_object)
      in
      mapping_array [ Encoding.integer 4L; transition; transition_object ]
  | Imported_tag { tag; tag_object } ->
      let* tag =
        mapping_identity_value "imported tag ID"
          (Id.Imported_tag_id.to_bytes tag)
      in
      let* tag_object =
        mapping_identity_value "imported tag object ID"
          (Store.Stored_object_id.to_raw_bytes tag_object)
      in
      mapping_array [ Encoding.integer 5L; tag; tag_object ]
  | Imported_revision { capsule; revision; revision_object } ->
      let* capsule =
        mapping_identity_value "imported capsule ID"
          (Id.Capsule_id.to_bytes capsule)
      in
      let* revision =
        mapping_identity_value "imported revision ID"
          (Id.Capsule_revision_id.to_bytes revision)
      in
      let* revision_object =
        mapping_identity_value "imported revision object ID"
          (Store.Stored_object_id.to_raw_bytes revision_object)
      in
      mapping_array [ Encoding.integer 1L; capsule; revision; revision_object ]
  | Exported_release { release; release_object; final_snapshot } ->
      let* release =
        mapping_identity_value "exported release ID"
          (Id.Release_id.to_bytes release)
      in
      let* release_object =
        mapping_identity_value "exported release object ID"
          (Store.Stored_object_id.to_raw_bytes release_object)
      in
      let* final_snapshot =
        mapping_identity_value "exported final snapshot ID"
          (Snapshot.Snapshot.stored_object_id final_snapshot
          |> Store.Stored_object_id.to_raw_bytes)
      in
      mapping_array
        [ Encoding.integer 2L; release; release_object; final_snapshot ]
  | Exported_revision { capsule; revision; revision_object; final_snapshot } ->
      let* capsule =
        mapping_identity_value "exported capsule ID"
          (Id.Capsule_id.to_bytes capsule)
      in
      let* revision =
        mapping_identity_value "exported revision ID"
          (Id.Capsule_revision_id.to_bytes revision)
      in
      let* revision_object =
        mapping_identity_value "exported revision object ID"
          (Store.Stored_object_id.to_raw_bytes revision_object)
      in
      let* final_snapshot =
        mapping_identity_value "exported final snapshot ID"
          (Snapshot.Snapshot.stored_object_id final_snapshot
          |> Store.Stored_object_id.to_raw_bytes)
      in
      mapping_array
        [
          Encoding.integer 3L;
          capsule;
          revision;
          revision_object;
          final_snapshot;
        ]

let direction_code = function Import -> 0L | Export -> 1L
let kind_code = function Tree -> 1L | Commit -> 2L | Tag -> 3L

let valid_mapping_combination_v1 direction kind subject =
  match (direction, kind, subject) with
  | Import, Tree, Imported_snapshot _ -> true
  | Import, Commit, Imported_revision _ -> true
  | Export, Commit, Exported_release _ | Export, Commit, Exported_revision _ ->
      true
  | ( Import,
      Commit,
      ( Imported_snapshot _ | Imported_transition _ | Imported_tag _
      | Exported_release _ | Exported_revision _ ) )
  | ( Import,
      Tree,
      ( Imported_transition _ | Imported_tag _ | Imported_revision _
      | Exported_release _ | Exported_revision _ ) )
  | Export, (Tree | Tag), _
  | ( Export,
      Commit,
      ( Imported_snapshot _ | Imported_transition _ | Imported_tag _
      | Imported_revision _ ) )
  | Import, Tag, _ ->
      false

let valid_mapping_combination version direction kind subject =
  let v1 = valid_mapping_combination_v1 direction kind subject in
  let v2 =
    v1
    || direction = Import && kind = Commit
       &&
       match subject with
       | Imported_transition _ -> true
       | Imported_snapshot _ | Imported_tag _ | Imported_revision _
       | Exported_release _ | Exported_revision _ ->
           false
  in
  (Int.equal version 1 && v1)
  || (Int.equal version 2 && v2)
  || Int.equal version 3
     && (v2
        || direction = Import && kind = Tag
           &&
           match subject with
           | Imported_tag _ -> true
           | Imported_snapshot _ | Imported_transition _ | Imported_revision _
           | Exported_release _ | Exported_revision _ ->
               false)

let mapping_identity_payload ~version ~direction ~git_object ~git_kind ~subject
    =
  let* git_object = mapping_object_id_value git_object in
  let* subject = mapping_subject_value subject in
  mapping_array
    [
      Encoding.integer (Int64.of_int version);
      Encoding.integer (direction_code direction);
      Encoding.integer (kind_code git_kind);
      git_object;
      subject;
    ]

let derive_mapping_id ~version ~direction ~git_object ~git_kind ~subject =
  let* identity =
    mapping_identity_payload ~version ~direction ~git_object ~git_kind ~subject
  in
  let raw =
    Hash.feed_string Hash.empty (mapping_domain version) |> fun context ->
    Hash.feed_string context (Encoding.encode identity)
    |> Hash.get |> Hash.to_raw_string
  in
  match Id.Git_mapping_id.of_bytes raw with
  | Ok identity -> Ok identity
  | Error error -> Error (Mapping_error (Id.parse_error_to_string error))

let create_mapping_with_version version ~direction ~git_object ~git_kind
    ~subject =
  if not (valid_mapping_combination version direction git_kind subject) then
    Error (Mapping_error "invalid mapping direction, Git kind, and subject")
  else
    let* id =
      derive_mapping_id ~version ~direction ~git_object ~git_kind ~subject
    in
    Ok { version; id; direction; git_object; git_kind; subject }

let create_mapping ~direction ~git_object ~git_kind ~subject =
  create_mapping_with_version 1 ~direction ~git_object ~git_kind ~subject

let mapping_payload mapping =
  let* identity =
    mapping_identity_payload ~version:mapping.version
      ~direction:mapping.direction ~git_object:mapping.git_object
      ~git_kind:mapping.git_kind ~subject:mapping.subject
  in
  let* id =
    mapping_identity_value "Git mapping ID"
      (Id.Git_mapping_id.to_bytes mapping.id)
  in
  mapping_array
    [
      Encoding.integer (Int64.of_int mapping.version);
      id;
      Encoding.integer (direction_code mapping.direction);
      Encoding.integer (kind_code mapping.git_kind);
      (match identity with
      | Encoding.Array [ _; _; _; object_id; _ ] -> object_id
      | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
      | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
          assert false);
      (match identity with
      | Encoding.Array [ _; _; _; _; subject ] -> subject
      | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
      | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
          assert false);
    ]

let mapping_envelope mapping =
  let* payload = mapping_payload mapping in
  Envelope.create ~object_type:Envelope.Git_mapping
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error ->
      Mapping_error (Envelope.creation_error_to_string error))

let mapping_fields name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error
        (Mapping_error (Printf.sprintf "%s must contain %d values" name length))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Mapping_error (name ^ " must be an array"))

let mapping_integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Mapping_error (name ^ " must be an integer"))

let mapping_bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Mapping_error (name ^ " must be bytes"))

let mapping_raw_id name parser value =
  let* raw = mapping_bytes name value in
  if String.length raw <> 32 then
    Error
      (Mapping_error
         (Printf.sprintf "%s must be exactly 32 bytes, got %d" name
            (String.length raw)))
  else
    parser raw
    |> Result.map_error (fun error ->
        Mapping_error (Id.parse_error_to_string error))

let mapping_stored_id name value =
  let* raw = mapping_bytes name value in
  match Store.Stored_object_id.of_raw_bytes raw with
  | Some identity -> Ok identity
  | None ->
      Error
        (Mapping_error
           (Printf.sprintf "%s must be exactly 32 bytes, got %d" name
              (String.length raw)))

let mapping_direction_of_code = function
  | 0L -> Ok Import
  | 1L -> Ok Export
  | value ->
      Error
        (Mapping_error (Printf.sprintf "unknown mapping direction: %Ld" value))

let object_kind_of_code = function
  | 1L -> Ok Tree
  | 2L -> Ok Commit
  | 3L -> Ok Tag
  | value ->
      Error
        (Mapping_error (Printf.sprintf "unknown Git object kind: %Ld" value))

let decode_object_id value =
  let* fields = mapping_fields "Git object ID" 2 value in
  match fields with
  | [ format; raw ] ->
      let* format = mapping_integer "Git object format" format in
      let* format =
        match format with
        | 1L -> Ok Sha1
        | 2L -> Ok Sha256
        | value ->
            Error
              (Mapping_error
                 (Printf.sprintf "unknown Git object format: %Ld" value))
      in
      let* raw = mapping_bytes "Git object ID bytes" raw in
      object_id_of_raw format raw
  | _ -> assert false

let decode_mapping_subject value =
  let* values =
    match value with
    | Encoding.Array [] -> Error (Mapping_error "Git mapping subject is empty")
    | Encoding.Array values -> Ok values
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        Error (Mapping_error "Git mapping subject must be an array")
  in
  match values with
  | tag :: fields ->
      let* tag = mapping_integer "Git mapping subject tag" tag in
      if Int64.equal tag 0L then
        match fields with
        | [ snapshot ] ->
            let* snapshot = mapping_stored_id "imported snapshot ID" snapshot in
            Ok
              (Imported_snapshot
                 (Snapshot.Snapshot.of_stored_object_id snapshot))
        | _ ->
            Error (Mapping_error "imported snapshot subject has invalid length")
      else if Int64.equal tag 4L then
        match fields with
        | [ transition; transition_object ] ->
            let* transition =
              mapping_raw_id "imported transition ID"
                Id.Imported_transition_id.of_bytes transition
            in
            let* transition_object =
              mapping_stored_id "imported transition object ID"
                transition_object
            in
            Ok (Imported_transition { transition; transition_object })
        | _ ->
            Error
              (Mapping_error "imported transition subject has invalid length")
      else if Int64.equal tag 5L then
        match fields with
        | [ tag; tag_object ] ->
            let* tag =
              mapping_raw_id "imported tag ID" Id.Imported_tag_id.of_bytes tag
            in
            let* tag_object =
              mapping_stored_id "imported tag object ID" tag_object
            in
            Ok (Imported_tag { tag; tag_object })
        | _ -> Error (Mapping_error "imported tag subject has invalid length")
      else if Int64.equal tag 1L then
        match fields with
        | [ capsule; revision; revision_object ] ->
            let* capsule =
              mapping_raw_id "imported capsule ID" Id.Capsule_id.of_bytes
                capsule
            in
            let* revision =
              mapping_raw_id "imported revision ID"
                Id.Capsule_revision_id.of_bytes revision
            in
            let* revision_object =
              mapping_stored_id "imported revision object ID" revision_object
            in
            Ok (Imported_revision { capsule; revision; revision_object })
        | _ ->
            Error (Mapping_error "imported revision subject has invalid length")
      else if Int64.equal tag 2L then
        match fields with
        | [ release; release_object; final_snapshot ] ->
            let* release =
              mapping_raw_id "exported release ID" Id.Release_id.of_bytes
                release
            in
            let* release_object =
              mapping_stored_id "exported release object ID" release_object
            in
            let* final_snapshot =
              mapping_stored_id "exported final snapshot ID" final_snapshot
            in
            Ok
              (Exported_release
                 {
                   release;
                   release_object;
                   final_snapshot =
                     Snapshot.Snapshot.of_stored_object_id final_snapshot;
                 })
        | _ ->
            Error (Mapping_error "exported release subject has invalid length")
      else if Int64.equal tag 3L then
        match fields with
        | [ capsule; revision; revision_object; final_snapshot ] ->
            let* capsule =
              mapping_raw_id "exported capsule ID" Id.Capsule_id.of_bytes
                capsule
            in
            let* revision =
              mapping_raw_id "exported revision ID"
                Id.Capsule_revision_id.of_bytes revision
            in
            let* revision_object =
              mapping_stored_id "exported revision object ID" revision_object
            in
            let* final_snapshot =
              mapping_stored_id "exported final snapshot ID" final_snapshot
            in
            Ok
              (Exported_revision
                 {
                   capsule;
                   revision;
                   revision_object;
                   final_snapshot =
                     Snapshot.Snapshot.of_stored_object_id final_snapshot;
                 })
        | _ ->
            Error (Mapping_error "exported revision subject has invalid length")
      else
        Error
          (Mapping_error
             (Printf.sprintf "unknown Git mapping subject tag: %Ld" tag))
  | [] -> assert false

let decode_mapping_payload value =
  let* fields = mapping_fields "Git mapping" 6 value in
  match fields with
  | [ version; supplied_id; direction; git_kind; git_object; subject ] ->
      let* version = mapping_integer "Git mapping version" version in
      if
        not
          (Int64.equal version 1L || Int64.equal version 2L
         || Int64.equal version 3L)
      then
        Error
          (Mapping_error
             (Printf.sprintf "unsupported Git mapping version: %Ld" version))
      else
        let* supplied_id =
          mapping_raw_id "Git mapping ID" Id.Git_mapping_id.of_bytes supplied_id
        in
        let* direction = mapping_integer "Git mapping direction" direction in
        let* direction = mapping_direction_of_code direction in
        let* git_kind = mapping_integer "Git object kind" git_kind in
        let* git_kind = object_kind_of_code git_kind in
        let* git_object = decode_object_id git_object in
        let* subject = decode_mapping_subject subject in
        let version = Int64.to_int version in
        let* mapping =
          create_mapping_with_version version ~direction ~git_object ~git_kind
            ~subject
        in
        if not (Id.Git_mapping_id.equal supplied_id mapping.id) then
          Error
            (Mapping_error "Git mapping logical ID does not match its preimage")
        else
          let* canonical = mapping_payload mapping in
          if String.equal (Encoding.encode canonical) (Encoding.encode value)
          then Ok mapping
          else Error (Mapping_error "Git mapping payload is noncanonical")
  | _ -> assert false

let mapping_binding_body version logical physical =
  let* logical =
    mapping_identity_value "Git mapping ID" (Id.Git_mapping_id.to_bytes logical)
  in
  let* physical =
    mapping_identity_value "Git mapping object ID"
      (Store.Stored_object_id.to_raw_bytes physical)
  in
  mapping_array [ Encoding.integer (Int64.of_int version); logical; physical ]

let mapping_binding_checksum version body =
  Hash.feed_string Hash.empty (mapping_binding_domain version) |> fun context ->
  Hash.feed_string context (Encoding.encode body)
  |> Hash.get |> Hash.to_raw_string

let encode_mapping_binding version logical physical =
  let* body = mapping_binding_body version logical physical in
  let checksum = Encoding.bytes (mapping_binding_checksum version body) in
  let* encoded =
    mapping_array
      [
        Encoding.integer (Int64.of_int version);
        (match body with
        | Encoding.Array [ _; logical; _ ] -> logical
        | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
        | Encoding.Map _ | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
            assert false);
        (match body with
        | Encoding.Array [ _; _; physical ] -> physical
        | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
        | Encoding.Map _ | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
            assert false);
        checksum;
      ]
  in
  Ok (Encoding.encode encoded)

let decode_mapping_binding bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error ->
        Mapping_error (Encoding.decode_error_to_string error))
  in
  let* fields = mapping_fields "Git mapping binding" 4 value in
  match fields with
  | [ version; logical; physical; supplied_checksum ] ->
      let* version = mapping_integer "Git mapping binding version" version in
      if
        not
          (Int64.equal version 1L || Int64.equal version 2L
         || Int64.equal version 3L)
      then
        Error
          (Mapping_error
             (Printf.sprintf "unsupported Git mapping binding version: %Ld"
                version))
      else
        let version = Int64.to_int version in
        let* logical =
          mapping_raw_id "Git mapping binding ID" Id.Git_mapping_id.of_bytes
            logical
        in
        let* physical =
          mapping_stored_id "Git mapping binding object ID" physical
        in
        let* supplied_checksum =
          mapping_bytes "Git mapping binding checksum" supplied_checksum
        in
        if String.length supplied_checksum <> 32 then
          Error (Mapping_error "Git mapping binding checksum must be 32 bytes")
        else
          let* body = mapping_binding_body version logical physical in
          let expected_checksum = mapping_binding_checksum version body in
          if not (String.equal expected_checksum supplied_checksum) then
            Error (Mapping_error "Git mapping binding checksum mismatch")
          else
            let* canonical = encode_mapping_binding version logical physical in
            if String.equal canonical bytes then Ok (version, logical, physical)
            else
              Error (Mapping_error "Git mapping binding bytes are noncanonical")
  | _ -> assert false

let mapping_ref_components logical =
  [ "git-mappings"; Id.Git_mapping_id.to_hex logical ]

let publish_mapping store mapping =
  let* envelope = mapping_envelope mapping in
  let* physical =
    Store.put store envelope
    |> Result.map_error (fun error -> Store_error error)
  in
  let* binding = encode_mapping_binding mapping.version mapping.id physical in
  Store.with_lock store ~name:"git-mappings"
    ~on_error:(fun error -> Store_error error)
    (fun () ->
      let components = mapping_ref_components mapping.id in
      let* current =
        Store.Ref_file.read store ~components
        |> Result.map_error (fun error -> Store_error error)
      in
      match current with
      | None ->
          Store.Ref_file.compare_and_swap store ~components ~expected:None
            ~replacement:binding
          |> Result.map_error (fun error -> Store_error error)
      | Some current ->
          let* current_version, current_id, current_object =
            decode_mapping_binding current
          in
          if
            Int.equal current_version mapping.version
            && Id.Git_mapping_id.equal current_id mapping.id
            && Store.Stored_object_id.equal current_object physical
          then Ok ()
          else
            Error
              (Mapping_error
                 "Git mapping ID already has a different immutable binding"))
  |> Result.map (fun () -> mapping)

let transition_v1_domain = "yeokcham:imported-transition:v1\000"
let transition_v2_domain = "yeokcham:imported-transition:v2\000"
let transition_binding_domain = "yeokcham:imported-transition-binding:v1\000"

let transition_array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Imported_transition_error (Encoding.construction_error_to_string error))

let transition_identity_value label raw =
  if String.length raw = 32 then Ok (Encoding.bytes raw)
  else
    Error
      (Imported_transition_error
         (Printf.sprintf "%s must be exactly 32 bytes, got %d" label
            (String.length raw)))

let transition_object_id_value identity =
  let format = match identity.format with Sha1 -> 1L | Sha256 -> 2L in
  transition_array [ Encoding.integer format; Encoding.bytes identity.raw ]

let transition_object_id_of_value value = decode_object_id value

let transition_snapshot_value snapshot =
  transition_identity_value "imported transition snapshot ID"
    (Snapshot.Snapshot.stored_object_id snapshot
    |> Store.Stored_object_id.to_raw_bytes)

let transition_parent_values parents =
  let rec loop reversed = function
    | [] -> transition_array (List.rev reversed)
    | parent :: rest ->
        let* parent = transition_object_id_value parent in
        loop (parent :: reversed) rest
  in
  loop [] parents

let transition_identity_payload ~commit ~tree ~snapshot ~parents =
  let* commit = transition_object_id_value commit in
  let* tree = transition_object_id_value tree in
  let* snapshot = transition_snapshot_value snapshot in
  let* parents = transition_parent_values parents in
  transition_array [ Encoding.integer 1L; commit; tree; snapshot; parents ]

let transition_metadata_value label value =
  if String.is_empty value then
    Error (Imported_transition_error (label ^ " must not be empty"))
  else if String.contains value '\000' || String.contains value '\n' then
    Error
      (Imported_transition_error
         (label ^ " must not contain NUL or newline bytes"))
  else Ok (Encoding.bytes value)

let transition_message_value message =
  transition_identity_value "imported transition message content ID"
    (Snapshot.Content.stored_object_id message
    |> Store.Stored_object_id.to_raw_bytes)

let transition_v2_identity_payload ~commit ~tree ~snapshot ~parents ~author
    ~committer ~message =
  let* commit = transition_object_id_value commit in
  let* tree = transition_object_id_value tree in
  let* snapshot = transition_snapshot_value snapshot in
  let* parents = transition_parent_values parents in
  let* author = transition_metadata_value "imported transition author" author in
  let* committer =
    transition_metadata_value "imported transition committer" committer
  in
  let* message = transition_message_value message in
  transition_array
    [
      Encoding.integer 2L;
      commit;
      tree;
      snapshot;
      parents;
      author;
      committer;
      message;
    ]

let object_id_equal left right =
  left.format = right.format && String.equal left.raw right.raw

let object_id_compare left right =
  match (left.format, right.format) with
  | Sha1, Sha256 -> -1
  | Sha256, Sha1 -> 1
  | Sha1, Sha1 | Sha256, Sha256 -> String.compare left.raw right.raw

let valid_transition_parents commit parents =
  let rec loop seen = function
    | [] -> Ok ()
    | parent :: rest ->
        if parent.format <> commit.format then
          Error
            (Imported_transition_error
               "parent Git object format differs from commit format")
        else if object_id_equal parent commit then
          Error
            (Imported_transition_error "commit cannot name itself as a parent")
        else if List.exists (object_id_equal parent) seen then
          Error (Imported_transition_error "commit parent IDs must be unique")
        else loop (parent :: seen) rest
  in
  loop [] parents

let derive_transition_id ~commit ~tree ~snapshot ~parents =
  let* identity =
    transition_identity_payload ~commit ~tree ~snapshot ~parents
  in
  let raw =
    Hash.feed_string Hash.empty transition_v1_domain |> fun context ->
    Hash.feed_string context (Encoding.encode identity)
    |> Hash.get |> Hash.to_raw_string
  in
  Id.Imported_transition_id.of_bytes raw
  |> Result.map_error (fun error ->
      Imported_transition_error (Id.parse_error_to_string error))

let derive_transition_v2_id ~commit ~tree ~snapshot ~parents ~author ~committer
    ~message =
  let* identity =
    transition_v2_identity_payload ~commit ~tree ~snapshot ~parents ~author
      ~committer ~message
  in
  let raw =
    Hash.feed_string Hash.empty transition_v2_domain |> fun context ->
    Hash.feed_string context (Encoding.encode identity)
    |> Hash.get |> Hash.to_raw_string
  in
  Id.Imported_transition_id.of_bytes raw
  |> Result.map_error (fun error ->
      Imported_transition_error (Id.parse_error_to_string error))

let create_imported_transition ~commit ~tree ~snapshot ~parents =
  if tree.format <> commit.format then
    Error
      (Imported_transition_error
         "tree Git object format differs from commit format")
  else
    let* () = valid_transition_parents commit parents in
    let* id = derive_transition_id ~commit ~tree ~snapshot ~parents in
    Ok
      {
        transition_id = id;
        transition_commit = commit;
        transition_tree = tree;
        transition_snapshot = snapshot;
        transition_parents = parents;
        transition_metadata = None;
      }

let create_imported_transition_v2 ~commit ~tree ~snapshot ~parents ~author
    ~committer ~message =
  if tree.format <> commit.format then
    Error
      (Imported_transition_error
         "tree Git object format differs from commit format")
  else
    let* () = valid_transition_parents commit parents in
    let* id =
      derive_transition_v2_id ~commit ~tree ~snapshot ~parents ~author
        ~committer ~message
    in
    Ok
      {
        transition_id = id;
        transition_commit = commit;
        transition_tree = tree;
        transition_snapshot = snapshot;
        transition_parents = parents;
        transition_metadata = Some { author; committer; message };
      }

let transition_payload transition =
  let* id =
    transition_identity_value "imported transition ID"
      (Id.Imported_transition_id.to_bytes transition.transition_id)
  in
  match transition.transition_metadata with
  | None -> (
      let* identity =
        transition_identity_payload ~commit:transition.transition_commit
          ~tree:transition.transition_tree
          ~snapshot:transition.transition_snapshot
          ~parents:transition.transition_parents
      in
      match identity with
      | Encoding.Array [ _; commit; tree; snapshot; parents ] ->
          transition_array
            [ Encoding.integer 1L; id; commit; tree; snapshot; parents ]
      | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
      | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
          assert false)
  | Some { author; committer; message } -> (
      let* identity =
        transition_v2_identity_payload ~commit:transition.transition_commit
          ~tree:transition.transition_tree
          ~snapshot:transition.transition_snapshot
          ~parents:transition.transition_parents ~author ~committer ~message
      in
      match identity with
      | Encoding.Array
          [ _; commit; tree; snapshot; parents; author; committer; message ] ->
          transition_array
            [
              Encoding.integer 2L;
              id;
              commit;
              tree;
              snapshot;
              parents;
              author;
              committer;
              message;
            ]
      | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
      | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
          assert false)

let transition_envelope transition =
  let* payload = transition_payload transition in
  Envelope.create ~object_type:Envelope.Imported_transition
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error ->
      Imported_transition_error (Envelope.creation_error_to_string error))

let transition_fields name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error
        (Imported_transition_error
           (Printf.sprintf "%s must contain %d values" name length))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Imported_transition_error (name ^ " must be an array"))

let transition_integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Imported_transition_error (name ^ " must be an integer"))

let transition_bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Imported_transition_error (name ^ " must be bytes"))

let transition_raw_id name parser value =
  let* raw = transition_bytes name value in
  if String.length raw <> 32 then
    Error
      (Imported_transition_error
         (Printf.sprintf "%s must be exactly 32 bytes, got %d" name
            (String.length raw)))
  else
    parser raw
    |> Result.map_error (fun error ->
        Imported_transition_error (Id.parse_error_to_string error))

let transition_stored_id name value =
  let* raw = transition_bytes name value in
  match Store.Stored_object_id.of_raw_bytes raw with
  | Some identity -> Ok identity
  | None ->
      Error
        (Imported_transition_error
           (Printf.sprintf "%s must be exactly 32 bytes, got %d" name
              (String.length raw)))

let decode_transition_parents commit value =
  let* values =
    match value with
    | Encoding.Array values -> Ok values
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        Error (Imported_transition_error "commit parent IDs must be an array")
  in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
        let* parent = transition_object_id_of_value value in
        loop (parent :: reversed) rest
  in
  let* parents = loop [] values in
  let* () = valid_transition_parents commit parents in
  Ok parents

let decoded_transition_id value =
  transition_raw_id "imported transition ID" Id.Imported_transition_id.of_bytes
    value

let decoded_transition_snapshot value =
  let* snapshot =
    transition_stored_id "imported transition snapshot ID" value
  in
  Ok (Snapshot.Snapshot.of_stored_object_id snapshot)

let verify_decoded_transition value supplied_id transition =
  if not (Id.Imported_transition_id.equal supplied_id transition.transition_id)
  then
    Error
      (Imported_transition_error
         "imported transition logical ID does not match its preimage")
  else
    let* canonical = transition_payload transition in
    if String.equal (Encoding.encode canonical) (Encoding.encode value) then
      Ok transition
    else
      Error
        (Imported_transition_error "imported transition payload is noncanonical")

let decode_transition_v1 value =
  let* fields = transition_fields "imported transition v1" 6 value in
  match fields with
  | [ version; supplied_id; commit; tree; snapshot; parents ] ->
      let* version = transition_integer "imported transition version" version in
      if not (Int64.equal version 1L) then assert false
      else
        let* supplied_id = decoded_transition_id supplied_id in
        let* commit = transition_object_id_of_value commit in
        let* tree = transition_object_id_of_value tree in
        let* snapshot = decoded_transition_snapshot snapshot in
        let* parents = decode_transition_parents commit parents in
        let* transition =
          create_imported_transition ~commit ~tree ~snapshot ~parents
        in
        verify_decoded_transition value supplied_id transition
  | _ -> assert false

let decode_transition_v2 value =
  let* fields = transition_fields "imported transition v2" 9 value in
  match fields with
  | [
   version;
   supplied_id;
   commit;
   tree;
   snapshot;
   parents;
   author;
   committer;
   message;
  ] ->
      let* version = transition_integer "imported transition version" version in
      if not (Int64.equal version 2L) then assert false
      else
        let* supplied_id = decoded_transition_id supplied_id in
        let* commit = transition_object_id_of_value commit in
        let* tree = transition_object_id_of_value tree in
        let* snapshot = decoded_transition_snapshot snapshot in
        let* parents = decode_transition_parents commit parents in
        let* author = transition_bytes "imported transition author" author in
        let* committer =
          transition_bytes "imported transition committer" committer
        in
        let* message =
          transition_stored_id "imported transition message content ID" message
        in
        let message = Snapshot.Content.of_stored_object_id message in
        let* transition =
          create_imported_transition_v2 ~commit ~tree ~snapshot ~parents ~author
            ~committer ~message
        in
        verify_decoded_transition value supplied_id transition
  | _ -> assert false

let decode_transition_payload value =
  match value with
  | Encoding.Array (version :: _) ->
      let* version = transition_integer "imported transition version" version in
      if Int64.equal version 1L then decode_transition_v1 value
      else if Int64.equal version 2L then decode_transition_v2 value
      else
        Error
          (Imported_transition_error
             (Printf.sprintf "unsupported imported transition version: %Ld"
                version))
  | Encoding.Array []
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error
        (Imported_transition_error
           "imported transition must be a nonempty array")

let transition_binding_body logical physical =
  let* logical =
    transition_identity_value "imported transition ID"
      (Id.Imported_transition_id.to_bytes logical)
  in
  let* physical =
    transition_identity_value "imported transition object ID"
      (Store.Stored_object_id.to_raw_bytes physical)
  in
  transition_array [ Encoding.integer 1L; logical; physical ]

let transition_binding_checksum body =
  Hash.feed_string Hash.empty transition_binding_domain |> fun context ->
  Hash.feed_string context (Encoding.encode body)
  |> Hash.get |> Hash.to_raw_string

let encode_transition_binding logical physical =
  let* body = transition_binding_body logical physical in
  let checksum = Encoding.bytes (transition_binding_checksum body) in
  match body with
  | Encoding.Array [ _; logical; physical ] ->
      let* encoded =
        transition_array [ Encoding.integer 1L; logical; physical; checksum ]
      in
      Ok (Encoding.encode encoded)
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
      assert false

let decode_transition_binding bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error ->
        Imported_transition_error (Encoding.decode_error_to_string error))
  in
  let* fields = transition_fields "imported transition binding" 4 value in
  match fields with
  | [ version; logical; physical; supplied_checksum ] ->
      let* version =
        transition_integer "imported transition binding version" version
      in
      if not (Int64.equal version 1L) then
        Error
          (Imported_transition_error
             (Printf.sprintf
                "unsupported imported transition binding version: %Ld" version))
      else
        let* logical =
          transition_raw_id "imported transition binding ID"
            Id.Imported_transition_id.of_bytes logical
        in
        let* physical =
          transition_stored_id "imported transition binding object ID" physical
        in
        let* supplied_checksum =
          transition_bytes "imported transition binding checksum"
            supplied_checksum
        in
        if String.length supplied_checksum <> 32 then
          Error
            (Imported_transition_error
               "imported transition binding checksum must be 32 bytes")
        else
          let* body = transition_binding_body logical physical in
          let expected_checksum = transition_binding_checksum body in
          if not (String.equal expected_checksum supplied_checksum) then
            Error
              (Imported_transition_error
                 "imported transition binding checksum mismatch")
          else
            let* canonical = encode_transition_binding logical physical in
            if String.equal canonical bytes then Ok (logical, physical)
            else
              Error
                (Imported_transition_error
                   "imported transition binding bytes are noncanonical")
  | _ -> assert false

let transition_ref_components logical =
  [ "imported-transitions"; Id.Imported_transition_id.to_hex logical ]

let publish_transition store transition =
  let* envelope = transition_envelope transition in
  let* physical =
    Store.put store envelope
    |> Result.map_error (fun error -> Store_error error)
  in
  let* binding = encode_transition_binding transition.transition_id physical in
  Store.with_lock store ~name:"imported-transitions"
    ~on_error:(fun error -> Store_error error)
    (fun () ->
      let components = transition_ref_components transition.transition_id in
      let* current =
        Store.Ref_file.read store ~components
        |> Result.map_error (fun error -> Store_error error)
      in
      match current with
      | None ->
          Store.Ref_file.compare_and_swap store ~components ~expected:None
            ~replacement:binding
          |> Result.map_error (fun error -> Store_error error)
      | Some current ->
          let* current_id, current_object = decode_transition_binding current in
          if
            Id.Imported_transition_id.equal current_id transition.transition_id
            && Store.Stored_object_id.equal current_object physical
          then Ok ()
          else
            Error
              (Imported_transition_error
                 "imported transition ID already has a different immutable \
                  binding"))
  |> Result.map (fun () -> (transition, physical))

let load_transition_binding store logical =
  let components = transition_ref_components logical in
  let* binding =
    Store.Ref_file.read store ~components
    |> Result.map_error (fun error -> Store_error error)
  in
  let* binding =
    match binding with
    | Some binding -> Ok binding
    | None ->
        Error
          (Imported_transition_error "imported transition binding is absent")
  in
  let* bound_id, physical = decode_transition_binding binding in
  if not (Id.Imported_transition_id.equal bound_id logical) then
    Error
      (Imported_transition_error
         "imported transition binding logical ID disagrees with its path")
  else
    let* envelope =
      Store.get store physical
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type envelope <> Envelope.Imported_transition then
      Error
        (Imported_transition_error
           (Printf.sprintf "expected imported transition object type 24, got %d"
              (Envelope.object_type_code (Envelope.object_type envelope))))
    else
      let* transition = decode_transition_payload (Envelope.payload envelope) in
      if not (Id.Imported_transition_id.equal transition.transition_id logical)
      then
        Error
          (Imported_transition_error
             "imported transition logical ID disagrees with binding")
      else Ok (transition, physical)

let verify_transition_references store transition =
  let* _ =
    Snapshot.Snapshot.load store transition.transition_snapshot
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let* () =
    match transition.transition_metadata with
    | None -> Ok ()
    | Some { message; _ } ->
        Snapshot.Content.load store message
        |> Result.map_error (fun error ->
            Imported_transition_error
              ("imported transition message is unavailable: "
              ^ Snapshot.error_to_string error))
        |> Result.map (fun _ -> ())
  in
  Ok ()

let load_imported_transition store logical =
  let* transition, _ = load_transition_binding store logical in
  let* () = verify_transition_references store transition in
  Ok transition

let tag_domain = "yeokcham:imported-tag:v1\000"
let tag_binding_domain = "yeokcham:imported-tag-binding:v1\000"

let tag_array values =
  Encoding.array values
  |> Result.map_error (fun error ->
      Imported_tag_error (Encoding.construction_error_to_string error))

let tag_bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Imported_tag_error (name ^ " must be bytes"))

let tag_integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Imported_tag_error (name ^ " must be an integer"))

let tag_id_value name raw =
  if String.length raw = 32 then Ok (Encoding.bytes raw)
  else
    Error
      (Imported_tag_error
         (Printf.sprintf "%s must be exactly 32 bytes, got %d" name
            (String.length raw)))

let tag_object_id_value identity =
  let format = match identity.format with Sha1 -> 1L | Sha256 -> 2L in
  tag_array [ Encoding.integer format; Encoding.bytes identity.raw ]

let tag_object_id_of_value value =
  decode_object_id value
  |> Result.map_error (fun error -> Imported_tag_error (error_to_string error))

let tag_target_kind_code = function
  | Tag_commit -> 1L
  | Tag_tree -> 2L
  | Tag_blob -> 3L

let tag_target_kind_of_code = function
  | 1L -> Ok Tag_commit
  | 2L -> Ok Tag_tree
  | 3L -> Ok Tag_blob
  | value ->
      Error
        (Imported_tag_error
           (Printf.sprintf "unknown imported tag target kind: %Ld" value))

let tag_target_kind_name = function
  | Tag_commit -> "commit"
  | Tag_tree -> "tree"
  | Tag_blob -> "blob"

let tag_target_kind_of_name = function
  | "commit" -> Ok Tag_commit
  | "tree" -> Ok Tag_tree
  | "blob" -> Ok Tag_blob
  | value -> Error (Invalid_tag ("unsupported target type: " ^ value))

let valid_imported_tag_name name =
  let components = String.split_on_char '/' name in
  if String.is_empty name then Error (Imported_tag_error "tag name is empty")
  else if String.contains name '\000' then
    Error (Imported_tag_error "tag name contains NUL")
  else if
    List.exists
      (fun part ->
        String.is_empty part || String.equal part "." || String.equal part "..")
      components
  then Error (Imported_tag_error "tag name has an unsafe component")
  else Ok ()

let tag_representation_value ~target ~target_kind ~annotation =
  match annotation with
  | None ->
      tag_array
        [
          Encoding.integer 0L;
          Encoding.integer (tag_target_kind_code target_kind);
        ]
  | Some annotation ->
      let* target = tag_object_id_value target in
      let* annotation =
        tag_id_value "imported tag annotation content ID"
          (Snapshot.Content.stored_object_id annotation
          |> Store.Stored_object_id.to_raw_bytes)
      in
      tag_array
        [
          Encoding.integer 1L;
          target;
          Encoding.integer (tag_target_kind_code target_kind);
          annotation;
        ]

let tag_identity_payload ~name ~ref_object ~target ~target_kind ~annotation =
  let* name = tag_bytes "imported tag name" (Encoding.bytes name) in
  let* ref_object = tag_object_id_value ref_object in
  let* representation =
    tag_representation_value ~target ~target_kind ~annotation
  in
  tag_array
    [ Encoding.integer 1L; Encoding.bytes name; ref_object; representation ]

let derive_tag_id ~name ~ref_object ~target ~target_kind ~annotation =
  let* identity =
    tag_identity_payload ~name ~ref_object ~target ~target_kind ~annotation
  in
  let raw =
    Hash.feed_string Hash.empty tag_domain |> fun context ->
    Hash.feed_string context (Encoding.encode identity)
    |> Hash.get |> Hash.to_raw_string
  in
  Id.Imported_tag_id.of_bytes raw
  |> Result.map_error (fun error ->
      Imported_tag_error (Id.parse_error_to_string error))

let create_imported_tag ~name ~ref_object ~target ~target_kind ~annotation =
  let* () = valid_imported_tag_name name in
  if ref_object.format <> target.format then
    Error
      (Imported_tag_error
         "tag ref object and target have different Git object formats")
  else if annotation = None && not (object_id_equal ref_object target) then
    Error
      (Imported_tag_error "lightweight tag target disagrees with ref object")
  else if annotation <> None && object_id_equal ref_object target then
    Error (Imported_tag_error "annotated tag cannot name itself as its target")
  else
    let* tag_id =
      derive_tag_id ~name ~ref_object ~target ~target_kind ~annotation
    in
    Ok
      {
        tag_id;
        tag_name = name;
        tag_ref_object = ref_object;
        tag_target = target;
        tag_target_kind = target_kind;
        tag_annotation = annotation;
      }

let tag_payload tag =
  let* identity =
    tag_identity_payload ~name:tag.tag_name ~ref_object:tag.tag_ref_object
      ~target:tag.tag_target ~target_kind:tag.tag_target_kind
      ~annotation:tag.tag_annotation
  in
  let* id =
    tag_id_value "imported tag ID" (Id.Imported_tag_id.to_bytes tag.tag_id)
  in
  match identity with
  | Encoding.Array [ _; name; ref_object; representation ] ->
      tag_array [ Encoding.integer 1L; id; name; ref_object; representation ]
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
      assert false

let tag_envelope tag =
  let* payload = tag_payload tag in
  Envelope.create ~object_type:Envelope.Imported_tag
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error ->
      Imported_tag_error (Envelope.creation_error_to_string error))

let tag_fields name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error
        (Imported_tag_error
           (Printf.sprintf "%s must contain %d values" name length))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Imported_tag_error (name ^ " must be an array"))

let tag_raw_id name parser value =
  let* raw = tag_bytes name value in
  if String.length raw <> 32 then
    Error
      (Imported_tag_error
         (Printf.sprintf "%s must be exactly 32 bytes, got %d" name
            (String.length raw)))
  else
    parser raw
    |> Result.map_error (fun error ->
        Imported_tag_error (Id.parse_error_to_string error))

let tag_stored_id name value =
  let* raw = tag_bytes name value in
  match Store.Stored_object_id.of_raw_bytes raw with
  | Some identity -> Ok identity
  | None ->
      Error
        (Imported_tag_error
           (Printf.sprintf "%s must be exactly 32 bytes, got %d" name
              (String.length raw)))

let decode_tag_representation name ref_object value =
  let* values =
    match value with
    | Encoding.Array values -> Ok values
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        Error (Imported_tag_error "tag representation must be an array")
  in
  match values with
  | [ tag; target_kind ] ->
      let* tag = tag_integer "tag representation kind" tag in
      if not (Int64.equal tag 0L) then
        Error (Imported_tag_error "lightweight tag has an invalid kind")
      else
        let* target_kind =
          tag_integer "lightweight tag target kind" target_kind
        in
        let* target_kind = tag_target_kind_of_code target_kind in
        create_imported_tag ~name ~ref_object ~target:ref_object ~target_kind
          ~annotation:None
  | [ tag; target; target_kind; annotation ] ->
      let* tag = tag_integer "tag representation kind" tag in
      if not (Int64.equal tag 1L) then
        Error (Imported_tag_error "annotated tag has an invalid kind")
      else
        let* target = tag_object_id_of_value target in
        let* target_kind =
          tag_integer "annotated tag target kind" target_kind
        in
        let* target_kind = tag_target_kind_of_code target_kind in
        let* annotation = tag_stored_id "annotated tag content ID" annotation in
        create_imported_tag ~name ~ref_object ~target ~target_kind
          ~annotation:(Some (Snapshot.Content.of_stored_object_id annotation))
  | _ -> Error (Imported_tag_error "tag representation has an invalid length")

let decode_tag_payload value =
  let* fields = tag_fields "imported tag" 5 value in
  match fields with
  | [ version; supplied_id; name; ref_object; representation ] ->
      let* version = tag_integer "imported tag version" version in
      if not (Int64.equal version 1L) then
        Error
          (Imported_tag_error
             (Printf.sprintf "unsupported imported tag version: %Ld" version))
      else
        let* supplied_id =
          tag_raw_id "imported tag ID" Id.Imported_tag_id.of_bytes supplied_id
        in
        let* name = tag_bytes "imported tag name" name in
        let* ref_object = tag_object_id_of_value ref_object in
        let* tag = decode_tag_representation name ref_object representation in
        if not (Id.Imported_tag_id.equal supplied_id tag.tag_id) then
          Error
            (Imported_tag_error
               "imported tag logical ID does not match its preimage")
        else
          let* canonical = tag_payload tag in
          if String.equal (Encoding.encode canonical) (Encoding.encode value)
          then Ok tag
          else Error (Imported_tag_error "imported tag payload is noncanonical")
  | _ -> assert false

let tag_binding_body logical physical =
  let* logical =
    tag_id_value "imported tag ID" (Id.Imported_tag_id.to_bytes logical)
  in
  let* physical =
    tag_id_value "imported tag object ID"
      (Store.Stored_object_id.to_raw_bytes physical)
  in
  tag_array [ Encoding.integer 1L; logical; physical ]

let tag_binding_checksum body =
  Hash.feed_string Hash.empty tag_binding_domain |> fun context ->
  Hash.feed_string context (Encoding.encode body)
  |> Hash.get |> Hash.to_raw_string

let encode_tag_binding logical physical =
  let* body = tag_binding_body logical physical in
  let checksum = Encoding.bytes (tag_binding_checksum body) in
  match body with
  | Encoding.Array [ _; logical; physical ] ->
      let* encoded =
        tag_array [ Encoding.integer 1L; logical; physical; checksum ]
      in
      Ok (Encoding.encode encoded)
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
      assert false

let decode_tag_binding bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error ->
        Imported_tag_error (Encoding.decode_error_to_string error))
  in
  let* fields = tag_fields "imported tag binding" 4 value in
  match fields with
  | [ version; logical; physical; supplied_checksum ] ->
      let* version = tag_integer "imported tag binding version" version in
      if not (Int64.equal version 1L) then
        Error
          (Imported_tag_error
             (Printf.sprintf "unsupported imported tag binding version: %Ld"
                version))
      else
        let* logical =
          tag_raw_id "imported tag binding ID" Id.Imported_tag_id.of_bytes
            logical
        in
        let* physical =
          tag_stored_id "imported tag binding object ID" physical
        in
        let* supplied_checksum =
          tag_bytes "imported tag binding checksum" supplied_checksum
        in
        if String.length supplied_checksum <> 32 then
          Error
            (Imported_tag_error
               "imported tag binding checksum must be exactly 32 bytes")
        else
          let* body = tag_binding_body logical physical in
          if not (String.equal supplied_checksum (tag_binding_checksum body))
          then
            Error (Imported_tag_error "imported tag binding checksum mismatch")
          else
            let* canonical = encode_tag_binding logical physical in
            if String.equal canonical bytes then Ok (logical, physical)
            else
              Error
                (Imported_tag_error
                   "imported tag binding bytes are noncanonical")
  | _ -> assert false

let tag_ref_components logical =
  [ "imported-tags"; Id.Imported_tag_id.to_hex logical ]

let publish_tag store tag =
  let* envelope = tag_envelope tag in
  let* physical =
    Store.put store envelope
    |> Result.map_error (fun error -> Store_error error)
  in
  let* binding = encode_tag_binding tag.tag_id physical in
  Store.with_lock store ~name:"imported-tags"
    ~on_error:(fun error -> Store_error error)
    (fun () ->
      let components = tag_ref_components tag.tag_id in
      let* current =
        Store.Ref_file.read store ~components
        |> Result.map_error (fun error -> Store_error error)
      in
      match current with
      | None ->
          Store.Ref_file.compare_and_swap store ~components ~expected:None
            ~replacement:binding
          |> Result.map_error (fun error -> Store_error error)
      | Some current ->
          let* current_id, current_object = decode_tag_binding current in
          if
            Id.Imported_tag_id.equal current_id tag.tag_id
            && Store.Stored_object_id.equal current_object physical
          then Ok ()
          else
            Error
              (Imported_tag_error
                 "imported tag ID already has a different immutable binding"))
  |> Result.map (fun () -> (tag, physical))

let load_tag_binding store logical =
  let components = tag_ref_components logical in
  let* binding =
    Store.Ref_file.read store ~components
    |> Result.map_error (fun error -> Store_error error)
  in
  let* binding =
    match binding with
    | Some binding -> Ok binding
    | None -> Error (Imported_tag_error "imported tag binding is absent")
  in
  let* bound_id, physical = decode_tag_binding binding in
  if not (Id.Imported_tag_id.equal bound_id logical) then
    Error
      (Imported_tag_error
         "imported tag binding logical ID disagrees with its path")
  else
    let* envelope =
      Store.get store physical
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type envelope <> Envelope.Imported_tag then
      Error
        (Imported_tag_error
           (Printf.sprintf "expected imported tag object type 25, got %d"
              (Envelope.object_type_code (Envelope.object_type envelope))))
    else
      let* tag = decode_tag_payload (Envelope.payload envelope) in
      if not (Id.Imported_tag_id.equal tag.tag_id logical) then
        Error
          (Imported_tag_error "imported tag logical ID disagrees with binding")
      else Ok (tag, physical)

let load_imported_tag store logical =
  let* tag, _ = load_tag_binding store logical in
  let* () =
    match tag.tag_annotation with
    | None -> Ok ()
    | Some annotation ->
        Snapshot.Content.load store annotation
        |> Result.map_error (fun error ->
            Imported_tag_error
              ("annotated tag content is unavailable: "
              ^ Snapshot.error_to_string error))
        |> Result.map (fun _ -> ())
  in
  Ok tag

let imported_tag_id tag = tag.tag_id
let imported_tag_name tag = tag.tag_name
let imported_tag_ref_object tag = tag.tag_ref_object
let imported_tag_target tag = tag.tag_target
let imported_tag_target_kind tag = tag.tag_target_kind
let imported_tag_annotation tag = tag.tag_annotation
let imported_transition_id transition = transition.transition_id
let imported_transition_commit transition = transition.transition_commit
let imported_transition_tree transition = transition.transition_tree
let imported_transition_snapshot transition = transition.transition_snapshot
let imported_transition_parents transition = transition.transition_parents

let imported_transition_author transition =
  Option.map (fun metadata -> metadata.author) transition.transition_metadata

let imported_transition_committer transition =
  Option.map (fun metadata -> metadata.committer) transition.transition_metadata

let imported_transition_message transition =
  Option.map (fun metadata -> metadata.message) transition.transition_metadata

let verify_mapping_subject store = function
  | Imported_snapshot snapshot ->
      Snapshot.Snapshot.load store snapshot
      |> Result.map_error (fun error -> Snapshot_error error)
      |> Result.map (fun _ -> ())
  | Imported_transition { transition; transition_object } ->
      let* loaded, physical = load_transition_binding store transition in
      if not (Store.Stored_object_id.equal physical transition_object) then
        Error
          (Mapping_error
             "imported transition mapping object disagrees with its binding")
      else verify_transition_references store loaded
  | Imported_tag { tag; tag_object } ->
      let* loaded, physical = load_tag_binding store tag in
      if not (Store.Stored_object_id.equal physical tag_object) then
        Error
          (Mapping_error
             "imported tag mapping object disagrees with its binding")
      else
        let* () =
          match loaded.tag_annotation with
          | None -> Ok ()
          | Some annotation ->
              Snapshot.Content.load store annotation
              |> Result.map_error (fun error ->
                  Mapping_error
                    ("imported tag annotation is unavailable: "
                    ^ Snapshot.error_to_string error))
              |> Result.map (fun _ -> ())
        in
        Ok ()
  | Exported_release { release; release_object; final_snapshot } ->
      let* loaded =
        Release.load_release store release_object
        |> Result.map_error (fun error -> Release_error error)
      in
      if not (Id.Release_id.equal release (Release.release_id loaded)) then
        Error
          (Mapping_error "exported release mapping object disagrees with its ID")
      else if
        not
          (Snapshot.Snapshot.equal_id final_snapshot
             (Release.release_final_snapshot loaded))
      then
        Error
          (Mapping_error
             "exported release mapping snapshot disagrees with its release")
      else
        Snapshot.Snapshot.load store final_snapshot
        |> Result.map_error (fun error -> Snapshot_error error)
        |> Result.map (fun _ -> ())
  | Imported_revision _ -> Ok ()
  | Exported_revision { capsule; revision; revision_object; final_snapshot } ->
      let source =
        Capsule_store.make_revision_link ~capsule ~revision
          ~object_id:revision_object
      in
      let* loaded =
        Capsule_store.Durable.verify_link store source
        |> Result.map_error (fun error ->
            Mapping_error
              ("exported revision mapping source is invalid: "
              ^ Capsule_store.error_to_string error))
      in
      if
        not
          (Snapshot.Snapshot.equal_id final_snapshot
             (Capsule_store.revision_expected_result loaded))
      then
        Error
          (Mapping_error
             "exported revision mapping snapshot disagrees with its revision")
      else
        Snapshot.Snapshot.load store final_snapshot
        |> Result.map_error (fun error -> Snapshot_error error)
        |> Result.map (fun _ -> ())

let load_mapping store logical =
  let components = mapping_ref_components logical in
  let* binding =
    Store.Ref_file.read store ~components
    |> Result.map_error (fun error -> Store_error error)
  in
  let* binding =
    match binding with
    | Some binding -> Ok binding
    | None -> Error (Mapping_error "Git mapping binding is absent")
  in
  let* bound_version, bound_id, physical = decode_mapping_binding binding in
  if not (Id.Git_mapping_id.equal bound_id logical) then
    Error
      (Mapping_error "Git mapping binding logical ID disagrees with its path")
  else
    let* envelope =
      Store.get store physical
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type envelope <> Envelope.Git_mapping then
      Error
        (Mapping_error
           (Printf.sprintf "expected Git mapping object type 23, got %d"
              (Envelope.object_type_code (Envelope.object_type envelope))))
    else
      let* mapping = decode_mapping_payload (Envelope.payload envelope) in
      if
        not
          (Int.equal bound_version mapping.version
          && Id.Git_mapping_id.equal mapping.id logical)
      then
        Error
          (Mapping_error "Git mapping object logical ID disagrees with binding")
      else
        let* () = verify_mapping_subject store mapping.subject in
        Ok mapping

let mapping_id mapping = mapping.id
let mapping_direction mapping = mapping.direction
let mapping_git_object mapping = mapping.git_object
let mapping_kind mapping = mapping.git_kind
let mapping_subject mapping = mapping.subject

let store_file_content store bytes =
  if String.length bytes <= Snapshot.inline_file_limit then
    Snapshot.Content.store store bytes
  else
    Snapshot.Manifest.store_bytes store bytes
    |> Result.map (fun manifest ->
        Snapshot.Content.of_stored_object_id
          (Snapshot.Manifest.stored_object_id manifest))

let import_tree ?runner configuration ~store ~repository ~tree =
  let* configuration = validate_configuration configuration in
  let* repository = validate_repository_path repository in
  let* executable =
    match executable_path configuration.git with
    | Some executable -> Ok executable
    | None -> Error (Git_missing configuration.git)
  in
  let* inspection = inspect ?runner configuration ~repository in
  if tree.format <> inspection.object_format then
    Error
      (Invalid_object_id
         { format = inspection.object_format; value = object_id_to_hex tree })
  else
    let total_tree_bytes = ref 0 in
    let total_blob_bytes = ref 0 in
    let total_entries = ref 0 in
    let read_object identity kind limit =
      read_exact_object ?runner configuration executable repository ~identity
        ~kind ~limit
    in
    let rec import_directory depth identity =
      if depth > configuration.max_depth then
        Error
          (Import_limit_exceeded
             {
               resource = "tree depth";
               limit = configuration.max_depth;
               actual = depth;
             })
      else
        let* raw = read_object identity "tree" configuration.max_tree_bytes in
        let next_tree_total = !total_tree_bytes + String.length raw in
        if next_tree_total > configuration.max_total_tree_bytes then
          Error
            (Import_limit_exceeded
               {
                 resource = "total tree bytes";
                 limit = configuration.max_total_tree_bytes;
                 actual = next_tree_total;
               })
        else (
          total_tree_bytes := next_tree_total;
          let* entries =
            parse_tree_entries ~max_entries:configuration.max_tree_entries
              identity raw
          in
          let next_total = !total_entries + List.length entries in
          if next_total > configuration.max_tree_entries then
            Error
              (Import_limit_exceeded
                 {
                   resource = "total tree entries";
                   limit = configuration.max_tree_entries;
                   actual = next_total;
                 })
          else (
            total_entries := next_total;
            let rec import_entries reversed = function
              | [] -> Ok (List.rev reversed)
              | entry :: rest ->
                  let* imported =
                    match entry.mode with
                    | "40000" ->
                        let* child =
                          import_directory (depth + 1) entry.object_id
                        in
                        Ok (entry.name, Snapshot.Tree.Directory child)
                    | "100644" | "100755" | "120000" ->
                        let* blob =
                          read_object entry.object_id "blob"
                            configuration.max_blob_bytes
                        in
                        if
                          String.equal entry.mode "120000"
                          && String.contains blob '\000'
                        then
                          Error
                            (Invalid_symlink_target
                               { identity = entry.object_id })
                        else
                          let next_total =
                            !total_blob_bytes + String.length blob
                          in
                          if next_total > configuration.max_total_blob_bytes
                          then
                            Error
                              (Import_limit_exceeded
                                 {
                                   resource = "total blob bytes";
                                   limit = configuration.max_total_blob_bytes;
                                   actual = next_total;
                                 })
                          else (
                            total_blob_bytes := next_total;
                            let* content =
                              store_file_content store blob
                              |> Result.map_error (fun error ->
                                  Snapshot_error error)
                            in
                            let mode =
                              if String.equal entry.mode "100644" then
                                Snapshot.Regular
                              else if String.equal entry.mode "100755" then
                                Snapshot.Executable
                              else Snapshot.Symlink
                            in
                            Ok (entry.name, Snapshot.Tree.File { mode; content }))
                    | mode -> Error (Unsupported_tree_mode { identity; mode })
                  in
                  import_entries (imported :: reversed) rest
            in
            let* entries = import_entries [] entries in
            let entries =
              List.sort
                (fun (left, _) (right, _) -> String.compare left right)
                entries
            in
            let* tree =
              Snapshot.Tree.create entries
              |> Result.map_error (fun error -> Snapshot_error error)
            in
            Snapshot.Tree.store store tree
            |> Result.map_error (fun error -> Snapshot_error error)))
    in
    let* root = import_directory 0 tree in
    let snapshot = Snapshot.Snapshot.create ~root in
    let* snapshot =
      Snapshot.Snapshot.store store snapshot
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let* mapping =
      create_mapping ~direction:Import ~git_object:tree ~git_kind:Tree
        ~subject:(Imported_snapshot snapshot)
    in
    let* mapping = publish_mapping store mapping in
    Ok { snapshot; mapping }

let commit_header_end raw =
  let rec loop index =
    if index + 1 >= String.length raw then None
    else if Char.equal raw.[index] '\n' && Char.equal raw.[index + 1] '\n' then
      Some index
    else loop (index + 1)
  in
  loop 0

let commit_object_id identity label value =
  object_id_of_hex identity.format value
  |> Result.map_error (fun _ ->
      Invalid_commit
        {
          identity;
          detail =
            Printf.sprintf "%s is not a full %s object ID" label
              (object_format_to_string identity.format);
        })

type parsed_commit_metadata = {
  parsed_author : string;
  parsed_committer : string;
  parsed_message : string;
}

type parsed_commit_headers = {
  parsed_tree : object_id;
  parsed_parents : object_id list;
  parsed_metadata : parsed_commit_metadata;
}

type preceding_header = Metadata_header | Other_header

let valid_parsed_identity identity label value =
  if String.is_empty value then
    Error (Invalid_commit { identity; detail = label ^ " header is empty" })
  else if String.contains value '\000' then
    Error
      (Invalid_commit
         { identity; detail = label ^ " header contains a NUL byte" })
  else Ok value

let parse_commit_headers ~max_parents identity raw =
  let* header_end =
    match commit_header_end raw with
    | Some index -> Ok index
    | None ->
        Error
          (Invalid_commit
             {
               identity;
               detail = "header block is not terminated by a blank line";
             })
  in
  let header = String.sub raw 0 header_end in
  let message =
    String.sub raw (header_end + 2) (String.length raw - header_end - 2)
  in
  let lines = String.split_on_char '\n' header in
  let rec parse tree parents author committer preceding = function
    | [] -> (
        match (tree, author, committer) with
        | Some tree, Some author, Some committer ->
            Ok
              {
                parsed_tree = tree;
                parsed_parents = List.rev parents;
                parsed_metadata =
                  {
                    parsed_author = author;
                    parsed_committer = committer;
                    parsed_message = message;
                  };
              }
        | None, _, _ ->
            Error
              (Invalid_commit { identity; detail = "tree header is absent" })
        | Some _, None, _ ->
            Error
              (Invalid_commit { identity; detail = "author header is absent" })
        | Some _, Some _, None ->
            Error
              (Invalid_commit
                 { identity; detail = "committer header is absent" }))
    | line :: rest -> (
        if String.is_empty line then
          Error
            (Invalid_commit { identity; detail = "empty commit header line" })
        else if Char.equal line.[0] ' ' then
          match preceding with
          | None ->
              Error
                (Invalid_commit
                   {
                     identity;
                     detail = "header continuation has no prior header";
                   })
          | Some Metadata_header ->
              Error
                (Invalid_commit
                   {
                     identity;
                     detail = "author or committer header has a continuation";
                   })
          | Some Other_header ->
              parse tree parents author committer (Some Other_header) rest
        else
          match String.index_opt line ' ' with
          | None ->
              Error
                (Invalid_commit
                   {
                     identity;
                     detail = "commit header lacks a key/value separator";
                   })
          | Some separator ->
              let key = String.sub line 0 separator in
              let value =
                String.sub line (separator + 1)
                  (String.length line - separator - 1)
              in
              if String.is_empty key then
                Error
                  (Invalid_commit
                     { identity; detail = "commit header key is empty" })
              else if String.equal key "tree" then
                match tree with
                | Some _ ->
                    Error
                      (Invalid_commit
                         {
                           identity;
                           detail = "tree header occurs more than once";
                         })
                | None ->
                    let* tree = commit_object_id identity "tree header" value in
                    parse (Some tree) parents author committer
                      (Some Other_header) rest
              else if String.equal key "parent" then
                if List.length parents = max_parents then
                  Error
                    (Import_limit_exceeded
                       {
                         resource = "commit parents";
                         limit = max_parents;
                         actual = max_parents + 1;
                       })
                else
                  let* parent =
                    commit_object_id identity "parent header" value
                  in
                  parse tree (parent :: parents) author committer
                    (Some Other_header) rest
              else if String.equal key "author" then
                match author with
                | Some _ ->
                    Error
                      (Invalid_commit
                         {
                           identity;
                           detail = "author header occurs more than once";
                         })
                | None ->
                    let* author =
                      valid_parsed_identity identity "author" value
                    in
                    parse tree parents (Some author) committer
                      (Some Metadata_header) rest
              else if String.equal key "committer" then
                match committer with
                | Some _ ->
                    Error
                      (Invalid_commit
                         {
                           identity;
                           detail = "committer header occurs more than once";
                         })
                | None ->
                    let* committer =
                      valid_parsed_identity identity "committer" value
                    in
                    parse tree parents author (Some committer)
                      (Some Metadata_header) rest
              else parse tree parents author committer (Some Other_header) rest)
  in
  let* parsed = parse None [] None None None lines in
  let rec valid_parents seen = function
    | [] -> Ok ()
    | parent :: rest ->
        if object_id_equal parent identity then
          Error
            (Invalid_commit
               { identity; detail = "commit names itself as a parent" })
        else if List.exists (object_id_equal parent) seen then
          Error
            (Invalid_commit
               { identity; detail = "commit names a parent more than once" })
        else valid_parents (parent :: seen) rest
  in
  let* () = valid_parents [] parsed.parsed_parents in
  Ok parsed

let import_commit ?runner configuration ~store ~repository ~commit =
  let* configuration = validate_configuration configuration in
  let* repository = validate_repository_path repository in
  let* executable =
    match executable_path configuration.git with
    | Some executable -> Ok executable
    | None -> Error (Git_missing configuration.git)
  in
  let* inspection = inspect ?runner configuration ~repository in
  if commit.format <> inspection.object_format then
    Error
      (Invalid_object_id
         { format = inspection.object_format; value = object_id_to_hex commit })
  else
    let* raw =
      read_exact_object ?runner configuration executable repository
        ~identity:commit ~kind:"commit" ~limit:configuration.max_commit_bytes
    in
    let* parsed =
      parse_commit_headers ~max_parents:configuration.max_commit_parents commit
        raw
    in
    let tree = parsed.parsed_tree in
    let parents = parsed.parsed_parents in
    let rec verify_parents = function
      | [] -> Ok ()
      | parent :: rest ->
          let* () =
            verify_exact_object_type ?runner configuration executable repository
              ~identity:parent ~kind:"commit"
          in
          verify_parents rest
    in
    let* () = verify_parents parents in
    let* tree_import =
      import_tree ?runner configuration ~store ~repository ~tree
    in
    let* message =
      Snapshot.Content.store store parsed.parsed_metadata.parsed_message
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let* transition =
      create_imported_transition_v2 ~commit ~tree ~snapshot:tree_import.snapshot
        ~parents ~author:parsed.parsed_metadata.parsed_author
        ~committer:parsed.parsed_metadata.parsed_committer ~message
    in
    let* transition, transition_object = publish_transition store transition in
    let* mapping =
      create_mapping_with_version 3 ~direction:Import ~git_object:commit
        ~git_kind:Commit
        ~subject:
          (Imported_transition
             { transition = transition.transition_id; transition_object })
    in
    let* mapping = publish_mapping store mapping in
    Ok { imported_transition = transition; commit_mapping = mapping }

let valid_requested_tag configuration tag =
  if String.length tag > configuration.max_tag_name_bytes then
    Error
      (Invalid_tag
         (Printf.sprintf "tag name exceeds %d bytes"
            configuration.max_tag_name_bytes))
  else if String.starts_with ~prefix:"refs/" tag then
    Error (Invalid_tag "tag name must not include refs/ prefix")
  else
    valid_imported_tag_name tag
    |> Result.map_error (fun error -> Invalid_tag (error_to_string error))

let tag_ref_output_limit configuration format =
  let object_hex = object_id_length format * 2 in
  configuration.max_tag_name_bytes + object_hex + 32

let parse_tag_ref format requested output =
  let length = String.length output in
  let output =
    if length > 0 && Char.equal output.[length - 1] '\n' then
      String.sub output 0 (length - 1)
    else output
  in
  if
    String.is_empty output
    || String.contains output '\n'
    || String.contains output '\r'
  then Error (Invalid_tag "tag ref is absent or has multiple records")
  else
    match String.split_on_char '\000' output with
    | [ ref_name; object_hex; object_type ] ->
        if not (String.equal ref_name ("refs/tags/" ^ requested)) then
          Error (Invalid_tag "resolved ref name disagrees with requested tag")
        else
          let* object_ = object_id_of_hex format object_hex in
          if String.is_empty object_type || String.contains object_type '\000'
          then Error (Invalid_tag "tag ref object type is empty")
          else Ok (object_, object_type)
    | _ -> Error (Invalid_tag "tag ref output has an invalid field count")

let parse_annotated_tag_headers ~name identity raw =
  let header_end =
    match find_byte raw '\n' 0 with
    | None -> None
    | Some _ ->
        let rec find_blank offset =
          if offset + 1 >= String.length raw then None
          else if
            Char.equal raw.[offset] '\n' && Char.equal raw.[offset + 1] '\n'
          then Some offset
          else find_blank (offset + 1)
        in
        find_blank 0
  in
  let* header_end =
    match header_end with
    | Some offset -> Ok offset
    | None ->
        Error (Invalid_tag "annotated tag header lacks a blank-line terminator")
  in
  let lines = String.sub raw 0 header_end |> String.split_on_char '\n' in
  let field line =
    match String.index_opt line ' ' with
    | Some separator when separator > 0 ->
        Ok
          ( String.sub line 0 separator,
            String.sub line (separator + 1) (String.length line - separator - 1)
          )
    | _ ->
        Error (Invalid_tag "annotated tag header lacks a key/value separator")
  in
  let rec parse target target_kind tag_name tagger = function
    | [] -> (
        match (target, target_kind, tag_name, tagger) with
        | Some target, Some target_kind, Some tag_name, Some _ ->
            if not (String.equal tag_name name) then
              Error (Invalid_tag "annotated tag header name disagrees with ref")
            else Ok (target, target_kind)
        | _ -> Error (Invalid_tag "annotated tag misses a required header"))
    | line :: rest ->
        let* key, value = field line in
        if String.equal key "object" then
          match target with
          | Some _ ->
              Error
                (Invalid_tag "annotated tag object header occurs more than once")
          | None ->
              let* target = object_id_of_hex identity.format value in
              parse (Some target) target_kind tag_name tagger rest
        else if String.equal key "type" then
          match target_kind with
          | Some _ ->
              Error
                (Invalid_tag "annotated tag type header occurs more than once")
          | None ->
              let* target_kind = tag_target_kind_of_name value in
              parse target (Some target_kind) tag_name tagger rest
        else if String.equal key "tag" then
          match tag_name with
          | Some _ ->
              Error
                (Invalid_tag "annotated tag name header occurs more than once")
          | None ->
              if String.is_empty value then
                Error (Invalid_tag "annotated tag name is empty")
              else parse target target_kind (Some value) tagger rest
        else if String.equal key "tagger" then
          match tagger with
          | Some _ ->
              Error
                (Invalid_tag "annotated tag tagger header occurs more than once")
          | None ->
              if String.is_empty value then
                Error (Invalid_tag "annotated tag tagger is empty")
              else parse target target_kind tag_name (Some value) rest
        else parse target target_kind tag_name tagger rest
  in
  parse None None None None lines

let import_tag ?runner configuration ~store ~repository ~tag =
  let* configuration = validate_configuration configuration in
  let* repository = validate_repository_path repository in
  let* () = valid_requested_tag configuration tag in
  let* executable =
    match executable_path configuration.git with
    | Some executable -> Ok executable
    | None -> Error (Git_missing configuration.git)
  in
  let* inspection = inspect ?runner configuration ~repository in
  let* ref_output =
    run_bytes ?runner configuration executable repository ~operation:"tag-ref"
      ~max_stdout_bytes:
        (tag_ref_output_limit configuration inspection.object_format)
      [
        "--no-replace-objects";
        "for-each-ref";
        "--format=%(refname)%00%(objectname)%00%(objecttype)";
        "--";
        "refs/tags/" ^ tag;
      ]
  in
  let* ref_object, ref_type =
    parse_tag_ref inspection.object_format tag ref_output
  in
  let* imported_tag =
    if String.equal ref_type "tag" then
      let* raw =
        read_exact_object ?runner configuration executable repository
          ~identity:ref_object ~kind:"tag" ~limit:configuration.max_tag_bytes
      in
      let* target, target_kind =
        parse_annotated_tag_headers ~name:tag ref_object raw
      in
      let* () =
        verify_exact_object_type ?runner configuration executable repository
          ~identity:target
          ~kind:(tag_target_kind_name target_kind)
      in
      let* annotation =
        Snapshot.Content.store store raw
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      create_imported_tag ~name:tag ~ref_object ~target ~target_kind
        ~annotation:(Some annotation)
    else
      let* target_kind = tag_target_kind_of_name ref_type in
      let* () =
        verify_exact_object_type ?runner configuration executable repository
          ~identity:ref_object ~kind:ref_type
      in
      create_imported_tag ~name:tag ~ref_object ~target:ref_object ~target_kind
        ~annotation:None
  in
  let* imported_tag, tag_object = publish_tag store imported_tag in
  let* mapping =
    create_mapping_with_version 3 ~direction:Import ~git_object:ref_object
      ~git_kind:Tag
      ~subject:(Imported_tag { tag = imported_tag.tag_id; tag_object })
  in
  let* tag_mapping = publish_mapping store mapping in
  Ok { imported_tag; tag_mapping }

type export_file = {
  export_path : string list;
  export_mode : Snapshot.file_mode;
  export_content : Snapshot.Content.id;
}

let export_mode = function
  | Snapshot.Regular -> "100644"
  | Snapshot.Executable -> "100755"
  | Snapshot.Symlink -> "120000"

let export_path path = String.concat "/" path

let with_temporary_bytes label bytes run =
  try
    let path = Filename.temp_file ("yeokcham-git-" ^ label ^ "-") ".tmp" in
    Fun.protect
      ~finally:(fun () ->
        try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
      (fun () ->
        try
          Out_channel.with_open_bin path (fun channel ->
              Out_channel.output_string channel bytes);
          run path
        with
        | Unix.Unix_error (error, operation, argument) ->
            Error
              (Export_error
                 (Unix.error_message error ^ ": " ^ operation ^ " " ^ argument))
        | Sys_error message -> Error (Export_error message))
  with Sys_error message -> Error (Export_error message)

let with_isolated_index run =
  try
    let path = Filename.temp_file "yeokcham-git-index-" ".tmp" in
    Unix.unlink path;
    Fun.protect
      ~finally:(fun () ->
        try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
      (fun () ->
        try run path with
        | Unix.Unix_error (error, operation, argument) ->
            Error
              (Export_error
                 (Unix.error_message error ^ ": " ^ operation ^ " " ^ argument))
        | Sys_error message -> Error (Export_error message))
  with
  | Unix.Unix_error (error, operation, argument) ->
      Error
        (Export_error
           (Unix.error_message error ^ ": " ^ operation ^ " " ^ argument))
  | Sys_error message -> Error (Export_error message)

let default_export_identity =
  {
    git_identity_name = "Yeokcham Export";
    git_identity_email = "noreply@yeokcham.local";
  }

let export_identity_header identity timestamp =
  identity.git_identity_name ^ " <" ^ identity.git_identity_email ^ "> "
  ^ Int64.to_string timestamp ^ " +0000"

let export_environment ~timestamp ~author ~committer =
  let date = "@" ^ Int64.to_string timestamp ^ " +0000" in
  [
    ("GIT_AUTHOR_DATE", date);
    ("GIT_AUTHOR_EMAIL", author.git_identity_email);
    ("GIT_AUTHOR_NAME", author.git_identity_name);
    ("GIT_ATTR_NOSYSTEM", "1");
    ("GIT_COMMITTER_DATE", date);
    ("GIT_COMMITTER_EMAIL", committer.git_identity_email);
    ("GIT_COMMITTER_NAME", committer.git_identity_name);
    ("GIT_CONFIG_NOSYSTEM", "1");
  ]

let add_environment environment pair = pair :: environment

let export_files configuration store snapshot =
  let total_entries = ref 0 in
  let total_path_bytes = ref 0 in
  let rec collect depth path tree =
    if depth > configuration.max_depth then
      Error
        (Export_limit_exceeded
           {
             resource = "tree depth";
             limit = configuration.max_depth;
             actual = depth;
           })
    else
      let* tree =
        Snapshot.Tree.load store tree
        |> Result.map_error (fun error -> Snapshot_error error)
      in
      let entries = Snapshot.Tree.entries tree in
      if path <> [] && entries = [] then
        Error
          (Unsupported_export_representation
             ("nested empty directory: " ^ export_path path))
      else
        let rec entries_result reversed = function
          | [] -> Ok (List.rev reversed)
          | (name, entry) :: rest ->
              let next_entries = !total_entries + 1 in
              if next_entries > configuration.max_tree_entries then
                Error
                  (Export_limit_exceeded
                     {
                       resource = "total tree entries";
                       limit = configuration.max_tree_entries;
                       actual = next_entries;
                     })
              else
                let next_path_bytes = !total_path_bytes + String.length name in
                if next_path_bytes > configuration.max_total_tree_bytes then
                  Error
                    (Export_limit_exceeded
                       {
                         resource = "total tree path bytes";
                         limit = configuration.max_total_tree_bytes;
                         actual = next_path_bytes;
                       })
                else (
                  total_entries := next_entries;
                  total_path_bytes := next_path_bytes;
                  let* produced =
                    match entry with
                    | Snapshot.Tree.File { mode; content } ->
                        Ok
                          [
                            {
                              export_path = path @ [ name ];
                              export_mode = mode;
                              export_content = content;
                            };
                          ]
                    | Snapshot.Tree.Directory child ->
                        collect (depth + 1) (path @ [ name ]) child
                  in
                  entries_result (List.rev_append produced reversed) rest)
        in
        entries_result [] entries
  in
  collect 0 [] (Snapshot.Snapshot.root snapshot)

let build_export_tree ?runner configuration executable repository ~environment
    ~format store files =
  let total_blob_bytes = ref 0 in
  let* staged =
    List.fold_left
      (fun result file ->
        let* reversed = result in
        let* bytes =
          Snapshot.Content.load store file.export_content
          |> Result.map_error (fun error -> Snapshot_error error)
        in
        if String.length bytes > configuration.max_blob_bytes then
          Error
            (Export_limit_exceeded
               {
                 resource = "blob bytes";
                 limit = configuration.max_blob_bytes;
                 actual = String.length bytes;
               })
        else if
          file.export_mode = Snapshot.Symlink && String.contains bytes '\000'
        then
          Error
            (Unsupported_export_representation
               ("symlink target contains NUL bytes: "
               ^ export_path file.export_path))
        else
          let next_total = !total_blob_bytes + String.length bytes in
          if next_total > configuration.max_total_blob_bytes then
            Error
              (Export_limit_exceeded
                 {
                   resource = "total blob bytes";
                   limit = configuration.max_total_blob_bytes;
                   actual = next_total;
                 })
          else (
            total_blob_bytes := next_total;
            let file = (file, bytes) in
            Ok (file :: reversed)))
      (Ok []) files
  in
  if staged = [] then
    with_temporary_bytes "empty-tree" "" (fun path ->
        let* output =
          run ?runner ~environment configuration executable repository
            ~operation:"hash-empty-tree"
            [
              "--no-replace-objects";
              "hash-object";
              "-t";
              "tree";
              "-w";
              "--no-filters";
              path;
            ]
        in
        let* output = single_line ~operation:"hash-empty-tree" output in
        let* tree = object_id_of_hex format output in
        let* () =
          verify_exact_object_type ?runner configuration executable repository
            ~identity:tree ~kind:"tree"
        in
        Ok tree)
  else
    with_isolated_index (fun index ->
        let environment =
          add_environment environment ("GIT_INDEX_FILE", index)
        in
        let* _ =
          run ?runner ~environment configuration executable repository
            ~operation:"read-tree-empty"
            [ "--no-replace-objects"; "read-tree"; "--empty" ]
        in
        let rec stage = function
          | [] -> Ok ()
          | (file, bytes) :: rest ->
              with_temporary_bytes "content" bytes (fun path ->
                  let* output =
                    run ?runner ~environment configuration executable repository
                      ~operation:"hash-object"
                      [
                        "--no-replace-objects";
                        "hash-object";
                        "-w";
                        "--no-filters";
                        path;
                      ]
                  in
                  let* output = single_line ~operation:"hash-object" output in
                  let* blob = object_id_of_hex format output in
                  let* _ =
                    run ?runner ~environment configuration executable repository
                      ~operation:"update-index"
                      [
                        "--no-replace-objects";
                        "update-index";
                        "--add";
                        "--cacheinfo";
                        export_mode file.export_mode
                        ^ "," ^ object_id_to_hex blob ^ ","
                        ^ export_path file.export_path;
                      ]
                  in
                  stage rest)
        in
        let* () = stage (List.rev staged) in
        let* output =
          run ?runner ~environment configuration executable repository
            ~operation:"write-tree"
            [ "--no-replace-objects"; "write-tree" ]
        in
        let* output = single_line ~operation:"write-tree" output in
        let* tree = object_id_of_hex format output in
        let* () =
          verify_exact_object_type ?runner configuration executable repository
            ~identity:tree ~kind:"tree"
        in
        Ok tree)

let export_ref release =
  "refs/heads/yeokcham/release-" ^ Id.Release_id.to_hex release

let add_u32 buffer value =
  List.iter
    (fun shift ->
      Buffer.add_char buffer (Char.chr ((value lsr shift) land 0xff)))
    [ 24; 16; 8; 0 ]

let add_export_metadata_component buffer value =
  add_u32 buffer (String.length value);
  Buffer.add_string buffer value

let export_metadata_ref release metadata =
  let bytes = Buffer.create 512 in
  Buffer.add_string bytes "yeokcham:git-release-metadata:v1\000";
  List.iter
    (add_export_metadata_component bytes)
    [
      metadata.release_export_author.git_identity_name;
      metadata.release_export_author.git_identity_email;
      metadata.release_export_committer.git_identity_name;
      metadata.release_export_committer.git_identity_email;
      metadata.release_export_message;
    ];
  let digest =
    Hash.digest_string (Buffer.contents bytes) |> Hash.to_raw_string
  in
  export_ref release ^ "-metadata-" ^ bytes_to_hex digest

let maximum_export_identity_bytes = 255

let invalid_identity_character = function
  | '\000' | '\n' | '\r' | '<' | '>' -> true
  | _ -> false

let validate_export_identity label identity =
  let name = identity.git_identity_name in
  let email = identity.git_identity_email in
  if String.is_empty name || String.length name > maximum_export_identity_bytes
  then Error (Export_error (label ^ " name is empty or exceeds 255 bytes"))
  else if String.exists invalid_identity_character name then
    Error (Export_error (label ^ " name contains a forbidden character"))
  else if
    String.is_empty email || String.length email > maximum_export_identity_bytes
  then Error (Export_error (label ^ " email is empty or exceeds 255 bytes"))
  else if
    String.exists
      (fun character ->
        invalid_identity_character character
        || Char.equal character ' ' || Char.equal character '\t')
      email
  then Error (Export_error (label ^ " email contains a forbidden character"))
  else
    match String.index_opt email '@' with
    | Some at
      when at > 0
           && at + 1 < String.length email
           && Option.is_none (String.index_from_opt email (at + 1) '@') ->
        Ok ()
    | Some _ | None -> Error (Export_error (label ^ " email has invalid shape"))

let validate_release_export_metadata configuration metadata ~timestamp =
  let* () =
    validate_export_identity "configured Git author"
      metadata.release_export_author
  in
  let* () =
    validate_export_identity "configured Git committer"
      metadata.release_export_committer
  in
  if String.contains metadata.release_export_message '\000' then
    Error (Export_error "configured Git message contains NUL bytes")
  else
    let header_bytes =
      70
      + String.length
          (export_identity_header metadata.release_export_author timestamp)
      + String.length
          (export_identity_header metadata.release_export_committer timestamp)
      + 20
    in
    let actual = header_bytes + String.length metadata.release_export_message in
    if actual > configuration.max_commit_bytes then
      Error
        (Export_limit_exceeded
           {
             resource = "configured release commit bytes";
             limit = configuration.max_commit_bytes;
             actual;
           })
    else Ok ()

let object_id_list_equal left right =
  List.length left = List.length right
  && List.for_all2 object_id_equal left right

let verify_exported_commit ?runner configuration executable repository ~tree
    ~commit ~timestamp ~author ~committer ~message ~parents =
  let* raw =
    read_exact_object ?runner configuration executable repository
      ~identity:commit ~kind:"commit" ~limit:configuration.max_commit_bytes
  in
  let* parsed =
    parse_commit_headers ~max_parents:configuration.max_commit_parents commit
      raw
  in
  let author = export_identity_header author timestamp in
  let committer = export_identity_header committer timestamp in
  if not (object_id_equal tree parsed.parsed_tree) then
    Error (Export_error "exported commit tree disagrees with constructed tree")
  else if not (object_id_list_equal parents parsed.parsed_parents) then
    Error (Export_error "exported commit parents disagree with policy")
  else if
    not
      (String.equal author parsed.parsed_metadata.parsed_author
      && String.equal committer parsed.parsed_metadata.parsed_committer)
  then Error (Export_error "exported commit metadata disagrees with policy")
  else if not (String.equal message parsed.parsed_metadata.parsed_message) then
    Error (Export_error "exported commit message disagrees with policy")
  else Ok ()

let create_export_commit ?runner configuration executable repository
    ~environment ~format ~tree ~timestamp ~author ~committer ~message ~parents
    ~configured_metadata =
  with_temporary_bytes "message" message (fun message_path ->
      let parent_arguments =
        List.concat_map
          (fun parent -> [ "-p"; object_id_to_hex parent ])
          parents
      in
      let* output =
        run ?runner ~environment configuration executable repository
          ~operation:"commit-tree"
          ((if configured_metadata then [ "-c"; "i18n.commitEncoding=UTF-8" ]
            else [])
          @ [
              "-c";
              "commit.gpgSign=false";
              "--no-replace-objects";
              "commit-tree";
              object_id_to_hex tree;
            ]
          @ parent_arguments @ [ "-F"; message_path ])
      in
      let* output = single_line ~operation:"commit-tree" output in
      let* commit = object_id_of_hex format output in
      let* () =
        verify_exported_commit ?runner configuration executable repository ~tree
          ~commit ~timestamp ~author ~committer ~message ~parents
      in
      Ok commit)

let publish_export_ref ?runner configuration executable repository ~commit
    ~target_ref =
  let zero = String.make (String.length (object_id_to_hex commit)) '0' in
  match
    run ?runner configuration executable repository ~operation:"update-ref"
      [
        "--no-replace-objects";
        "update-ref";
        "--no-deref";
        target_ref;
        object_id_to_hex commit;
        zero;
      ]
  with
  | Ok _ -> Ok ()
  | Error original -> (
      match
        run ?runner configuration executable repository
          ~operation:"read-export-ref"
          [
            "--no-replace-objects";
            "rev-parse";
            "--verify";
            "--quiet";
            target_ref;
          ]
      with
      | Error _ -> Error original
      | Ok output ->
          let* output = single_line ~operation:"read-export-ref" output in
          let* existing = object_id_of_hex commit.format output in
          if object_id_equal existing commit then Ok ()
          else
            Error
              (Export_error
                 ("target ref already names a different commit: " ^ target_ref))
      )

let export_release ?metadata ?runner ?fail_at configuration ~store ~repository
    ~release =
  let* configuration = validate_configuration configuration in
  let* repository = validate_repository_path repository in
  let* executable =
    match executable_path configuration.git with
    | Some executable -> Ok executable
    | None -> Error (Git_missing configuration.git)
  in
  let* inspection = inspect ?runner configuration ~repository in
  Store.with_lock store ~name:"git-export"
    ~on_error:(fun error -> Store_error error)
    (fun () ->
      let* release =
        Release.Durable.verify store release
        |> Result.map_error (fun error -> Release_error error)
      in
      let timestamp = Release.release_created_at release in
      if Int64.compare timestamp 0L < 0 then
        Error (Export_error "release creation timestamp must be nonnegative")
      else
        let* () =
          match metadata with
          | None -> Ok ()
          | Some metadata ->
              validate_release_export_metadata configuration metadata ~timestamp
        in
        let* release_object =
          Release.store_release store release
          |> Result.map_error (fun error -> Release_error error)
        in
        let snapshot_id = Release.release_final_snapshot release in
        let* snapshot =
          Snapshot.Snapshot.load store snapshot_id
          |> Result.map_error (fun error -> Snapshot_error error)
        in
        let author, committer, message, configured_metadata =
          match metadata with
          | Some metadata ->
              ( metadata.release_export_author,
                metadata.release_export_committer,
                metadata.release_export_message,
                true )
          | None ->
              ( default_export_identity,
                default_export_identity,
                Option.value
                  ~default:
                    ("Yeokcham release "
                    ^ Id.Release_id.to_hex (Release.release_id release)
                    ^ "\n")
                  (Release.release_message release),
                false )
        in
        let environment = export_environment ~timestamp ~author ~committer in
        let* files = export_files configuration store snapshot in
        let* tree =
          build_export_tree ?runner configuration executable repository
            ~environment ~format:inspection.object_format store files
        in
        let* commit =
          create_export_commit ?runner configuration executable repository
            ~environment ~format:inspection.object_format ~tree ~timestamp
            ~author ~committer ~message ~parents:[] ~configured_metadata
        in
        let target_ref =
          match metadata with
          | None -> export_ref (Release.release_id release)
          | Some metadata ->
              export_metadata_ref (Release.release_id release) metadata
        in
        let* () =
          match fail_at with
          | Some Before_git_ref ->
              Error (Injected_interruption "before Git ref publication")
          | Some Before_mapping_binding
          | Some (Before_revision_mapping_binding _)
          | None ->
              Ok ()
        in
        let* () =
          publish_export_ref ?runner configuration executable repository ~commit
            ~target_ref
        in
        let* _ =
          run ?runner configuration executable repository ~operation:"fsck"
            [ "--no-replace-objects"; "fsck"; "--full"; "--no-dangling" ]
        in
        let* () =
          match fail_at with
          | Some Before_mapping_binding ->
              Error (Injected_interruption "before Git mapping publication")
          | Some Before_git_ref
          | Some (Before_revision_mapping_binding _)
          | None ->
              Ok ()
        in
        let* mapping =
          create_mapping ~direction:Export ~git_object:commit ~git_kind:Commit
            ~subject:
              (Exported_release
                 {
                   release = Release.release_id release;
                   release_object;
                   final_snapshot = snapshot_id;
                 })
        in
        let* mapping = publish_mapping store mapping in
        let* mapping = load_mapping store mapping.id in
        Ok
          {
            export_release = Release.release_id release;
            export_release_object = release_object;
            export_snapshot = snapshot_id;
            export_tree = tree;
            export_commit = commit;
            export_target_ref = target_ref;
            export_mapping = mapping;
          })

type prepared_revision_export = {
  prepared_source : Capsule_store.revision_link;
  prepared_revision : Capsule_store.revision;
  prepared_snapshot : Snapshot.Snapshot.id;
  prepared_timestamp : int64;
  prepared_message : string;
}

type emitted_revision_export = {
  emitted_source : Capsule_store.revision_link;
  emitted_snapshot : Snapshot.Snapshot.id;
  emitted_tree : object_id;
  emitted_commit : object_id;
}

let revision_sources_equal left right =
  Id.Capsule_id.equal
    (Capsule_store.revision_link_capsule left)
    (Capsule_store.revision_link_capsule right)
  && Id.Capsule_revision_id.equal
       (Capsule_store.revision_link_revision left)
       (Capsule_store.revision_link_revision right)

let validate_revision_sources configuration revisions =
  let actual = List.length revisions in
  if actual = 0 then
    Error (Export_error "revision export requires one or more links")
  else if actual > configuration.max_export_commits then
    Error
      (Export_limit_exceeded
         {
           resource = "revision export commits";
           limit = configuration.max_export_commits;
           actual;
         })
  else
    let rec distinct seen = function
      | [] -> Ok ()
      | source :: rest ->
          if List.exists (revision_sources_equal source) seen then
            Error
              (Export_error
                 "revision export selection repeats a capsule/revision identity")
          else distinct (source :: seen) rest
    in
    distinct [] revisions

let add_sequence_component buffer value =
  add_u32 buffer (String.length value);
  Buffer.add_string buffer value

let revision_export_ref revisions =
  let bytes = Buffer.create (32 + (List.length revisions * 96)) in
  Buffer.add_string bytes "yeokcham:git-capsule-linear:v1\000";
  List.iter
    (fun source ->
      add_sequence_component bytes
        (Id.Capsule_id.to_bytes (Capsule_store.revision_link_capsule source));
      add_sequence_component bytes
        (Id.Capsule_revision_id.to_bytes
           (Capsule_store.revision_link_revision source));
      add_sequence_component bytes
        (Store.Stored_object_id.to_raw_bytes
           (Capsule_store.revision_link_object source)))
    revisions;
  let digest =
    Hash.digest_string (Buffer.contents bytes) |> Hash.to_raw_string
  in
  "refs/heads/yeokcham/capsule-linear-" ^ bytes_to_hex digest

let revision_export_message source =
  "Yeokcham capsule "
  ^ Id.Capsule_id.to_hex (Capsule_store.revision_link_capsule source)
  ^ " revision "
  ^ Id.Capsule_revision_id.to_hex (Capsule_store.revision_link_revision source)
  ^ "\n"

let prepare_revision_export store source =
  let* revision =
    Capsule_store.Durable.verify_link store source
    |> Result.map_error (fun error -> Capsule_error error)
  in
  let timestamp = Capsule_store.revision_created_at revision in
  if Int64.compare timestamp 0L < 0 then
    Error (Export_error "revision creation timestamp must be nonnegative")
  else
    let snapshot = Capsule_store.revision_expected_result revision in
    let* _ =
      Snapshot.Snapshot.load store snapshot
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    Ok
      {
        prepared_source = source;
        prepared_revision = revision;
        prepared_snapshot = snapshot;
        prepared_timestamp = timestamp;
        prepared_message = revision_export_message source;
      }

let validate_revision_export_chain revisions =
  let rec loop = function
    | [] | [ _ ] -> Ok ()
    | current :: (next :: _ as rest) ->
        if
          Snapshot.Snapshot.equal_id current.prepared_snapshot
            (Capsule_store.revision_declared_base next.prepared_revision)
        then loop rest
        else
          Error
            (Export_error
               "selected revisions do not form an \
                expected-result/declared-base chain")
  in
  loop revisions

let fail_before_revision_mapping fail_at index =
  match fail_at with
  | Some Before_mapping_binding when Int.equal index 0 ->
      Error (Injected_interruption "before Git revision mapping publication")
  | Some (Before_revision_mapping_binding target) when Int.equal target index ->
      Error
        (Injected_interruption
           ("before Git revision mapping publication at index "
          ^ string_of_int index))
  | Some Before_git_ref
  | Some Before_mapping_binding
  | Some (Before_revision_mapping_binding _)
  | None ->
      Ok ()

let export_revisions ?runner ?fail_at configuration ~store ~repository
    ~revisions =
  let* configuration = validate_configuration configuration in
  let* repository = validate_repository_path repository in
  let* () = validate_revision_sources configuration revisions in
  let* () =
    match fail_at with
    | Some (Before_revision_mapping_binding index)
      when index < 0 || index >= List.length revisions ->
        Error (Export_error "injected revision mapping index is out of range")
    | Some Before_git_ref
    | Some Before_mapping_binding
    | Some (Before_revision_mapping_binding _)
    | None ->
        Ok ()
  in
  let* executable =
    match executable_path configuration.git with
    | Some executable -> Ok executable
    | None -> Error (Git_missing configuration.git)
  in
  let* inspection = inspect ?runner configuration ~repository in
  Store.with_lock store ~name:"git-export"
    ~on_error:(fun error -> Store_error error)
    (fun () ->
      let* prepared =
        List.fold_left
          (fun result source ->
            let* reversed = result in
            let* prepared = prepare_revision_export store source in
            Ok (prepared :: reversed))
          (Ok []) revisions
        |> Result.map List.rev
      in
      let* () = validate_revision_export_chain prepared in
      let rec emit previous reversed = function
        | [] -> Ok (List.rev reversed)
        | current :: rest ->
            let environment =
              export_environment ~timestamp:current.prepared_timestamp
                ~author:default_export_identity
                ~committer:default_export_identity
            in
            let* snapshot =
              Snapshot.Snapshot.load store current.prepared_snapshot
              |> Result.map_error (fun error -> Snapshot_error error)
            in
            let* files = export_files configuration store snapshot in
            let* tree =
              build_export_tree ?runner configuration executable repository
                ~environment ~format:inspection.object_format store files
            in
            let parents = Option.to_list previous in
            let* commit =
              create_export_commit ?runner configuration executable repository
                ~environment ~format:inspection.object_format ~tree
                ~timestamp:current.prepared_timestamp
                ~author:default_export_identity
                ~committer:default_export_identity
                ~message:current.prepared_message ~parents
                ~configured_metadata:false
            in
            emit (Some commit)
              ({
                 emitted_source = current.prepared_source;
                 emitted_snapshot = current.prepared_snapshot;
                 emitted_tree = tree;
                 emitted_commit = commit;
               }
              :: reversed)
              rest
      in
      let* emitted = emit None [] prepared in
      let target_ref = revision_export_ref revisions in
      let tip = (List.hd (List.rev emitted)).emitted_commit in
      let* () =
        match fail_at with
        | Some Before_git_ref ->
            Error (Injected_interruption "before Git ref publication")
        | Some Before_mapping_binding
        | Some (Before_revision_mapping_binding _)
        | None ->
            Ok ()
      in
      let* () =
        publish_export_ref ?runner configuration executable repository
          ~commit:tip ~target_ref
      in
      let* _ =
        run ?runner configuration executable repository ~operation:"fsck"
          [ "--no-replace-objects"; "fsck"; "--full"; "--no-dangling" ]
      in
      let rec publish index reversed = function
        | [] -> Ok (List.rev reversed)
        | current :: rest ->
            let* () = fail_before_revision_mapping fail_at index in
            let* mapping =
              create_mapping ~direction:Export
                ~git_object:current.emitted_commit ~git_kind:Commit
                ~subject:
                  (Exported_revision
                     {
                       capsule =
                         Capsule_store.revision_link_capsule
                           current.emitted_source;
                       revision =
                         Capsule_store.revision_link_revision
                           current.emitted_source;
                       revision_object =
                         Capsule_store.revision_link_object
                           current.emitted_source;
                       final_snapshot = current.emitted_snapshot;
                     })
            in
            let* mapping = publish_mapping store mapping in
            let* mapping = load_mapping store mapping.id in
            publish (index + 1)
              ({
                 revision_export_source = current.emitted_source;
                 revision_export_snapshot = current.emitted_snapshot;
                 revision_export_tree = current.emitted_tree;
                 revision_export_commit = current.emitted_commit;
                 revision_export_mapping = mapping;
               }
              :: reversed)
              rest
      in
      let* exports = publish 0 [] emitted in
      Ok { revision_exports = exports; revision_export_target_ref = target_ref })

let archive_domain = "yeokcham:git-archive:v1\000"
let archive_v2_domain = "yeokcham:git-archive:v2\000"
let archive_binding_domain = "yeokcham:git-archive-binding:v1\000"

let archive_error_of_encoding error =
  Archive_error (Encoding.construction_error_to_string error)

let archive_array values =
  Encoding.array values |> Result.map_error archive_error_of_encoding

let archive_bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Archive_error (name ^ " must be bytes"))

let archive_integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Archive_error (name ^ " must be an integer"))

let archive_fields name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error
        (Archive_error (Printf.sprintf "%s must contain %d values" name length))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Archive_error (name ^ " must be an array"))

let archive_raw_id name parser value =
  let* raw = archive_bytes name value in
  if String.length raw <> 32 then
    Error
      (Archive_error
         (Printf.sprintf "%s must be exactly 32 bytes, got %d" name
            (String.length raw)))
  else
    parser raw
    |> Result.map_error (fun error ->
        Archive_error (Id.parse_error_to_string error))

let archive_stored_id name value =
  let* raw = archive_bytes name value in
  match Store.Stored_object_id.of_raw_bytes raw with
  | Some identity -> Ok identity
  | None ->
      Error
        (Archive_error
           (Printf.sprintf "%s must be exactly 32 bytes, got %d" name
              (String.length raw)))

let archive_format_code = function Sha1 -> 1L | Sha256 -> 2L

let archive_format_of_code = function
  | 1L -> Ok Sha1
  | 2L -> Ok Sha256
  | value ->
      Error
        (Archive_error
           (Printf.sprintf "unknown Git archive object format: %Ld" value))

let archive_boolean name = function
  | Encoding.Bool value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
  | Encoding.Map _ | Encoding.Null ->
      Error (Archive_error (name ^ " must be a Boolean"))

let archive_capability_value capability =
  archive_array
    [
      Encoding.bool capability.archive_source_bare;
      Encoding.integer
        (archive_format_code capability.archive_source_object_format);
    ]

let decode_archive_capability value =
  let* fields = archive_fields "Git archive capability" 2 value in
  match fields with
  | [ bare; object_format ] ->
      let* archive_source_bare =
        archive_boolean "Git archive source bare flag" bare
      in
      let* object_format =
        archive_integer "Git archive source object format" object_format
      in
      let* archive_source_object_format =
        archive_format_of_code object_format
      in
      Ok { archive_source_bare; archive_source_object_format }
  | _ -> assert false

let archive_ref_value format reference =
  if String.is_empty reference.archive_ref_name then
    Error (Archive_error "Git archive ref name must not be empty")
  else if
    String.contains reference.archive_ref_name '\000'
    || String.contains reference.archive_ref_name '\n'
    || String.contains reference.archive_ref_name '\r'
  then Error (Archive_error "Git archive ref name contains a forbidden byte")
  else if reference.archive_ref_object.format <> format then
    Error (Archive_error "Git archive ref has a different object format")
  else
    archive_array
      [
        Encoding.bytes reference.archive_ref_name;
        Encoding.bytes reference.archive_ref_object.raw;
      ]

let archive_ref_values format references =
  let rec loop previous reversed = function
    | [] -> archive_array (List.rev reversed)
    | reference :: rest ->
        let* () =
          match previous with
          | None -> Ok ()
          | Some previous
            when String.compare previous reference.archive_ref_name < 0 ->
              Ok ()
          | Some _ ->
              Error
                (Archive_error
                   "Git archive refs must be strictly bytewise ordered")
        in
        let* value = archive_ref_value format reference in
        loop (Some reference.archive_ref_name) (value :: reversed) rest
  in
  loop None [] references

let archive_identity_payload version format capability references =
  let* references = archive_ref_values format references in
  match (version, capability) with
  | 1, None ->
      archive_array
        [
          Encoding.integer 1L;
          Encoding.integer (archive_format_code format);
          references;
        ]
  | 2, Some capability when capability.archive_source_object_format = format ->
      let* capability = archive_capability_value capability in
      archive_array [ Encoding.integer 2L; capability; references ]
  | 1, Some _ | 2, None | _, _ ->
      Error (Archive_error "invalid Git archive version and capability report")

let derive_archive_id version format capability references =
  let* identity =
    archive_identity_payload version format capability references
  in
  let domain =
    match version with 1 -> archive_domain | 2 -> archive_v2_domain | _ -> ""
  in
  if String.is_empty domain then
    Error (Archive_error "unsupported Git archive version")
  else
    let raw =
      Hash.feed_string Hash.empty domain |> fun context ->
      Hash.feed_string context (Encoding.encode identity)
      |> Hash.get |> Hash.to_raw_string
    in
    Id.Git_archive_id.of_bytes raw
    |> Result.map_error (fun error ->
        Archive_error (Id.parse_error_to_string error))

let create_archive ~version ~format ~capability ~bundle ~refs =
  let* archive_identity = derive_archive_id version format capability refs in
  Ok
    {
      archive_version = version;
      archive_identity;
      archive_format = format;
      archive_source_capability = capability;
      archive_content = bundle;
      archive_ref_inventory = refs;
    }

let archive_payload archive =
  let* refs =
    archive_ref_values archive.archive_format archive.archive_ref_inventory
  in
  let* archive_identity =
    archive_raw_id "Git archive ID" Id.Git_archive_id.of_bytes
      (Encoding.bytes (Id.Git_archive_id.to_bytes archive.archive_identity))
  in
  let archive_identity =
    Encoding.bytes (Id.Git_archive_id.to_bytes archive_identity)
  in
  let bundle =
    Snapshot.Content.stored_object_id archive.archive_content
    |> Store.Stored_object_id.to_raw_bytes |> Encoding.bytes
  in
  match (archive.archive_version, archive.archive_source_capability) with
  | 1, None ->
      archive_array
        [
          Encoding.integer 1L;
          archive_identity;
          Encoding.integer (archive_format_code archive.archive_format);
          bundle;
          refs;
        ]
  | 2, Some capability
    when capability.archive_source_object_format = archive.archive_format ->
      let* capability = archive_capability_value capability in
      archive_array
        [ Encoding.integer 2L; archive_identity; capability; bundle; refs ]
  | 1, Some _ | 2, None | _, _ ->
      Error (Archive_error "invalid Git archive version and capability report")

let archive_envelope archive =
  let* payload = archive_payload archive in
  Envelope.create ~object_type:Envelope.Git_archive
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error ->
      Archive_error (Envelope.creation_error_to_string error))

let decode_archive_ref format value =
  let* fields = archive_fields "Git archive ref" 2 value in
  match fields with
  | [ name; object_raw ] ->
      let* archive_ref_name = archive_bytes "Git archive ref name" name in
      let* raw = archive_bytes "Git archive ref object ID" object_raw in
      let* archive_ref_object =
        object_id_of_raw format raw
        |> Result.map_error (fun error -> Archive_error (error_to_string error))
      in
      Ok { archive_ref_name; archive_ref_object }
  | _ -> assert false

let decode_archive_refs format value =
  match value with
  | Encoding.Array values ->
      let rec loop reversed = function
        | [] -> Ok (List.rev reversed)
        | value :: rest ->
            let* reference = decode_archive_ref format value in
            loop (reference :: reversed) rest
      in
      loop [] values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Archive_error "Git archive refs must be an array")

let decode_archive_payload value =
  let fields =
    match value with
    | Encoding.Array fields -> Ok fields
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null ->
        Error (Archive_error "Git archive must be an array")
  in
  let* fields = fields in
  match fields with
  | [ version; supplied_id; format_or_capability; bundle; refs ] ->
      let* version = archive_integer "Git archive version" version in
      if Int64.equal version 1L then
        let* supplied_id =
          archive_raw_id "Git archive ID" Id.Git_archive_id.of_bytes supplied_id
        in
        let* format =
          archive_integer "Git archive object format" format_or_capability
        in
        let* format = archive_format_of_code format in
        let* bundle =
          archive_stored_id "Git archive bundle content ID" bundle
        in
        let* refs = decode_archive_refs format refs in
        let* archive =
          create_archive ~version:1 ~format ~capability:None
            ~bundle:(Snapshot.Content.of_stored_object_id bundle)
            ~refs
        in
        if not (Id.Git_archive_id.equal supplied_id archive.archive_identity)
        then
          Error
            (Archive_error "Git archive logical ID does not match its preimage")
        else
          let* canonical = archive_payload archive in
          if String.equal (Encoding.encode canonical) (Encoding.encode value)
          then Ok archive
          else Error (Archive_error "Git archive payload is noncanonical")
      else if Int64.equal version 2L then
        let* supplied_id =
          archive_raw_id "Git archive ID" Id.Git_archive_id.of_bytes supplied_id
        in
        let* capability = decode_archive_capability format_or_capability in
        let* bundle =
          archive_stored_id "Git archive bundle content ID" bundle
        in
        let* refs =
          decode_archive_refs capability.archive_source_object_format refs
        in
        let* archive =
          create_archive ~version:2
            ~format:capability.archive_source_object_format
            ~capability:(Some capability)
            ~bundle:(Snapshot.Content.of_stored_object_id bundle)
            ~refs
        in
        if not (Id.Git_archive_id.equal supplied_id archive.archive_identity)
        then
          Error
            (Archive_error "Git archive logical ID does not match its preimage")
        else
          let* canonical = archive_payload archive in
          if String.equal (Encoding.encode canonical) (Encoding.encode value)
          then Ok archive
          else Error (Archive_error "Git archive payload is noncanonical")
      else
        Error
          (Archive_error
             (Printf.sprintf "unsupported Git archive version: %Ld" version))
  | _ -> Error (Archive_error "Git archive has an unsupported field count")

let archive_binding_body archive_identity physical =
  archive_array
    [
      Encoding.integer 1L;
      Encoding.bytes (Id.Git_archive_id.to_bytes archive_identity);
      Encoding.bytes (Store.Stored_object_id.to_raw_bytes physical);
    ]

let archive_binding_checksum body =
  Hash.feed_string Hash.empty archive_binding_domain |> fun context ->
  Hash.feed_string context (Encoding.encode body)
  |> Hash.get |> Hash.to_raw_string

let encode_archive_binding archive_identity physical =
  let* body = archive_binding_body archive_identity physical in
  archive_array
    [
      Encoding.integer 1L;
      Encoding.bytes (Id.Git_archive_id.to_bytes archive_identity);
      Encoding.bytes (Store.Stored_object_id.to_raw_bytes physical);
      Encoding.bytes (archive_binding_checksum body);
    ]
  |> Result.map Encoding.encode

let decode_archive_binding bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error ->
        Archive_error (Encoding.decode_error_to_string error))
  in
  let* fields = archive_fields "Git archive binding" 4 value in
  match fields with
  | [ version; archive_identity; physical; checksum ] ->
      let* version = archive_integer "Git archive binding version" version in
      if not (Int64.equal version 1L) then
        Error
          (Archive_error
             (Printf.sprintf "unsupported Git archive binding version: %Ld"
                version))
      else
        let* archive_identity =
          archive_raw_id "Git archive binding ID" Id.Git_archive_id.of_bytes
            archive_identity
        in
        let* physical =
          archive_stored_id "Git archive binding object ID" physical
        in
        let* checksum = archive_bytes "Git archive binding checksum" checksum in
        if String.length checksum <> 32 then
          Error (Archive_error "Git archive binding checksum must be 32 bytes")
        else
          let* body = archive_binding_body archive_identity physical in
          if not (String.equal checksum (archive_binding_checksum body)) then
            Error (Archive_error "Git archive binding checksum mismatch")
          else
            let* canonical = encode_archive_binding archive_identity physical in
            if String.equal canonical bytes then Ok (archive_identity, physical)
            else Error (Archive_error "Git archive binding is noncanonical")
  | _ -> assert false

let archive_ref_components archive_identity =
  [ "git-archives"; Id.Git_archive_id.to_hex archive_identity ]

let load_archive_from_binding store archive_identity binding =
  let* bound_identity, physical = decode_archive_binding binding in
  if not (Id.Git_archive_id.equal bound_identity archive_identity) then
    Error
      (Archive_error "Git archive binding logical ID disagrees with its path")
  else
    let* envelope =
      Store.get store physical
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type envelope <> Envelope.Git_archive then
      Error
        (Archive_error
           (Printf.sprintf "expected Git archive object type 29, got %d"
              (Envelope.object_type_code (Envelope.object_type envelope))))
    else
      let* archive = decode_archive_payload (Envelope.payload envelope) in
      if not (Id.Git_archive_id.equal archive.archive_identity archive_identity)
      then
        Error (Archive_error "Git archive object ID disagrees with its binding")
      else
        Snapshot.Content.load store archive.archive_content
        |> Result.map_error (fun error ->
            Archive_error
              ("Git archive bundle content is unavailable: "
              ^ Snapshot.error_to_string error))
        |> Result.map (fun _ -> archive)

let load_archive store archive_identity =
  let components = archive_ref_components archive_identity in
  let* binding =
    Store.Ref_file.read store ~components
    |> Result.map_error (fun error -> Store_error error)
  in
  match binding with
  | None -> Error (Archive_error "Git archive binding is absent")
  | Some binding -> load_archive_from_binding store archive_identity binding

let list_archives store =
  let directory =
    Filename.concat
      (Filename.concat (Filename.concat (Store.root store) ".yeokcham") "refs")
      "git-archives"
  in
  if not (Sys.file_exists directory) then Ok []
  else
    try
      let entries =
        Sys.readdir directory |> Array.to_list |> List.sort String.compare
      in
      let rec loop reversed = function
        | [] -> Ok (List.rev reversed)
        | entry :: rest ->
            let* archive_identity =
              Id.Git_archive_id.of_hex entry
              |> Result.map_error (fun error ->
                  Archive_error
                    ("invalid Git archive binding filename: "
                    ^ Id.parse_error_to_string error))
            in
            let* archive = load_archive store archive_identity in
            loop (archive :: reversed) rest
      in
      loop [] entries
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
    | Sys_error message -> Error (Archive_error message)

let publish_archive store archive =
  let* envelope = archive_envelope archive in
  let* physical =
    Store.put store envelope
    |> Result.map_error (fun error -> Store_error error)
  in
  let* binding = encode_archive_binding archive.archive_identity physical in
  Store.with_lock store ~name:"git-archives"
    ~on_error:(fun error -> Store_error error)
    (fun () ->
      let components = archive_ref_components archive.archive_identity in
      let* current =
        Store.Ref_file.read store ~components
        |> Result.map_error (fun error -> Store_error error)
      in
      match current with
      | None ->
          Store.Ref_file.compare_and_swap store ~components ~expected:None
            ~replacement:binding
          |> Result.map_error (fun error -> Store_error error)
          |> Result.map (fun () -> archive)
      | Some current ->
          load_archive_from_binding store archive.archive_identity current)

let archive_refs_of_output format output =
  let lines =
    String.split_on_char '\n' output
    |> List.filter (fun line -> not (String.is_empty line))
  in
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | line :: rest -> (
        match String.split_on_char '\000' line with
        | [ archive_ref_name; object_hex ] ->
            let* archive_ref_object =
              object_id_of_hex format object_hex
              |> Result.map_error (fun error ->
                  Archive_error (error_to_string error))
            in
            loop ({ archive_ref_name; archive_ref_object } :: reversed) rest
        | _ ->
            Error
              (Archive_error
                 "Git ref inventory did not contain exactly one ref and object \
                  ID"))
  in
  let* refs = loop [] lines in
  if refs = [] then
    Error (Archive_error "Git repository has no refs to archive")
  else
    let* _ = archive_ref_values format refs in
    Ok refs

let archive_refs_for_repository ?runner configuration executable repository
    format =
  let* output =
    run ?runner configuration executable repository
      ~operation:"archive-ref-inventory"
      [
        "--no-replace-objects";
        "for-each-ref";
        "--sort=refname";
        "--format=%(refname)%00%(objectname)";
      ]
  in
  archive_refs_of_output format output

let select_archive_refs requested available =
  if requested = [] then Ok available
  else
    let requested = List.sort String.compare requested in
    let rec requested_names previous = function
      | [] -> Ok ()
      | name :: rest ->
          if
            String.is_empty name
            || String.contains name '\000'
            || String.contains name '\n' || String.contains name '\r'
          then Error (Archive_error "requested Git ref name is malformed")
          else
            let* () =
              match previous with
              | None -> Ok ()
              | Some previous when String.compare previous name < 0 -> Ok ()
              | Some _ ->
                  Error (Archive_error "requested Git ref name is duplicated")
            in
            requested_names (Some name) rest
    in
    let* () = requested_names None requested in
    let rec select selected requested available =
      match (requested, available) with
      | [], _ -> Ok (List.rev selected)
      | requested_name :: _, [] ->
          Error
            (Archive_error ("requested Git ref is absent: " ^ requested_name))
      | requested_name :: requested_rest, candidate :: available_rest ->
          let comparison =
            String.compare requested_name candidate.archive_ref_name
          in
          if comparison = 0 then
            select (candidate :: selected) requested_rest available_rest
          else if comparison < 0 then
            Error
              (Archive_error ("requested Git ref is absent: " ^ requested_name))
          else select selected requested available_rest
    in
    select [] requested available

let archive_is_shallow ?runner configuration executable repository =
  let* output =
    run ?runner configuration executable repository
      ~operation:"archive-is-shallow"
      [ "rev-parse"; "--is-shallow-repository" ]
  in
  let* output = single_line ~operation:"archive-is-shallow" output in
  parse_boolean ~operation:"archive-is-shallow" output

let read_archive_bundle configuration path =
  try
    let size = (Unix.stat path).Unix.st_size in
    if size < 0 || size > configuration.max_archive_bytes then
      Error
        (Archive_error
           (Printf.sprintf "Git bundle exceeds archive limit (%d > %d)" size
              configuration.max_archive_bytes))
    else
      In_channel.with_open_bin path (fun channel ->
          let bytes = In_channel.input_all channel in
          if String.length bytes <> size then
            Error (Archive_error "Git bundle changed while being read")
          else Ok bytes)
  with
  | Unix.Unix_error (error, operation, argument) ->
      Error
        (Archive_error
           (Unix.error_message error ^ ": " ^ operation ^ " " ^ argument))
  | Sys_error message -> Error (Archive_error message)

let with_temporary_archive label run =
  try
    let path = Filename.temp_file ("yeokcham-git-" ^ label ^ "-") ".bundle" in
    Fun.protect
      ~finally:(fun () ->
        try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
      (fun () -> run path)
  with
  | Unix.Unix_error (error, operation, argument) ->
      Error
        (Archive_error
           (Unix.error_message error ^ ": " ^ operation ^ " " ^ argument))
  | Sys_error message -> Error (Archive_error message)

let archive_repository ?runner ?(refs = []) configuration ~store ~repository =
  let* configuration = validate_configuration configuration in
  let* repository = validate_repository_path repository in
  let* executable =
    match executable_path configuration.git with
    | Some executable -> Ok executable
    | None -> Error (Git_missing configuration.git)
  in
  let* inspection = inspect ?runner configuration ~repository in
  let* shallow =
    archive_is_shallow ?runner configuration executable repository
  in
  if shallow then
    Error (Archive_error "shallow Git repositories are not archivable")
  else
    let* available_before =
      archive_refs_for_repository ?runner configuration executable repository
        inspection.object_format
    in
    let* before = select_archive_refs refs available_before in
    with_temporary_archive "archive" (fun path ->
        let* () =
          try
            Unix.unlink path;
            Ok ()
          with Unix.Unix_error (error, operation, argument) ->
            Error
              (Archive_error
                 (Unix.error_message error ^ ": " ^ operation ^ " " ^ argument))
        in
        let* _ =
          run ?runner configuration executable repository
            ~operation:"archive-bundle-create"
            ([ "--no-replace-objects"; "bundle"; "create"; path ]
            @ if refs = [] then [ "--all" ] else List.map (fun ref -> ref) refs
            )
        in
        let* _ =
          run ?runner configuration executable repository
            ~operation:"archive-bundle-verify"
            [ "bundle"; "verify"; path ]
        in
        let* available_after =
          archive_refs_for_repository ?runner configuration executable
            repository inspection.object_format
        in
        let* after = select_archive_refs refs available_after in
        let same_inventory =
          List.length before = List.length after
          && List.for_all2
               (fun left right ->
                 String.equal left.archive_ref_name right.archive_ref_name
                 && String.equal left.archive_ref_object.raw
                      right.archive_ref_object.raw)
               before after
        in
        if not same_inventory then
          Error (Archive_error "Git refs changed while archive creation ran")
        else
          let* bundle = read_archive_bundle configuration path in
          let* content =
            Snapshot.Content.store store bundle
            |> Result.map_error (fun error ->
                Archive_error
                  ("unable to store Git bundle content: "
                  ^ Snapshot.error_to_string error))
          in
          let* archive =
            create_archive ~version:2 ~format:inspection.object_format
              ~capability:
                (Some
                   {
                     archive_source_bare = inspection.bare;
                     archive_source_object_format = inspection.object_format;
                   })
              ~bundle:content ~refs:before
          in
          publish_archive store archive)

let validate_archive_destination destination =
  if String.is_empty destination then
    Error (Archive_error "destination is empty")
  else if String.length destination > maximum_repository_path_bytes then
    Error
      (Archive_error
         (Printf.sprintf "destination exceeds %d bytes"
            maximum_repository_path_bytes))
  else if String.contains destination '\000' then
    Error (Archive_error "destination contains NUL")
  else if Filename.is_relative destination then
    Error (Archive_error "destination must be absolute")
  else
    try
      let parent = Filename.dirname destination in
      if (Unix.stat parent).Unix.st_kind <> Unix.S_DIR then
        Error (Archive_error "destination parent is not a directory")
      else
        match (Unix.lstat destination).Unix.st_kind with
        | Unix.S_DIR ->
            if Array.length (Sys.readdir destination) = 0 then Ok destination
            else Error (Archive_error "destination directory is not empty")
        | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
        | Unix.S_SOCK ->
            Error (Archive_error "destination exists and is not a directory")
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok destination
    | Unix.Unix_error (error, operation, argument) ->
        Error
          (Archive_error
             (Unix.error_message error ^ ": " ^ operation ^ " " ^ argument))
    | Sys_error message -> Error (Archive_error message)

let exit_archive ?runner configuration ~store ~archive ~destination =
  let* configuration = validate_configuration configuration in
  let* destination = validate_archive_destination destination in
  let* archive = load_archive store archive in
  let* executable =
    match executable_path configuration.git with
    | Some executable -> Ok executable
    | None -> Error (Git_missing configuration.git)
  in
  let* bundle =
    Snapshot.Content.load store archive.archive_content
    |> Result.map_error (fun error ->
        Archive_error
          ("Git archive bundle content is unavailable: "
          ^ Snapshot.error_to_string error))
  in
  with_temporary_archive "exit" (fun path ->
      try
        Out_channel.with_open_bin path (fun channel ->
            Out_channel.output_string channel bundle);
        let* _ =
          run ?runner configuration executable (Filename.dirname path)
            ~operation:"archive-exit-clone"
            [ "clone"; "--mirror"; "--no-local"; path; destination ]
        in
        let* inspection =
          inspect ?runner configuration ~repository:destination
        in
        if inspection.object_format <> archive.archive_format then
          Error
            (Archive_error
               "reconstructed Git object format does not match archive")
        else
          let* _ =
            run ?runner configuration executable destination
              ~operation:"archive-exit-fsck" [ "fsck"; "--full" ]
          in
          let* refs =
            archive_refs_for_repository ?runner configuration executable
              destination archive.archive_format
          in
          let same_inventory =
            List.length refs = List.length archive.archive_ref_inventory
            && List.for_all2
                 (fun left right ->
                   String.equal left.archive_ref_name right.archive_ref_name
                   && String.equal left.archive_ref_object.raw
                        right.archive_ref_object.raw)
                 refs archive.archive_ref_inventory
          in
          if same_inventory then Ok archive
          else
            Error
              (Archive_error
                 "reconstructed Git ref inventory does not match archive")
      with
      | Unix.Unix_error (error, operation, argument) ->
          Error
            (Archive_error
               (Unix.error_message error ^ ": " ^ operation ^ " " ^ argument))
      | Sys_error message -> Error (Archive_error message))

let archive_id archive = archive.archive_identity
let archive_object_format archive = archive.archive_format
let archive_refs archive = archive.archive_ref_inventory
let archive_bundle archive = archive.archive_content
let archive_capability archive = archive.archive_source_capability

let with_temporary_archive_directory label run =
  let rec remove path =
    try
      match (Unix.lstat path).Unix.st_kind with
      | Unix.S_DIR ->
          Sys.readdir path
          |> Array.iter (fun name -> remove (Filename.concat path name));
          Unix.rmdir path
      | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
      | Unix.S_SOCK ->
          Unix.unlink path
    with Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  in
  try
    let path = Filename.temp_file ("yeokcham-git-" ^ label ^ "-") "" in
    Unix.unlink path;
    Unix.mkdir path 0o700;
    Fun.protect ~finally:(fun () -> remove path) (fun () -> run path)
  with
  | Unix.Unix_error (error, operation, argument) ->
      Error
        (Adoption_error
           (Unix.error_message error ^ ": " ^ operation ^ " " ^ argument))
  | Sys_error message -> Error (Adoption_error message)

let import_archive_commit ?runner configuration ~store ~archive ~commit =
  let* preserved = load_archive store archive in
  if preserved.archive_format <> commit.format then
    Error
      (Adoption_error
         "selected Git commit object format does not match the archive")
  else
    with_temporary_archive_directory "archive-adopt" (fun repository ->
        let* _ =
          exit_archive ?runner configuration ~store ~archive
            ~destination:repository
        in
        import_commit ?runner configuration ~store ~repository ~commit)

let adoption_domain = "yeokcham:git-adoption:v1\000"
let adoption_binding_domain = "yeokcham:git-adoption-binding:v1\000"

let adoption_error_of_encoding error =
  Adoption_error (Encoding.construction_error_to_string error)

let adoption_array values =
  Encoding.array values |> Result.map_error adoption_error_of_encoding

let adoption_bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Adoption_error (name ^ " must be bytes"))

let adoption_integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Adoption_error (name ^ " must be an integer"))

let adoption_fields name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error
        (Adoption_error (Printf.sprintf "%s must contain %d values" name length))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Adoption_error (name ^ " must be an array"))

let adoption_raw_id name parser value =
  let* raw = adoption_bytes name value in
  if String.length raw <> 32 then
    Error
      (Adoption_error
         (Printf.sprintf "%s must be exactly 32 bytes, got %d" name
            (String.length raw)))
  else
    parser raw
    |> Result.map_error (fun error ->
        Adoption_error (Id.parse_error_to_string error))

let adoption_object_value format identity =
  if identity.format <> format then
    Error (Adoption_error "Git adoption object format disagrees with archive")
  else Ok (Encoding.bytes identity.raw)

let decode_adoption_object format name value =
  let* raw = adoption_bytes name value in
  object_id_of_raw format raw
  |> Result.map_error (fun error -> Adoption_error (error_to_string error))

let adoption_optional_object_value format = function
  | None -> Ok Encoding.null
  | Some identity -> adoption_object_value format identity

let decode_adoption_optional_object format name = function
  | Encoding.Null -> Ok None
  | ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
    | Encoding.Map _ | Encoding.Bool _ ) as value ->
      decode_adoption_object format name value |> Result.map Option.some

let adoption_optional_id_value render = function
  | None -> Ok Encoding.null
  | Some identity -> Ok (Encoding.bytes (render identity))

let decode_adoption_optional_id name parser = function
  | Encoding.Null -> Ok None
  | ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
    | Encoding.Map _ | Encoding.Bool _ ) as value ->
      adoption_raw_id name parser value |> Result.map Option.some

let adoption_identity_payload adoption =
  let* commit =
    adoption_object_value adoption.adoption_format adoption.adoption_commit
  in
  let* parent =
    adoption_optional_object_value adoption.adoption_format
      adoption.adoption_parent
  in
  let transition =
    Encoding.bytes
      (Id.Imported_transition_id.to_bytes adoption.adoption_transition)
  in
  let mapping =
    Encoding.bytes (Id.Git_mapping_id.to_bytes adoption.adoption_mapping)
  in
  let* parent_transition =
    adoption_optional_id_value Id.Imported_transition_id.to_bytes
      adoption.adoption_parent_transition
  in
  let* parent_mapping =
    adoption_optional_id_value Id.Git_mapping_id.to_bytes
      adoption.adoption_parent_mapping
  in
  let capsule =
    Encoding.bytes (Id.Capsule_id.to_bytes adoption.adoption_capsule)
  in
  let revision =
    Encoding.bytes (Id.Capsule_revision_id.to_bytes adoption.adoption_revision)
  in
  let source =
    Encoding.bytes
      (Scratch.Checkpoint_id.stored_object_id adoption.adoption_source
      |> Store.Stored_object_id.to_raw_bytes)
  in
  let target =
    Encoding.bytes
      (Scratch.Checkpoint_id.stored_object_id adoption.adoption_target
      |> Store.Stored_object_id.to_raw_bytes)
  in
  adoption_array
    [
      Encoding.integer 1L;
      Encoding.bytes (Id.Git_archive_id.to_bytes adoption.adoption_archive);
      Encoding.integer (archive_format_code adoption.adoption_format);
      commit;
      parent;
      transition;
      mapping;
      parent_transition;
      parent_mapping;
      capsule;
      revision;
      source;
      target;
    ]

let derive_adoption_id adoption =
  let* identity = adoption_identity_payload adoption in
  let raw =
    Hash.feed_string Hash.empty adoption_domain |> fun context ->
    Hash.feed_string context (Encoding.encode identity)
    |> Hash.get |> Hash.to_raw_string
  in
  Id.Git_adoption_id.of_bytes raw
  |> Result.map_error (fun error ->
      Adoption_error (Id.parse_error_to_string error))

let make_adoption ~archive ~format ~commit ~parent ~transition ~mapping
    ~parent_transition ~parent_mapping ~capsule ~revision ~source ~target =
  let provisional =
    {
      adoption_identity =
        Id.Git_adoption_id.of_bytes (String.make 32 '\000') |> Result.get_ok;
      adoption_archive = archive;
      adoption_format = format;
      adoption_commit = commit;
      adoption_parent = parent;
      adoption_transition = transition;
      adoption_mapping = mapping;
      adoption_parent_transition = parent_transition;
      adoption_parent_mapping = parent_mapping;
      adoption_capsule = capsule;
      adoption_revision = revision;
      adoption_source = source;
      adoption_target = target;
    }
  in
  let* adoption_identity = derive_adoption_id provisional in
  Ok { provisional with adoption_identity }

let adoption_payload adoption =
  let* identity = adoption_identity_payload adoption in
  let supplied_id =
    Encoding.bytes (Id.Git_adoption_id.to_bytes adoption.adoption_identity)
  in
  match identity with
  | Encoding.Array (_ :: rest) ->
      adoption_array (Encoding.integer 1L :: supplied_id :: rest)
  | Encoding.Array [] -> assert false
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      assert false

let adoption_envelope adoption =
  let* payload = adoption_payload adoption in
  Envelope.create ~object_type:Envelope.Git_adoption
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error ->
      Adoption_error (Envelope.creation_error_to_string error))

let checkpoint_id_of_adoption_value name value =
  let* raw = adoption_bytes name value in
  match Store.Stored_object_id.of_raw_bytes raw with
  | Some identity -> Ok (Scratch.Checkpoint_id.of_stored_object_id identity)
  | None ->
      Error
        (Adoption_error
           (Printf.sprintf "%s must be exactly 32 bytes, got %d" name
              (String.length raw)))

let decode_adoption_payload value =
  let* fields = adoption_fields "Git adoption" 14 value in
  match fields with
  | [
   version;
   supplied_id;
   archive;
   format;
   commit;
   parent;
   transition;
   mapping;
   parent_transition;
   parent_mapping;
   capsule;
   revision;
   source;
   target;
  ] ->
      let* version = adoption_integer "Git adoption version" version in
      if not (Int64.equal version 1L) then
        Error
          (Adoption_error
             (Printf.sprintf "unsupported Git adoption version: %Ld" version))
      else
        let* adoption_identity =
          adoption_raw_id "Git adoption ID" Id.Git_adoption_id.of_bytes
            supplied_id
        in
        let* adoption_archive =
          adoption_raw_id "Git adoption archive ID" Id.Git_archive_id.of_bytes
            archive
        in
        let* format = adoption_integer "Git adoption object format" format in
        let* adoption_format =
          match format with
          | 1L -> Ok Sha1
          | 2L -> Ok Sha256
          | value ->
              Error
                (Adoption_error
                   (Printf.sprintf "unknown Git adoption object format: %Ld"
                      value))
        in
        let* adoption_commit =
          decode_adoption_object adoption_format "Git adoption commit" commit
        in
        let* adoption_parent =
          decode_adoption_optional_object adoption_format "Git adoption parent"
            parent
        in
        let* adoption_transition =
          adoption_raw_id "Git adoption transition ID"
            Id.Imported_transition_id.of_bytes transition
        in
        let* adoption_mapping =
          adoption_raw_id "Git adoption mapping ID" Id.Git_mapping_id.of_bytes
            mapping
        in
        let* adoption_parent_transition =
          decode_adoption_optional_id "Git adoption parent transition ID"
            Id.Imported_transition_id.of_bytes parent_transition
        in
        let* adoption_parent_mapping =
          decode_adoption_optional_id "Git adoption parent mapping ID"
            Id.Git_mapping_id.of_bytes parent_mapping
        in
        let* adoption_capsule =
          adoption_raw_id "Git adoption capsule ID" Id.Capsule_id.of_bytes
            capsule
        in
        let* adoption_revision =
          adoption_raw_id "Git adoption revision ID"
            Id.Capsule_revision_id.of_bytes revision
        in
        let* adoption_source =
          checkpoint_id_of_adoption_value "Git adoption source checkpoint"
            source
        in
        let* adoption_target =
          checkpoint_id_of_adoption_value "Git adoption target checkpoint"
            target
        in
        let* adoption =
          make_adoption ~archive:adoption_archive ~format:adoption_format
            ~commit:adoption_commit ~parent:adoption_parent
            ~transition:adoption_transition ~mapping:adoption_mapping
            ~parent_transition:adoption_parent_transition
            ~parent_mapping:adoption_parent_mapping ~capsule:adoption_capsule
            ~revision:adoption_revision ~source:adoption_source
            ~target:adoption_target
        in
        if
          not
            (Id.Git_adoption_id.equal adoption_identity
               adoption.adoption_identity)
        then
          Error
            (Adoption_error
               "Git adoption logical ID does not match its preimage")
        else
          let* canonical = adoption_payload adoption in
          if String.equal (Encoding.encode canonical) (Encoding.encode value)
          then Ok adoption
          else Error (Adoption_error "Git adoption payload is noncanonical")
  | _ -> assert false

let adoption_binding_body adoption_identity physical =
  adoption_array
    [
      Encoding.integer 1L;
      Encoding.bytes (Id.Git_adoption_id.to_bytes adoption_identity);
      Encoding.bytes (Store.Stored_object_id.to_raw_bytes physical);
    ]

let adoption_binding_checksum body =
  Hash.feed_string Hash.empty adoption_binding_domain |> fun context ->
  Hash.feed_string context (Encoding.encode body)
  |> Hash.get |> Hash.to_raw_string

let encode_adoption_binding adoption_identity physical =
  let* body = adoption_binding_body adoption_identity physical in
  adoption_array
    [
      Encoding.integer 1L;
      Encoding.bytes (Id.Git_adoption_id.to_bytes adoption_identity);
      Encoding.bytes (Store.Stored_object_id.to_raw_bytes physical);
      Encoding.bytes (adoption_binding_checksum body);
    ]
  |> Result.map Encoding.encode

let decode_adoption_binding bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error ->
        Adoption_error (Encoding.decode_error_to_string error))
  in
  let* fields = adoption_fields "Git adoption binding" 4 value in
  match fields with
  | [ version; adoption_identity; physical; checksum ] ->
      let* version = adoption_integer "Git adoption binding version" version in
      if not (Int64.equal version 1L) then
        Error
          (Adoption_error
             (Printf.sprintf "unsupported Git adoption binding version: %Ld"
                version))
      else
        let* adoption_identity =
          adoption_raw_id "Git adoption binding ID" Id.Git_adoption_id.of_bytes
            adoption_identity
        in
        let* physical_raw =
          adoption_bytes "Git adoption binding object ID" physical
        in
        let* physical =
          match Store.Stored_object_id.of_raw_bytes physical_raw with
          | Some identity -> Ok identity
          | None ->
              Error
                (Adoption_error
                   "Git adoption binding object ID must be exactly 32 bytes")
        in
        let* checksum =
          adoption_bytes "Git adoption binding checksum" checksum
        in
        if String.length checksum <> 32 then
          Error
            (Adoption_error "Git adoption binding checksum must be 32 bytes")
        else
          let* body = adoption_binding_body adoption_identity physical in
          if not (String.equal checksum (adoption_binding_checksum body)) then
            Error (Adoption_error "Git adoption binding checksum mismatch")
          else
            let* canonical =
              encode_adoption_binding adoption_identity physical
            in
            if String.equal canonical bytes then Ok (adoption_identity, physical)
            else Error (Adoption_error "Git adoption binding is noncanonical")
  | _ -> assert false

let adoption_ref_components adoption_identity =
  [ "git-adoptions"; Id.Git_adoption_id.to_hex adoption_identity ]

let mapping_matches_transition mapping transition commit =
  mapping.direction = Import && mapping.git_kind = Commit
  && object_id_equal mapping.git_object commit
  &&
  match mapping.subject with
  | Imported_transition { transition = identity; _ } ->
      Id.Imported_transition_id.equal identity transition
  | Imported_snapshot _ | Imported_tag _ | Imported_revision _
  | Exported_release _ | Exported_revision _ ->
      false

let checkpoint_snapshot store checkpoint =
  Scratch.Checkpoint.load store checkpoint
  |> Result.map (fun checkpoint -> Scratch.Checkpoint.snapshot checkpoint)
  |> Result.map_error (fun error ->
      Adoption_error (Scratch.error_to_string error))

let snapshot_is_empty store snapshot =
  let* snapshot =
    Snapshot.Snapshot.load store snapshot
    |> Result.map_error (fun error ->
        Adoption_error (Snapshot.error_to_string error))
  in
  Snapshot.Tree.load store (Snapshot.Snapshot.root snapshot)
  |> Result.map (fun tree -> Snapshot.Tree.entries tree = [])
  |> Result.map_error (fun error ->
      Adoption_error (Snapshot.error_to_string error))

let adoption_revision store capsule revision =
  let* revisions =
    Capsule_store.Durable.history store capsule
    |> Result.map_error (fun error ->
        Adoption_error (Capsule_store.error_to_string error))
  in
  match
    List.find_opt
      (fun candidate ->
        Id.Capsule_revision_id.equal
          (Capsule_store.revision_id candidate)
          revision)
      revisions
  with
  | Some revision -> Ok revision
  | None -> Error (Adoption_error "adoption capsule revision is absent")

let validate_adoption store adoption =
  let* archive = load_archive store adoption.adoption_archive in
  if archive.archive_format <> adoption.adoption_format then
    Error
      (Adoption_error "adoption archive object format disagrees with receipt")
  else
    let* transition =
      load_imported_transition store adoption.adoption_transition
      |> Result.map_error (fun error -> Adoption_error (error_to_string error))
    in
    if
      not
        (object_id_equal transition.transition_commit adoption.adoption_commit)
    then
      Error (Adoption_error "adoption transition commit disagrees with receipt")
    else
      let* mapping =
        load_mapping store adoption.adoption_mapping
        |> Result.map_error (fun error ->
            Adoption_error (error_to_string error))
      in
      if
        not
          (mapping_matches_transition mapping adoption.adoption_transition
             adoption.adoption_commit)
      then
        Error (Adoption_error "adoption mapping does not name its transition")
      else
        let* source_snapshot =
          checkpoint_snapshot store adoption.adoption_source
        in
        let* target_snapshot =
          checkpoint_snapshot store adoption.adoption_target
        in
        if
          not
            (Snapshot.Snapshot.equal_id target_snapshot
               transition.transition_snapshot)
        then
          Error
            (Adoption_error "adoption target checkpoint disagrees with commit")
        else
          let* () =
            match
              ( adoption.adoption_parent,
                adoption.adoption_parent_transition,
                adoption.adoption_parent_mapping )
            with
            | None, None, None ->
                if transition.transition_parents <> [] then
                  Error
                    (Adoption_error
                       "non-root adoption must name one direct Git parent")
                else
                  let* empty = snapshot_is_empty store source_snapshot in
                  if empty then Ok ()
                  else
                    Error
                      (Adoption_error
                         "root adoption source checkpoint must be empty")
            | Some parent, Some parent_transition, Some parent_mapping ->
                if
                  not
                    (List.exists (object_id_equal parent)
                       transition.transition_parents)
                then
                  Error
                    (Adoption_error
                       "adoption parent is not a direct parent of the commit")
                else
                  let* imported_parent =
                    load_imported_transition store parent_transition
                    |> Result.map_error (fun error ->
                        Adoption_error (error_to_string error))
                  in
                  if
                    not
                      (object_id_equal imported_parent.transition_commit parent)
                  then
                    Error
                      (Adoption_error
                         "adoption parent transition disagrees with parent")
                  else if
                    not
                      (Snapshot.Snapshot.equal_id source_snapshot
                         imported_parent.transition_snapshot)
                  then
                    Error
                      (Adoption_error
                         "adoption source checkpoint disagrees with parent")
                  else
                    let* mapping =
                      load_mapping store parent_mapping
                      |> Result.map_error (fun error ->
                          Adoption_error (error_to_string error))
                    in
                    if
                      mapping_matches_transition mapping parent_transition
                        parent
                    then Ok ()
                    else
                      Error
                        (Adoption_error
                           "adoption parent mapping does not name its \
                            transition")
            | None, Some _, Some _
            | Some _, None, _
            | Some _, _, None
            | None, Some _, None
            | None, None, Some _ ->
                Error
                  (Adoption_error
                     "adoption parent, transition, and mapping must appear \
                      together")
          in
          let* revision =
            adoption_revision store adoption.adoption_capsule
              adoption.adoption_revision
          in
          if
            List.exists
              (fun boundary ->
                Scratch.Checkpoint_id.equal boundary.Capsule_store.source
                  adoption.adoption_source
                && Scratch.Checkpoint_id.equal boundary.Capsule_store.target
                     adoption.adoption_target)
              (Capsule_store.revision_boundaries revision)
          then Ok adoption
          else
            Error
              (Adoption_error
                 "adoption capsule revision does not retain its checkpoint \
                  boundary")

let load_adoption_from_binding store adoption_identity binding =
  let* bound_identity, physical = decode_adoption_binding binding in
  if not (Id.Git_adoption_id.equal bound_identity adoption_identity) then
    Error
      (Adoption_error "Git adoption binding logical ID disagrees with its path")
  else
    let* envelope =
      Store.get store physical
      |> Result.map_error (fun error -> Store_error error)
    in
    if Envelope.object_type envelope <> Envelope.Git_adoption then
      Error
        (Adoption_error
           (Printf.sprintf "expected Git adoption object type 30, got %d"
              (Envelope.object_type_code (Envelope.object_type envelope))))
    else
      let* adoption = decode_adoption_payload (Envelope.payload envelope) in
      if
        not
          (Id.Git_adoption_id.equal adoption.adoption_identity adoption_identity)
      then
        Error
          (Adoption_error "Git adoption object ID disagrees with its binding")
      else validate_adoption store adoption

let load_adoption store adoption_identity =
  let* binding =
    Store.Ref_file.read store
      ~components:(adoption_ref_components adoption_identity)
    |> Result.map_error (fun error -> Store_error error)
  in
  match binding with
  | None -> Error (Adoption_error "Git adoption binding is absent")
  | Some binding -> load_adoption_from_binding store adoption_identity binding

let record_archive_adoption store ~archive ~commit ~parent ~transition ~mapping
    ~parent_transition ~parent_mapping ~capsule ~revision ~source ~target =
  let* preserved = load_archive store archive in
  let* adoption =
    make_adoption ~archive ~format:preserved.archive_format ~commit ~parent
      ~transition:(imported_transition_id transition)
      ~mapping:(mapping_id mapping)
      ~parent_transition:(Option.map imported_transition_id parent_transition)
      ~parent_mapping:(Option.map mapping_id parent_mapping)
      ~capsule ~revision ~source ~target
  in
  let* () = validate_adoption store adoption |> Result.map (fun _ -> ()) in
  let* envelope = adoption_envelope adoption in
  let* physical =
    Store.put store envelope
    |> Result.map_error (fun error -> Store_error error)
  in
  let* binding = encode_adoption_binding adoption.adoption_identity physical in
  Store.with_lock store ~name:"git-adoptions"
    ~on_error:(fun error -> Store_error error)
    (fun () ->
      let components = adoption_ref_components adoption.adoption_identity in
      let* current =
        Store.Ref_file.read store ~components
        |> Result.map_error (fun error -> Store_error error)
      in
      match current with
      | None ->
          Store.Ref_file.compare_and_swap store ~components ~expected:None
            ~replacement:binding
          |> Result.map_error (fun error -> Store_error error)
          |> Result.map (fun () -> adoption)
      | Some current ->
          load_adoption_from_binding store adoption.adoption_identity current)

let adoption_id adoption = adoption.adoption_identity
let adoption_archive adoption = adoption.adoption_archive
let adoption_commit adoption = adoption.adoption_commit
let adoption_parent adoption = adoption.adoption_parent
let adoption_mapping adoption = adoption.adoption_mapping
let adoption_capsule adoption = adoption.adoption_capsule
let adoption_revision adoption = adoption.adoption_revision
let adoption_source adoption = adoption.adoption_source
let adoption_target adoption = adoption.adoption_target

module Legacy_format = struct
  let create_imported_transition_v1 = create_imported_transition
  let transition_envelope = transition_envelope
  let encode_transition_binding = encode_transition_binding

  let create_mapping_v2 ~direction ~git_object ~git_kind ~subject =
    create_mapping_with_version 2 ~direction ~git_object ~git_kind ~subject

  let mapping_envelope = mapping_envelope

  let encode_mapping_binding logical physical =
    encode_mapping_binding 2 logical physical
end

(* Git lineage deliberately models foreign topology in its own graph.  It is
   not an alternate encoding of scratch, capsules, or releases. *)
let lineage_node_domain = "yeokcham:git-lineage-node:v1\000"
let lineage_domain = "yeokcham:git-lineage:v1\000"
let lineage_node_binding_domain = "yeokcham:git-lineage-node-binding:v1\000"
let lineage_binding_domain = "yeokcham:git-lineage-binding:v1\000"

let lineage_error_of_encoding error =
  Lineage_error (Encoding.construction_error_to_string error)

let lineage_array values =
  Encoding.array values |> Result.map_error lineage_error_of_encoding

let lineage_bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Lineage_error (name ^ " must be bytes"))

let lineage_integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Lineage_error (name ^ " must be an integer"))

let lineage_fields name length = function
  | Encoding.Array values when List.length values = length -> Ok values
  | Encoding.Array _ ->
      Error
        (Lineage_error (Printf.sprintf "%s must contain %d values" name length))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Lineage_error (name ^ " must be an array"))

let lineage_raw_id name parser value =
  let* raw = lineage_bytes name value in
  if String.length raw <> 32 then
    Error
      (Lineage_error
         (Printf.sprintf "%s must be exactly 32 bytes, got %d" name
            (String.length raw)))
  else
    parser raw
    |> Result.map_error (fun error ->
        Lineage_error (Id.parse_error_to_string error))

let lineage_stored_id name value =
  let* raw = lineage_bytes name value in
  match Store.Stored_object_id.of_raw_bytes raw with
  | Some identity -> Ok identity
  | None ->
      Error
        (Lineage_error
           (Printf.sprintf "%s must be exactly 32 bytes, got %d" name
              (String.length raw)))

let lineage_format_code = function Sha1 -> 1L | Sha256 -> 2L

let lineage_format_of_code = function
  | 1L -> Ok Sha1
  | 2L -> Ok Sha256
  | value ->
      Error
        (Lineage_error
           (Printf.sprintf "unknown Git lineage object format: %Ld" value))

let lineage_object_value identity =
  lineage_array
    [
      Encoding.integer (lineage_format_code identity.format);
      Encoding.bytes identity.raw;
    ]

let decode_lineage_object name format value =
  let* fields = lineage_fields name 2 value in
  match fields with
  | [ encoded_format; raw ] ->
      let* encoded_format = lineage_integer (name ^ " format") encoded_format in
      let* encoded_format = lineage_format_of_code encoded_format in
      if encoded_format <> format then
        Error (Lineage_error (name ^ " object format disagrees with record"))
      else
        let* raw = lineage_bytes (name ^ " raw ID") raw in
        object_id_of_raw format raw
        |> Result.map_error (fun error -> Lineage_error (error_to_string error))
  | _ -> assert false

let distinct_lineage_ids name identities =
  let rec loop seen = function
    | [] -> Ok ()
    | identity :: rest ->
        let raw = Id.Git_lineage_node_id.to_bytes identity in
        if List.exists (String.equal raw) seen then
          Error (Lineage_error (name ^ " contains a duplicate node ID"))
        else loop (raw :: seen) rest
  in
  loop [] identities

let lineage_node_identity_payload archive format commit =
  let* commit = lineage_object_value commit in
  lineage_array
    [
      Encoding.integer 1L;
      Encoding.bytes (Id.Git_archive_id.to_bytes archive);
      Encoding.integer (lineage_format_code format);
      commit;
    ]

let derive_lineage_node_id archive format commit =
  let* identity = lineage_node_identity_payload archive format commit in
  let raw =
    Hash.feed_string Hash.empty lineage_node_domain |> fun context ->
    Hash.feed_string context (Encoding.encode identity)
    |> Hash.get |> Hash.to_raw_string
  in
  Id.Git_lineage_node_id.of_bytes raw
  |> Result.map_error (fun error ->
      Lineage_error (Id.parse_error_to_string error))

let make_lineage_node ~archive ~format ~commit ~transition ~mapping ~snapshot
    ~parents =
  if commit.format <> format then
    Error (Lineage_error "Git lineage commit has a different object format")
  else
    let* () = distinct_lineage_ids "Git lineage parents" parents in
    let* lineage_node_identity = derive_lineage_node_id archive format commit in
    Ok
      {
        lineage_node_identity;
        lineage_node_archive = archive;
        lineage_node_format = format;
        lineage_node_commit = commit;
        lineage_node_transition = transition;
        lineage_node_mapping = mapping;
        lineage_node_snapshot = snapshot;
        lineage_node_parents = parents;
      }

let lineage_node_payload node =
  let* commit = lineage_object_value node.lineage_node_commit in
  let* parents =
    List.map
      (fun parent ->
        Encoding.bytes (Id.Git_lineage_node_id.to_bytes parent))
      node.lineage_node_parents
    |> lineage_array
  in
  lineage_array
    [
      Encoding.integer 1L;
      Encoding.bytes
        (Id.Git_lineage_node_id.to_bytes node.lineage_node_identity);
      Encoding.bytes (Id.Git_archive_id.to_bytes node.lineage_node_archive);
      Encoding.integer (lineage_format_code node.lineage_node_format);
      commit;
      Encoding.bytes
        (Id.Imported_transition_id.to_bytes node.lineage_node_transition);
      Encoding.bytes (Id.Git_mapping_id.to_bytes node.lineage_node_mapping);
      Encoding.bytes
        (Snapshot.Snapshot.stored_object_id node.lineage_node_snapshot
        |> Store.Stored_object_id.to_raw_bytes);
      parents;
    ]

let lineage_node_envelope node =
  let* payload = lineage_node_payload node in
  Envelope.create ~object_type:Envelope.Git_lineage_node
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error ->
      Lineage_error (Envelope.creation_error_to_string error))

let decode_lineage_node_payload value =
  let* fields = lineage_fields "Git lineage node" 9 value in
  match fields with
  | [
   version;
   supplied_id;
   archive;
   format;
   commit;
   transition;
   mapping;
   snapshot;
   parents;
  ] ->
      let* version = lineage_integer "Git lineage node version" version in
      if not (Int64.equal version 1L) then
        Error
          (Lineage_error
             (Printf.sprintf "unsupported Git lineage node version: %Ld" version))
      else
        let* supplied_id =
          lineage_raw_id "Git lineage node ID" Id.Git_lineage_node_id.of_bytes
            supplied_id
        in
        let* archive =
          lineage_raw_id "Git lineage node archive" Id.Git_archive_id.of_bytes
            archive
        in
        let* format = lineage_integer "Git lineage node format" format in
        let* format = lineage_format_of_code format in
        let* commit = decode_lineage_object "Git lineage node commit" format commit in
        let* transition =
          lineage_raw_id "Git lineage node transition"
            Id.Imported_transition_id.of_bytes transition
        in
        let* mapping =
          lineage_raw_id "Git lineage node mapping" Id.Git_mapping_id.of_bytes
            mapping
        in
        let* snapshot = lineage_stored_id "Git lineage node snapshot" snapshot in
        let snapshot = Snapshot.Snapshot.of_stored_object_id snapshot in
        let* parents =
          match parents with
          | Encoding.Array values ->
              List.fold_left
                (fun result value ->
                  let* reversed = result in
                  let* parent =
                    lineage_raw_id "Git lineage node parent"
                      Id.Git_lineage_node_id.of_bytes value
                  in
                  Ok (parent :: reversed))
                (Ok []) values
              |> Result.map List.rev
          | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
          | Encoding.Bool _ | Encoding.Null ->
              Error (Lineage_error "Git lineage node parents must be an array")
        in
        let* node =
          make_lineage_node ~archive ~format ~commit ~transition ~mapping
            ~snapshot ~parents
        in
        if
          not
            (Id.Git_lineage_node_id.equal supplied_id
               node.lineage_node_identity)
        then Error (Lineage_error "Git lineage node logical ID does not match its preimage")
        else
          let* canonical = lineage_node_payload node in
          if String.equal (Encoding.encode canonical) (Encoding.encode value) then
            Ok node
          else Error (Lineage_error "Git lineage node payload is noncanonical")
  | _ -> assert false

let lineage_node_binding_body identity physical =
  lineage_array
    [
      Encoding.integer 1L;
      Encoding.bytes (Id.Git_lineage_node_id.to_bytes identity);
      Encoding.bytes (Store.Stored_object_id.to_raw_bytes physical);
    ]

let lineage_node_binding_checksum body =
  Hash.feed_string Hash.empty lineage_node_binding_domain |> fun context ->
  Hash.feed_string context (Encoding.encode body)
  |> Hash.get |> Hash.to_raw_string

let encode_lineage_node_binding identity physical =
  let* body = lineage_node_binding_body identity physical in
  lineage_array
    [
      Encoding.integer 1L;
      Encoding.bytes (Id.Git_lineage_node_id.to_bytes identity);
      Encoding.bytes (Store.Stored_object_id.to_raw_bytes physical);
      Encoding.bytes (lineage_node_binding_checksum body);
    ]
  |> Result.map Encoding.encode

let decode_lineage_node_binding bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error ->
        Lineage_error (Encoding.decode_error_to_string error))
  in
  let* fields = lineage_fields "Git lineage node binding" 4 value in
  match fields with
  | [ version; identity; physical; checksum ] ->
      let* version = lineage_integer "Git lineage node binding version" version in
      if not (Int64.equal version 1L) then
        Error (Lineage_error "unsupported Git lineage node binding version")
      else
        let* identity =
          lineage_raw_id "Git lineage node binding ID"
            Id.Git_lineage_node_id.of_bytes identity
        in
        let* physical =
          lineage_stored_id "Git lineage node binding object ID" physical
        in
        let* checksum = lineage_bytes "Git lineage node binding checksum" checksum in
        if String.length checksum <> 32 then
          Error (Lineage_error "Git lineage node binding checksum must be 32 bytes")
        else
          let* body = lineage_node_binding_body identity physical in
          if not (String.equal checksum (lineage_node_binding_checksum body)) then
            Error (Lineage_error "Git lineage node binding checksum mismatch")
          else
            let* canonical = encode_lineage_node_binding identity physical in
            if String.equal canonical bytes then Ok (identity, physical)
            else Error (Lineage_error "Git lineage node binding is noncanonical")
  | _ -> assert false

let lineage_node_ref_components identity =
  [ "git-lineage-nodes"; Id.Git_lineage_node_id.to_hex identity ]

let rec validate_lineage_node store visited node =
  let node_raw = Id.Git_lineage_node_id.to_bytes node.lineage_node_identity in
  if List.exists (String.equal node_raw) visited then
    Error (Lineage_error "Git lineage graph contains a cycle")
  else
    let visited = node_raw :: visited in
    let* archive = load_archive store node.lineage_node_archive in
    if archive.archive_format <> node.lineage_node_format then
      Error (Lineage_error "Git lineage node format disagrees with archive")
    else
      let* transition =
        load_imported_transition store node.lineage_node_transition
        |> Result.map_error (fun error -> Lineage_error (error_to_string error))
      in
      if not (object_id_equal transition.transition_commit node.lineage_node_commit)
      then Error (Lineage_error "Git lineage transition commit disagrees with node")
      else if
        not
          (Snapshot.Snapshot.equal_id transition.transition_snapshot
             node.lineage_node_snapshot)
      then Error (Lineage_error "Git lineage transition snapshot disagrees with node")
      else
        let* mapping =
          load_mapping store node.lineage_node_mapping
          |> Result.map_error (fun error -> Lineage_error (error_to_string error))
        in
        if
          not
            (mapping_matches_transition mapping node.lineage_node_transition
               node.lineage_node_commit)
        then Error (Lineage_error "Git lineage mapping does not name its transition")
        else
          let* parents =
            List.fold_left
              (fun result identity ->
                let* reversed = result in
                let* parent = load_lineage_node_with_visited store visited identity in
                Ok (parent :: reversed))
              (Ok []) node.lineage_node_parents
            |> Result.map List.rev
          in
          let parent_commits = List.map (fun parent -> parent.lineage_node_commit) parents in
          let same_parent_order =
            List.length parent_commits = List.length transition.transition_parents
            && List.for_all2 object_id_equal parent_commits transition.transition_parents
          in
          if same_parent_order then Ok node
          else Error (Lineage_error "Git lineage parent order disagrees with transition")

and load_lineage_node_with_visited store visited identity =
  let* binding =
    Store.Ref_file.read store ~components:(lineage_node_ref_components identity)
    |> Result.map_error (fun error -> Store_error error)
  in
  match binding with
  | None -> Error (Lineage_error "Git lineage node binding is absent")
  | Some binding ->
      let* bound_identity, physical = decode_lineage_node_binding binding in
      if not (Id.Git_lineage_node_id.equal bound_identity identity) then
        Error (Lineage_error "Git lineage node binding ID disagrees with its path")
      else
        let* envelope =
          Store.get store physical |> Result.map_error (fun error -> Store_error error)
        in
        if Envelope.object_type envelope <> Envelope.Git_lineage_node then
          Error (Lineage_error "Git lineage node binding names the wrong object type")
        else
          let* node = decode_lineage_node_payload (Envelope.payload envelope) in
          if not (Id.Git_lineage_node_id.equal node.lineage_node_identity identity)
          then Error (Lineage_error "Git lineage node object ID disagrees with binding")
          else validate_lineage_node store visited node

let load_lineage_node store identity =
  load_lineage_node_with_visited store [] identity

let publish_lineage_node store node =
  let* _ = validate_lineage_node store [] node in
  let* envelope = lineage_node_envelope node in
  let* physical = Store.put store envelope |> Result.map_error (fun error -> Store_error error) in
  let* binding = encode_lineage_node_binding node.lineage_node_identity physical in
  Store.with_lock store ~name:"git-lineage-nodes"
    ~on_error:(fun error -> Store_error error)
    (fun () ->
      let components = lineage_node_ref_components node.lineage_node_identity in
      let* current =
        Store.Ref_file.read store ~components
        |> Result.map_error (fun error -> Store_error error)
      in
      match current with
      | None ->
          Store.Ref_file.compare_and_swap store ~components ~expected:None
            ~replacement:binding
          |> Result.map_error (fun error -> Store_error error)
          |> Result.map (fun () -> node)
      | Some _ -> load_lineage_node store node.lineage_node_identity)

let valid_lineage_ref_name name =
  not (String.is_empty name)
  && not (String.contains name '\000')
  && not (String.contains name '\n')
  && not (String.contains name '\r')

let lineage_ref_value format reference =
  if not (valid_lineage_ref_name reference.lineage_ref_name) then
    Error (Lineage_error "Git lineage ref name is malformed")
  else if reference.lineage_ref_object.format <> format then
    Error (Lineage_error "Git lineage ref has a different object format")
  else
    let* object_id = lineage_object_value reference.lineage_ref_object in
    let head =
      match reference.lineage_ref_head with
      | None -> Encoding.null
      | Some identity ->
          Encoding.bytes (Id.Git_lineage_node_id.to_bytes identity)
    in
    lineage_array [ Encoding.bytes reference.lineage_ref_name; object_id; head ]

let lineage_ref_values format references =
  let rec loop previous reversed = function
    | [] -> lineage_array (List.rev reversed)
    | reference :: rest ->
        let* () =
          match previous with
          | None -> Ok ()
          | Some previous
            when String.compare previous reference.lineage_ref_name < 0 ->
              Ok ()
          | Some _ ->
              Error
                (Lineage_error
                   "Git lineage refs must be strictly bytewise ordered")
        in
        let* value = lineage_ref_value format reference in
        loop (Some reference.lineage_ref_name) (value :: reversed) rest
  in
  loop None [] references

let lineage_identity_payload archive =
  lineage_array
    [ Encoding.integer 1L; Encoding.bytes (Id.Git_archive_id.to_bytes archive) ]

let derive_lineage_id archive =
  let* identity = lineage_identity_payload archive in
  let raw =
    Hash.feed_string Hash.empty lineage_domain |> fun context ->
    Hash.feed_string context (Encoding.encode identity)
    |> Hash.get |> Hash.to_raw_string
  in
  Id.Git_lineage_id.of_bytes raw
  |> Result.map_error (fun error ->
      Lineage_error (Id.parse_error_to_string error))

let make_lineage ~archive ~format ~refs =
  let* () = lineage_ref_values format refs |> Result.map (fun _ -> ()) in
  let* lineage_identity = derive_lineage_id archive in
  Ok { lineage_identity; lineage_archive = archive; lineage_format = format; lineage_refs = refs }

let lineage_payload lineage =
  let* refs = lineage_ref_values lineage.lineage_format lineage.lineage_refs in
  lineage_array
    [
      Encoding.integer 1L;
      Encoding.bytes (Id.Git_lineage_id.to_bytes lineage.lineage_identity);
      Encoding.bytes (Id.Git_archive_id.to_bytes lineage.lineage_archive);
      Encoding.integer (lineage_format_code lineage.lineage_format);
      refs;
    ]

let lineage_envelope lineage =
  let* payload = lineage_payload lineage in
  Envelope.create ~object_type:Envelope.Git_lineage
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
  |> Result.map_error (fun error ->
      Lineage_error (Envelope.creation_error_to_string error))

let decode_lineage_ref format value =
  let* fields = lineage_fields "Git lineage ref" 3 value in
  match fields with
  | [ name; object_value; head ] ->
      let* lineage_ref_name = lineage_bytes "Git lineage ref name" name in
      let* lineage_ref_object =
        decode_lineage_object "Git lineage ref object" format object_value
      in
      let* lineage_ref_head =
        match head with
        | Encoding.Null -> Ok None
        | Encoding.Bytes _ ->
            lineage_raw_id "Git lineage ref head" Id.Git_lineage_node_id.of_bytes
              head
            |> Result.map Option.some
        | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
        | Encoding.Bool _ ->
            Error (Lineage_error "Git lineage ref head must be null or a node ID")
      in
      Ok { lineage_ref_name; lineage_ref_object; lineage_ref_head }
  | _ -> assert false

let decode_lineage_refs format = function
  | Encoding.Array values ->
      List.fold_left
        (fun result value ->
          let* reversed = result in
          let* reference = decode_lineage_ref format value in
          Ok (reference :: reversed))
        (Ok []) values
      |> Result.map List.rev
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Lineage_error "Git lineage refs must be an array")

let decode_lineage_payload value =
  let* fields = lineage_fields "Git lineage" 5 value in
  match fields with
  | [ version; supplied_id; archive; format; refs ] ->
      let* version = lineage_integer "Git lineage version" version in
      if not (Int64.equal version 1L) then
        Error
          (Lineage_error
             (Printf.sprintf "unsupported Git lineage version: %Ld" version))
      else
        let* supplied_id =
          lineage_raw_id "Git lineage ID" Id.Git_lineage_id.of_bytes supplied_id
        in
        let* archive =
          lineage_raw_id "Git lineage archive" Id.Git_archive_id.of_bytes archive
        in
        let* format = lineage_integer "Git lineage format" format in
        let* format = lineage_format_of_code format in
        let* refs = decode_lineage_refs format refs in
        let* lineage = make_lineage ~archive ~format ~refs in
        if not (Id.Git_lineage_id.equal supplied_id lineage.lineage_identity) then
          Error (Lineage_error "Git lineage logical ID does not match its preimage")
        else
          let* canonical = lineage_payload lineage in
          if String.equal (Encoding.encode canonical) (Encoding.encode value) then
            Ok lineage
          else Error (Lineage_error "Git lineage payload is noncanonical")
  | _ -> assert false

let lineage_binding_body identity physical =
  lineage_array
    [
      Encoding.integer 1L;
      Encoding.bytes (Id.Git_lineage_id.to_bytes identity);
      Encoding.bytes (Store.Stored_object_id.to_raw_bytes physical);
    ]

let lineage_binding_checksum body =
  Hash.feed_string Hash.empty lineage_binding_domain |> fun context ->
  Hash.feed_string context (Encoding.encode body)
  |> Hash.get |> Hash.to_raw_string

let encode_lineage_binding identity physical =
  let* body = lineage_binding_body identity physical in
  lineage_array
    [
      Encoding.integer 1L;
      Encoding.bytes (Id.Git_lineage_id.to_bytes identity);
      Encoding.bytes (Store.Stored_object_id.to_raw_bytes physical);
      Encoding.bytes (lineage_binding_checksum body);
    ]
  |> Result.map Encoding.encode

let decode_lineage_binding bytes =
  let* value =
    Encoding.decode bytes
    |> Result.map_error (fun error ->
        Lineage_error (Encoding.decode_error_to_string error))
  in
  let* fields = lineage_fields "Git lineage binding" 4 value in
  match fields with
  | [ version; identity; physical; checksum ] ->
      let* version = lineage_integer "Git lineage binding version" version in
      if not (Int64.equal version 1L) then
        Error (Lineage_error "unsupported Git lineage binding version")
      else
        let* identity =
          lineage_raw_id "Git lineage binding ID" Id.Git_lineage_id.of_bytes
            identity
        in
        let* physical = lineage_stored_id "Git lineage binding object ID" physical in
        let* checksum = lineage_bytes "Git lineage binding checksum" checksum in
        if String.length checksum <> 32 then
          Error (Lineage_error "Git lineage binding checksum must be 32 bytes")
        else
          let* body = lineage_binding_body identity physical in
          if not (String.equal checksum (lineage_binding_checksum body)) then
            Error (Lineage_error "Git lineage binding checksum mismatch")
          else
            let* canonical = encode_lineage_binding identity physical in
            if String.equal canonical bytes then Ok (identity, physical)
            else Error (Lineage_error "Git lineage binding is noncanonical")
  | _ -> assert false

let lineage_ref_components identity =
  [ "git-lineages"; Id.Git_lineage_id.to_hex identity ]

let same_archive_inventory lineage archive =
  List.length lineage.lineage_refs = List.length archive.archive_ref_inventory
  && List.for_all2
       (fun left right ->
         String.equal left.lineage_ref_name right.archive_ref_name
         && object_id_equal left.lineage_ref_object right.archive_ref_object)
       lineage.lineage_refs archive.archive_ref_inventory

let validate_lineage store lineage =
  let* archive = load_archive store lineage.lineage_archive in
  if archive.archive_format <> lineage.lineage_format then
    Error (Lineage_error "Git lineage format disagrees with archive")
  else if not (same_archive_inventory lineage archive) then
    Error (Lineage_error "Git lineage refs disagree with archive inventory")
  else
    List.fold_left
      (fun result reference ->
        let* () = result in
        match reference.lineage_ref_head with
        | None -> Ok ()
        | Some head ->
            let* node = load_lineage_node store head in
            if Id.Git_archive_id.equal node.lineage_node_archive lineage.lineage_archive
            then Ok ()
            else Error (Lineage_error "Git lineage ref head belongs to another archive"))
      (Ok ()) lineage.lineage_refs
    |> Result.map (fun () -> lineage)

let load_lineage_from_binding store identity binding =
  let* bound_identity, physical = decode_lineage_binding binding in
  if not (Id.Git_lineage_id.equal bound_identity identity) then
    Error (Lineage_error "Git lineage binding ID disagrees with its path")
  else
    let* envelope = Store.get store physical |> Result.map_error (fun error -> Store_error error) in
    if Envelope.object_type envelope <> Envelope.Git_lineage then
      Error (Lineage_error "Git lineage binding names the wrong object type")
    else
      let* lineage = decode_lineage_payload (Envelope.payload envelope) in
      if not (Id.Git_lineage_id.equal lineage.lineage_identity identity) then
        Error (Lineage_error "Git lineage object ID disagrees with binding")
      else validate_lineage store lineage

let load_lineage store identity =
  let* binding =
    Store.Ref_file.read store ~components:(lineage_ref_components identity)
    |> Result.map_error (fun error -> Store_error error)
  in
  match binding with
  | None -> Error (Lineage_error "Git lineage binding is absent")
  | Some binding -> load_lineage_from_binding store identity binding

let publish_lineage store lineage =
  let* () = validate_lineage store lineage |> Result.map (fun _ -> ()) in
  let* envelope = lineage_envelope lineage in
  let* physical = Store.put store envelope |> Result.map_error (fun error -> Store_error error) in
  let* binding = encode_lineage_binding lineage.lineage_identity physical in
  Store.with_lock store ~name:"git-lineages"
    ~on_error:(fun error -> Store_error error)
    (fun () ->
      let components = lineage_ref_components lineage.lineage_identity in
      let* current =
        Store.Ref_file.read store ~components
        |> Result.map_error (fun error -> Store_error error)
      in
      match current with
      | None ->
          Store.Ref_file.compare_and_swap store ~components ~expected:None
            ~replacement:binding
          |> Result.map_error (fun error -> Store_error error)
          |> Result.map (fun () -> lineage)
      | Some current ->
          load_lineage_from_binding store lineage.lineage_identity current)

type archived_lineage_ref = {
  archived_lineage_reference : archive_ref;
  archived_lineage_head : object_id option;
}

type discovered_lineage_commit = {
  discovered_lineage_commit : object_id;
  discovered_lineage_parents : object_id list;
}

let parse_archived_lineage_refs format archive output =
  let lines =
    String.split_on_char '\n' output
    |> List.filter (fun line -> not (String.is_empty line))
  in
  if List.length lines > 100_000 then
    Error (Lineage_error "Git lineage ref inventory exceeds 100000 refs")
  else
    let rec parse reversed = function
      | [] -> Ok (List.rev reversed)
      | line :: rest -> (
          match String.split_on_char '\000' line with
          | [ name; object_hex; object_kind; peeled_hex; peeled_kind ] ->
              let* object_id =
                object_id_of_hex format object_hex
                |> Result.map_error (fun error ->
                    Lineage_error (error_to_string error))
              in
              let* archived_lineage_head =
                if String.equal object_kind "commit" then Ok (Some object_id)
                else if String.equal peeled_kind "commit" then
                  object_id_of_hex format peeled_hex
                  |> Result.map Option.some
                  |> Result.map_error (fun error ->
                      Lineage_error (error_to_string error))
                else Ok None
              in
              parse
                ({
                   archived_lineage_reference =
                     { archive_ref_name = name; archive_ref_object = object_id };
                   archived_lineage_head;
                 }
                :: reversed)
                rest
          | _ ->
              Error
                (Lineage_error
                   "Git lineage ref inventory has an invalid field count"))
    in
    let* references = parse [] lines in
    let same_inventory =
      List.length references = List.length archive.archive_ref_inventory
      && List.for_all2
           (fun left right ->
             String.equal left.archived_lineage_reference.archive_ref_name
               right.archive_ref_name
             && object_id_equal
                  left.archived_lineage_reference.archive_ref_object
                  right.archive_ref_object)
           references archive.archive_ref_inventory
    in
    if same_inventory then Ok references
    else Error (Lineage_error "reconstructed archive refs changed during lineage materialization")

let archive_lineage_refs ?runner configuration executable repository archive =
  let* output =
    run_bytes ?runner configuration executable repository
      ~operation:"lineage-ref-inventory"
      ~max_stdout_bytes:configuration.max_total_tree_bytes
      [
        "--no-replace-objects";
        "for-each-ref";
        "--sort=refname";
        "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)";
      ]
  in
  parse_archived_lineage_refs archive.archive_format archive output

let object_ids_distinct identities =
  let rec loop seen = function
    | [] -> Ok ()
    | identity :: rest ->
        if List.exists (object_id_equal identity) seen then
          Error (Lineage_error "Git commit parent list contains a duplicate")
        else loop (identity :: seen) rest
  in
  loop [] identities

let parse_lineage_commit_graph format ~max_commits ~max_parents output =
  let lines =
    String.split_on_char '\n' output
    |> List.filter (fun line -> not (String.is_empty line))
  in
  let rec parse table count = function
    | [] -> Ok table
    | _ :: _ when count = max_commits ->
        Error
          (Import_limit_exceeded
             {
               resource = "reachable Git commits for lineage";
               limit = max_commits;
               actual = count + 1;
             })
    | line :: rest ->
        if String.contains line '\000' || String.contains line '\r' then
          Error (Lineage_error "Git lineage commit graph contains forbidden bytes")
        else
          let fields = String.split_on_char ' ' line in
          match fields with
          | [] | [ "" ] ->
              Error (Lineage_error "Git lineage commit graph has an empty line")
          | commit_hex :: parent_hexes ->
              if List.exists String.is_empty parent_hexes then
                Error (Lineage_error "Git lineage commit graph has repeated spaces")
              else if List.length parent_hexes > max_parents then
                Error
                  (Import_limit_exceeded
                     {
                       resource = "commit parents";
                       limit = max_parents;
                       actual = List.length parent_hexes;
                     })
              else
                let* discovered_lineage_commit =
                  object_id_of_hex format commit_hex
                  |> Result.map_error (fun error ->
                      Lineage_error (error_to_string error))
                in
                let raw = discovered_lineage_commit.raw in
                if Hashtbl.mem table raw then
                  Error (Lineage_error "Git lineage commit graph repeats a commit")
                else
                  let* discovered_lineage_parents =
                    List.fold_left
                      (fun result hex ->
                        let* reversed = result in
                        let* parent =
                          object_id_of_hex format hex
                          |> Result.map_error (fun error ->
                              Lineage_error (error_to_string error))
                        in
                        if object_id_equal parent discovered_lineage_commit then
                          Error (Lineage_error "Git lineage commit is its own parent")
                        else Ok (parent :: reversed))
                      (Ok []) parent_hexes
                    |> Result.map List.rev
                  in
                  let* () = object_ids_distinct discovered_lineage_parents in
                  Hashtbl.add table raw
                    { discovered_lineage_commit; discovered_lineage_parents };
                  parse table (count + 1) rest
  in
  parse (Hashtbl.create (max 16 (List.length lines))) 0 lines

let discover_lineage_commits ?runner configuration executable repository format
    references =
  let heads =
    references
    |> List.filter_map (fun reference -> reference.archived_lineage_head)
    |> List.sort_uniq object_id_compare
  in
  match heads with
  | [] -> Ok (Hashtbl.create 0)
  | _ ->
      let* output =
        run_bytes ?runner configuration executable repository
          ~operation:"lineage-rev-list"
          ~max_stdout_bytes:configuration.max_total_tree_bytes
          ([ "--no-replace-objects"; "rev-list"; "--topo-order"; "--reverse"; "--parents" ]
          @ List.map object_id_to_hex heads)
      in
      let* graph =
        parse_lineage_commit_graph format
          ~max_commits:configuration.max_export_commits
          ~max_parents:configuration.max_commit_parents output
      in
      let* () =
        List.fold_left
          (fun result head ->
            let* () = result in
            if Hashtbl.mem graph head.raw then Ok ()
            else Error (Lineage_error "Git lineage graph omits a selected ref head"))
          (Ok ()) heads
      in
      let* () =
        Hashtbl.fold
          (fun _ discovered result ->
            let* () = result in
            List.fold_left
              (fun result parent ->
                let* () = result in
                if Hashtbl.mem graph parent.raw then Ok ()
                else Error (Lineage_error "Git lineage graph omits a parent"))
              (Ok ()) discovered.discovered_lineage_parents)
          graph (Ok ())
      in
      Ok graph

let materialize_archive_lineage ?runner configuration ~store ~archive =
  let* configuration = validate_configuration configuration in
  let* preserved = load_archive store archive in
  let* executable =
    match executable_path configuration.git with
    | Some executable -> Ok executable
    | None -> Error (Git_missing configuration.git)
  in
  with_temporary_archive_directory "lineage" (fun repository ->
      let* _ =
        exit_archive ?runner configuration ~store ~archive ~destination:repository
      in
      let* references =
        archive_lineage_refs ?runner configuration executable repository preserved
      in
      let* graph =
        discover_lineage_commits ?runner configuration executable repository
          preserved.archive_format references
      in
      let materialized = Hashtbl.create (max 16 (Hashtbl.length graph)) in
      let visiting = Hashtbl.create (max 16 (Hashtbl.length graph)) in
      let created = ref [] in
      let rec visit commit =
        match Hashtbl.find_opt materialized commit.raw with
        | Some node -> Ok node
        | None ->
            if Hashtbl.mem visiting commit.raw then
              Error (Lineage_error "Git lineage graph contains a cycle")
            else
              match Hashtbl.find_opt graph commit.raw with
              | None -> Error (Lineage_error "Git lineage commit is missing from graph")
              | Some discovered ->
                  Hashtbl.add visiting commit.raw ();
                  let result =
                    let* parents =
                      List.fold_left
                        (fun result parent ->
                          let* reversed = result in
                          let* node = visit parent in
                          Ok (node :: reversed))
                        (Ok []) discovered.discovered_lineage_parents
                      |> Result.map List.rev
                    in
                    let* imported =
                      import_commit ?runner configuration ~store ~repository
                        ~commit:discovered.discovered_lineage_commit
                    in
                    let transition = imported.imported_transition in
                    let imported_parents = transition.transition_parents in
                    let expected_parents = discovered.discovered_lineage_parents in
                    if
                      List.length imported_parents <> List.length expected_parents
                      || not (List.for_all2 object_id_equal imported_parents expected_parents)
                    then Error (Lineage_error "Git commit import parent order disagrees with rev-list")
                    else
                      let* node =
                        make_lineage_node ~archive
                          ~format:preserved.archive_format
                          ~commit:discovered.discovered_lineage_commit
                          ~transition:(imported_transition_id transition)
                          ~mapping:(mapping_id imported.commit_mapping)
                          ~snapshot:transition.transition_snapshot
                          ~parents:(List.map (fun parent -> parent.lineage_node_identity) parents)
                      in
                      let* node = publish_lineage_node store node in
                      Hashtbl.replace materialized commit.raw node;
                      created := node :: !created;
                      Ok node
                  in
                  Hashtbl.remove visiting commit.raw;
                  result
      in
      let* resolved_references =
        List.fold_left
          (fun result reference ->
            let* reversed = result in
            let* lineage_ref_head =
              match reference.archived_lineage_head with
              | None -> Ok None
              | Some head ->
                  visit head
                  |> Result.map (fun node -> Some node.lineage_node_identity)
            in
            Ok
              ({
                 lineage_ref_name = reference.archived_lineage_reference.archive_ref_name;
                 lineage_ref_object = reference.archived_lineage_reference.archive_ref_object;
                 lineage_ref_head;
               }
              :: reversed))
          (Ok []) references
        |> Result.map List.rev
      in
      let* lineage =
        make_lineage ~archive ~format:preserved.archive_format
          ~refs:resolved_references
      in
      let* lineage = publish_lineage store lineage in
      let* lineage = load_lineage store lineage.lineage_identity in
      Ok { lineage; lineage_nodes = List.rev !created })

let lineage_id lineage = lineage.lineage_identity
let lineage_archive lineage = lineage.lineage_archive
let lineage_refs lineage = lineage.lineage_refs
let lineage_ref_name reference = reference.lineage_ref_name
let lineage_ref_object reference = reference.lineage_ref_object
let lineage_ref_head reference = reference.lineage_ref_head
let lineage_node_id node = node.lineage_node_identity
let lineage_node_archive node = node.lineage_node_archive
let lineage_node_commit node = node.lineage_node_commit
let lineage_node_snapshot node = node.lineage_node_snapshot
let lineage_node_transition node = node.lineage_node_transition
let lineage_node_mapping node = node.lineage_node_mapping
let lineage_node_parents node = node.lineage_node_parents
