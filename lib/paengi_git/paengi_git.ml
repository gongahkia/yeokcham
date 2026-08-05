module Validation = Paengi_validation
module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Hash = Paengi_hash.Sha256
module Id = Paengi_id
module Snapshot = Paengi_snapshot
module Store = Paengi_store

let ( let* ) = Result.bind

type object_format = Sha1 | Sha256
type inspection = { bare : bool; object_format : object_format }

let object_format_to_string = function Sha1 -> "sha1" | Sha256 -> "sha256"

type object_id = { format : object_format; raw : string }
type object_kind = Tree | Commit
type mapping_direction = Import | Export

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

type mapping_subject =
  | Imported_snapshot of Snapshot.Snapshot.id
  | Imported_transition of {
      transition : Id.Imported_transition_id.t;
      transition_object : Store.Stored_object_id.t;
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

type imported_transition = {
  transition_id : Id.Imported_transition_id.t;
  transition_commit : object_id;
  transition_tree : object_id;
  transition_snapshot : Snapshot.Snapshot.id;
  transition_parents : object_id list;
}

type commit_import_result = {
  imported_transition : imported_transition;
  commit_mapping : mapping;
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
  max_commit_bytes : int;
  max_commit_parents : int;
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
  }

let configuration_with ?git ?timeout_ms ?max_stdout_bytes ?max_stderr_bytes
    ?max_tree_bytes ?max_total_tree_bytes ?max_blob_bytes ?max_total_blob_bytes
    ?max_tree_entries ?max_depth ?max_commit_bytes ?max_commit_parents
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
  | Unsupported_tree_mode of { identity : object_id; mode : string }
  | Invalid_symlink_target of { identity : object_id }
  | Unexpected_object_type of {
      identity : object_id;
      expected : string;
      actual : string;
    }
  | Import_limit_exceeded of { resource : string; limit : int; actual : int }
  | Snapshot_error of Snapshot.error
  | Mapping_error of string
  | Imported_transition_error of string
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
  | Unsupported_tree_mode { identity; mode } ->
      Printf.sprintf "unsupported Git tree mode %S in %s" mode
        (object_id_to_hex identity)
  | Invalid_symlink_target { identity } ->
      Printf.sprintf "Git symlink target contains NUL bytes: %s"
        (object_id_to_hex identity)
  | Unexpected_object_type { identity; expected; actual } ->
      Printf.sprintf "Git object %s has type %s, expected %s"
        (object_id_to_hex identity) actual expected
  | Import_limit_exceeded { resource; limit; actual } ->
      Printf.sprintf "Git import %s limit exceeded (%d > %d)" resource actual
        limit
  | Snapshot_error error -> Snapshot.error_to_string error
  | Mapping_error detail -> "Git mapping error: " ^ detail
  | Imported_transition_error detail -> "imported transition error: " ^ detail
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
  then Error (Invalid_configuration "Git import limits must be positive")
  else if configuration.max_blob_bytes > Store.max_object_bytes then
    Error
      (Invalid_configuration
         (Printf.sprintf "Git blob limit exceeds Paengi object limit (%d > %d)"
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

let command configuration executable repository arguments =
  {
    Validation.executable;
    arguments = "-C" :: repository :: arguments;
    working_directory = [];
    timeout_ms = configuration.timeout_ms;
    max_stdout_bytes = configuration.max_stdout_bytes;
    max_stderr_bytes = configuration.max_stderr_bytes;
    environment_policy = Validation.Empty;
    environment = [];
    retain_output = false;
    format_version = 1L;
    mandatory_features = 0L;
  }

let run ?(runner = (module Validation.Unix_runner : Validation.Process_runner))
    configuration executable repository ~operation arguments =
  let module Runner = (val runner : Validation.Process_runner) in
  let result =
    Runner.run
      (command configuration executable repository arguments)
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
    configuration executable repository ~operation ~max_stdout_bytes arguments =
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
      environment = [];
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
      ~operation:(("cat-file-") ^ kind) ~max_stdout_bytes:limit
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
  | 1 -> "paengi:git-mapping:v1\000"
  | 2 -> "paengi:git-mapping:v2\000"
  | _ -> assert false

let mapping_binding_domain = function
  | 1 -> "paengi:git-mapping-binding:v1\000"
  | 2 -> "paengi:git-mapping-binding:v2\000"
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
let kind_code = function Tree -> 1L | Commit -> 2L

let valid_mapping_combination_v1 direction kind subject =
  match (direction, kind, subject) with
  | Import, Tree, Imported_snapshot _ -> true
  | Import, Commit, Imported_revision _ -> true
  | Export, Commit, Exported_release _ | Export, Commit, Exported_revision _ ->
      true
  | ( Import,
      Commit,
      ( Imported_snapshot _ | Imported_transition _ | Exported_release _
      | Exported_revision _ ) )
  | ( Import,
      Tree,
      ( Imported_transition _ | Imported_revision _ | Exported_release _
      | Exported_revision _ ) )
  | Export, Tree, _
  | Export, Commit,
    (Imported_snapshot _ | Imported_transition _ | Imported_revision _) ->
      false

let valid_mapping_combination version direction kind subject =
  (Int.equal version 1 && valid_mapping_combination_v1 direction kind subject)
  ||
  (Int.equal version 2
  &&
  (valid_mapping_combination_v1 direction kind subject
  ||
  (direction = Import
  && kind = Commit
  &&
  match subject with
  | Imported_transition _ -> true
  | Imported_snapshot _ | Imported_revision _ | Exported_release _
  | Exported_revision _ -> false)))

let mapping_identity_payload ~version ~direction ~git_object ~git_kind ~subject =
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

let create_mapping_with_version version ~direction ~git_object ~git_kind ~subject =
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
    mapping_identity_payload ~version:mapping.version ~direction:mapping.direction
      ~git_object:mapping.git_object ~git_kind:mapping.git_kind
      ~subject:mapping.subject
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
              mapping_stored_id "imported transition object ID" transition_object
            in
            Ok (Imported_transition { transition; transition_object })
        | _ ->
            Error
              (Mapping_error "imported transition subject has invalid length")
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
      if not (Int64.equal version 1L || Int64.equal version 2L) then
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
      if not (Int64.equal version 1L || Int64.equal version 2L) then
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

let transition_domain = "paengi:imported-transition:v1\000"
let transition_binding_domain = "paengi:imported-transition-binding:v1\000"

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
  transition_array
    [ Encoding.integer 1L; commit; tree; snapshot; parents ]

let object_id_equal left right =
  left.format = right.format && String.equal left.raw right.raw

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
          Error
            (Imported_transition_error "commit parent IDs must be unique")
        else loop (parent :: seen) rest
  in
  loop [] parents

let derive_transition_id ~commit ~tree ~snapshot ~parents =
  let* identity = transition_identity_payload ~commit ~tree ~snapshot ~parents in
  let raw =
    Hash.feed_string Hash.empty transition_domain |> fun context ->
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
      }

let transition_payload transition =
  let* identity =
    transition_identity_payload ~commit:transition.transition_commit
      ~tree:transition.transition_tree ~snapshot:transition.transition_snapshot
      ~parents:transition.transition_parents
  in
  let* id =
    transition_identity_value "imported transition ID"
      (Id.Imported_transition_id.to_bytes transition.transition_id)
  in
  match identity with
  | Encoding.Array [ _; commit; tree; snapshot; parents ] ->
      transition_array [ Encoding.integer 1L; id; commit; tree; snapshot; parents ]
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null | Encoding.Array _ -> assert false

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

let decode_transition_payload value =
  let* fields = transition_fields "imported transition" 6 value in
  match fields with
  | [ version; supplied_id; commit; tree; snapshot; parents ] ->
      let* version = transition_integer "imported transition version" version in
      if not (Int64.equal version 1L) then
        Error
          (Imported_transition_error
             (Printf.sprintf "unsupported imported transition version: %Ld"
                version))
      else
        let* supplied_id =
          transition_raw_id "imported transition ID"
            Id.Imported_transition_id.of_bytes supplied_id
        in
        let* commit = transition_object_id_of_value commit in
        let* tree = transition_object_id_of_value tree in
        let* snapshot = transition_stored_id "imported transition snapshot ID" snapshot in
        let snapshot = Snapshot.Snapshot.of_stored_object_id snapshot in
        let* parents = decode_transition_parents commit parents in
        let* transition =
          create_imported_transition ~commit ~tree ~snapshot ~parents
        in
      if
        not
          (Id.Imported_transition_id.equal supplied_id transition.transition_id)
      then
          Error
            (Imported_transition_error
               "imported transition logical ID does not match its preimage")
        else
          let* canonical = transition_payload transition in
          if String.equal (Encoding.encode canonical) (Encoding.encode value)
          then Ok transition
          else
            Error
              (Imported_transition_error
                 "imported transition payload is noncanonical")
  | _ -> assert false

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
  | Encoding.Bool _ | Encoding.Null | Encoding.Array _ -> assert false

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
          transition_bytes "imported transition binding checksum" supplied_checksum
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
                 "imported transition ID already has a different immutable binding"))
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
    | None -> Error (Imported_transition_error "imported transition binding is absent")
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
      if
        not
          (Id.Imported_transition_id.equal transition.transition_id logical)
      then
        Error
          (Imported_transition_error
             "imported transition logical ID disagrees with binding")
      else Ok (transition, physical)

let load_imported_transition store logical =
  let* transition, _ = load_transition_binding store logical in
  let* _ =
    Snapshot.Snapshot.load store transition.transition_snapshot
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  Ok transition

let imported_transition_id transition = transition.transition_id
let imported_transition_commit transition = transition.transition_commit
let imported_transition_tree transition = transition.transition_tree
let imported_transition_snapshot transition = transition.transition_snapshot
let imported_transition_parents transition = transition.transition_parents

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
      else
        let* _ =
          Snapshot.Snapshot.load store loaded.transition_snapshot
          |> Result.map_error (fun error -> Snapshot_error error)
        in
        Ok ()
  | Imported_revision _ | Exported_release _ | Exported_revision _ -> Ok ()

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
          detail = Printf.sprintf "%s is not a full %s object ID" label
                     (object_format_to_string identity.format);
        })

let parse_commit_headers ~max_parents identity raw =
  let* header_end =
    match commit_header_end raw with
    | Some index -> Ok index
    | None ->
        Error
          (Invalid_commit
             { identity; detail = "header block is not terminated by a blank line" })
  in
  let header = String.sub raw 0 header_end in
  let lines = String.split_on_char '\n' header in
  let rec parse tree parents previous_header = function
    | [] -> (
        match tree with
        | Some tree -> Ok (tree, List.rev parents)
        | None -> Error (Invalid_commit { identity; detail = "tree header is absent" }))
    | line :: rest ->
        if String.is_empty line then
          Error (Invalid_commit { identity; detail = "empty commit header line" })
        else if Char.equal line.[0] ' ' then
          if previous_header then parse tree parents true rest
          else
            Error
              (Invalid_commit
                 { identity; detail = "header continuation has no prior header" })
        else
          match String.index_opt line ' ' with
          | None ->
              Error
                (Invalid_commit
                   { identity; detail = "commit header lacks a key/value separator" })
          | Some separator ->
              let key = String.sub line 0 separator in
              let value =
                String.sub line (separator + 1)
                  (String.length line - separator - 1)
              in
              if String.is_empty key then
                Error (Invalid_commit { identity; detail = "commit header key is empty" })
              else if String.equal key "tree" then
                match tree with
                | Some _ ->
                    Error
                      (Invalid_commit
                         { identity; detail = "tree header occurs more than once" })
                | None ->
                    let* tree = commit_object_id identity "tree header" value in
                    parse (Some tree) parents true rest
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
                  let* parent = commit_object_id identity "parent header" value in
                  parse tree (parent :: parents) true rest
              else parse tree parents true rest
  in
  let* tree, parents = parse None [] false lines in
  let rec valid_parents seen = function
    | [] -> Ok ()
    | parent :: rest ->
        if object_id_equal parent identity then
          Error
            (Invalid_commit { identity; detail = "commit names itself as a parent" })
        else if List.exists (object_id_equal parent) seen then
          Error
            (Invalid_commit
               { identity; detail = "commit names a parent more than once" })
        else valid_parents (parent :: seen) rest
  in
  let* () = valid_parents [] parents in
  Ok (tree, parents)

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
      read_exact_object ?runner configuration executable repository ~identity:commit
        ~kind:"commit" ~limit:configuration.max_commit_bytes
    in
    let* tree, parents =
      parse_commit_headers ~max_parents:configuration.max_commit_parents commit raw
    in
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
    let* transition =
      create_imported_transition ~commit ~tree ~snapshot:tree_import.snapshot
        ~parents
    in
    let* transition, transition_object = publish_transition store transition in
    let* mapping =
      create_mapping_with_version 2 ~direction:Import ~git_object:commit
        ~git_kind:Commit
        ~subject:
          (Imported_transition
             {
               transition = transition.transition_id;
               transition_object;
             })
    in
    let* mapping = publish_mapping store mapping in
    Ok { imported_transition = transition; commit_mapping = mapping }
