module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Hash = Yeokcham_hash.Sha256
module Id = Yeokcham_id
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

type environment_policy = Empty | Inherit

type command = {
  executable : string;
  arguments : string list;
  working_directory : string list;
  timeout_ms : int64;
  max_stdout_bytes : int;
  max_stderr_bytes : int;
  environment_policy : environment_policy;
  environment : (string * string) list;
  retain_output : bool;
  format_version : int64;
  mandatory_features : int64;
}

type status = Passed | Failed | Timed_out | Execution_error
type captured_stream = { digest : string; retained : string; truncated : bool }

type process_result = {
  runner_status : status;
  runner_exit_code : int option;
  runner_signal : int option;
  runner_execution_error : string option;
  runner_duration_ms : int64;
  runner_stdout : captured_stream;
  runner_stderr : captured_stream;
  runner_environment_fingerprint : string option;
}

module type Process_runner = sig
  val run : command -> working_directory:string -> process_result
end

type evidence = {
  id : Id.Validation_id.t;
  snapshot : Snapshot.Snapshot.id;
  command : command;
  command_index : int;
  status : status;
  exit_code : int option;
  signal : int option;
  execution_error : string option;
  duration_ms : int64;
  stdout : captured_stream;
  stderr : captured_stream;
  stdout_output : Store.Stored_object_id.t option;
  stderr_output : Store.Stored_object_id.t option;
  environment_fingerprint : string option;
  runner_format_version : int64;
  observed_at : int64;
}

type error =
  | Store_error of Store.error
  | Snapshot_error of Snapshot.error
  | Materialize_error of Snapshot.Materialize.error
  | Envelope_error of Envelope.creation_error
  | Encoding_error of Encoding.construction_error
  | Invalid_command of string
  | Invalid_evidence of string
  | Decode_error of string
  | Unsupported_schema_version of int64
  | Unexpected_object_type of {
      expected : Envelope.object_type;
      actual : Envelope.object_type;
    }
  | Logical_identity_mismatch
  | Temporary_directory_error of string

let error_to_string = function
  | Store_error error -> Store.error_to_string error
  | Snapshot_error error -> Snapshot.error_to_string error
  | Materialize_error error -> Snapshot.Materialize.error_to_string error
  | Envelope_error error -> Envelope.creation_error_to_string error
  | Encoding_error error -> Encoding.construction_error_to_string error
  | Invalid_command message -> "invalid validation command: " ^ message
  | Invalid_evidence message -> "invalid validation evidence: " ^ message
  | Decode_error message -> "invalid validation schema: " ^ message
  | Unsupported_schema_version version ->
      Printf.sprintf "unsupported validation schema version: %Ld" version
  | Unexpected_object_type { expected; actual } ->
      Printf.sprintf "expected object type %d, got object type %d"
        (Envelope.object_type_code expected)
        (Envelope.object_type_code actual)
  | Logical_identity_mismatch ->
      "validation evidence logical ID does not match canonical preimage"
  | Temporary_directory_error message ->
      "validation temporary directory failed: " ^ message

let ( let* ) = Result.bind

let value_array values =
  Encoding.array values |> Result.map_error (fun error -> Encoding_error error)

let text value =
  Encoding.text value |> Result.map_error (fun error -> Encoding_error error)

let raw_snapshot identity =
  Snapshot.Snapshot.stored_object_id identity
  |> Store.Stored_object_id.to_raw_bytes

let raw_stored = Store.Stored_object_id.to_raw_bytes
let raw_validation = Id.Validation_id.to_bytes

let id_from_digest digest =
  match Id.Validation_id.of_bytes digest with
  | Ok identity -> identity
  | Error _ -> assert false

let hash domain value =
  Hash.feed_string Hash.empty domain |> fun context ->
  Hash.feed_string context value |> Hash.get |> Hash.to_raw_string

let valid_component value =
  (not (String.is_empty value))
  && (not (String.equal value "."))
  && (not (String.equal value ".."))
  && (not (String.contains value '/'))
  && not (String.contains value '\000')

let valid_environment_name value =
  (not (String.is_empty value))
  && (not (String.contains value '='))
  && not (String.contains value '\000')

let is_sorted_unique_environment environment =
  let rec loop previous = function
    | [] -> true
    | (name, _) :: rest -> (
        match previous with
        | None -> loop (Some name) rest
        | Some previous ->
            String.compare previous name < 0 && loop (Some name) rest)
  in
  loop None environment

let make_command command =
  if command.format_version <> 1L then
    Error (Invalid_command "unsupported command format version")
  else if command.mandatory_features <> 0L then
    Error (Invalid_command "unknown command mandatory features")
  else if
    String.is_empty command.executable
    || String.contains command.executable '\000'
  then Error (Invalid_command "executable must be nonempty and contain no NUL")
  else if Int64.compare command.timeout_ms 0L < 0 then
    Error (Invalid_command "timeout must be non-negative")
  else if command.max_stdout_bytes < 0 || command.max_stderr_bytes < 0 then
    Error (Invalid_command "output limits must be non-negative")
  else if
    List.exists
      (fun value -> not (valid_component value))
      command.working_directory
  then
    Error
      (Invalid_command "working directory must use safe relative components")
  else if
    List.exists
      (fun (name, value) ->
        (not (valid_environment_name name)) || String.contains value '\000')
      command.environment
  then Error (Invalid_command "environment additions are malformed")
  else if not (is_sorted_unique_environment command.environment) then
    Error (Invalid_command "environment additions must be ordered and unique")
  else Ok command

let environment_policy_code = function Empty -> 0L | Inherit -> 1L

let environment_policy_of_code = function
  | 0L -> Ok Empty
  | 1L -> Ok Inherit
  | value ->
      Error
        (Decode_error (Printf.sprintf "unknown environment policy: %Ld" value))

let command_payload command =
  let* command = make_command command in
  let* executable = text command.executable in
  let* arguments =
    List.fold_left
      (fun result argument ->
        let* reversed = result in
        let* argument = text argument in
        Ok (argument :: reversed))
      (Ok []) command.arguments
    |> Result.map List.rev
    |> fun result -> Result.bind result value_array
  in
  let working_directory = List.map Encoding.bytes command.working_directory in
  let* working_directory = value_array working_directory in
  let* environment =
    List.fold_left
      (fun result (name, value) ->
        let* reversed = result in
        let* name = text name in
        let* value = text value in
        let* pair = value_array [ name; value ] in
        Ok (pair :: reversed))
      (Ok []) command.environment
    |> Result.map List.rev
    |> fun result -> Result.bind result value_array
  in
  value_array
    [
      Encoding.integer command.format_version;
      executable;
      arguments;
      working_directory;
      Encoding.integer command.timeout_ms;
      Encoding.integer (Int64.of_int command.max_stdout_bytes);
      Encoding.integer (Int64.of_int command.max_stderr_bytes);
      Encoding.integer (environment_policy_code command.environment_policy);
      environment;
      Encoding.bool command.retain_output;
      Encoding.integer command.mandatory_features;
    ]

let fields name expected = function
  | Encoding.Array values when List.length values = expected -> Ok values
  | Encoding.Array _ ->
      Error (Decode_error (Printf.sprintf "%s has wrong arity" name))
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be an array"))

let integer name = function
  | Encoding.Integer value -> Ok value
  | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be an integer"))

let text_field name = function
  | Encoding.Text value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be text"))

let bytes name = function
  | Encoding.Bytes value -> Ok value
  | Encoding.Integer _ | Encoding.Text _ | Encoding.Array _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be bytes"))

let boolean name = function
  | Encoding.Bool value -> Ok value
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
  | Encoding.Map _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be a boolean"))

let optional name parse = function
  | Encoding.Null -> Ok None
  | ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
    | Encoding.Map _ | Encoding.Bool _ ) as value ->
      parse name value |> Result.map Option.some

let parse_raw_stored name value =
  let* raw = bytes name value in
  match Store.Stored_object_id.of_raw_bytes raw with
  | Some identity -> Ok identity
  | None -> Error (Decode_error (name ^ " must be a 32-byte stored object ID"))

let parse_snapshot name value =
  let* stored = parse_raw_stored name value in
  Ok (Snapshot.Snapshot.of_stored_object_id stored)

let parse_validation name value =
  let* raw = bytes name value in
  if String.length raw <> 32 then
    Error (Decode_error (name ^ " must be a 32-byte validation ID"))
  else
    match Id.Validation_id.of_bytes raw with
    | Ok identity -> Ok identity
    | Error _ -> assert false

let parse_nonnegative_int name value =
  let* value = integer name value in
  if
    Int64.compare value 0L < 0 || Int64.compare value (Int64.of_int max_int) > 0
  then Error (Decode_error (name ^ " is out of range"))
  else Ok (Int64.to_int value)

let parse_array name = function
  | Encoding.Array values -> Ok values
  | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
  | Encoding.Bool _ | Encoding.Null ->
      Error (Decode_error (name ^ " must be an array"))

let decode_command_payload value =
  let* values = fields "validation command" 11 value in
  match values with
  | [
   version;
   executable;
   arguments;
   working_directory;
   timeout_ms;
   max_stdout_bytes;
   max_stderr_bytes;
   environment_policy;
   environment;
   retain_output;
   mandatory_features;
  ] ->
      let* format_version = integer "validation command version" version in
      let* executable = text_field "validation executable" executable in
      let* arguments = parse_array "validation arguments" arguments in
      let* arguments =
        List.fold_left
          (fun result value ->
            let* reversed = result in
            let* value = text_field "validation argument" value in
            Ok (value :: reversed))
          (Ok []) arguments
        |> Result.map List.rev
      in
      let* working_directory =
        parse_array "validation working directory" working_directory
      in
      let* working_directory =
        List.fold_left
          (fun result value ->
            let* reversed = result in
            let* value = bytes "validation working directory component" value in
            Ok (value :: reversed))
          (Ok []) working_directory
        |> Result.map List.rev
      in
      let* timeout_ms = integer "validation timeout" timeout_ms in
      let* max_stdout_bytes =
        parse_nonnegative_int "validation stdout limit" max_stdout_bytes
      in
      let* max_stderr_bytes =
        parse_nonnegative_int "validation stderr limit" max_stderr_bytes
      in
      let* environment_policy =
        integer "validation environment policy" environment_policy
      in
      let* environment_policy = environment_policy_of_code environment_policy in
      let* environment = parse_array "validation environment" environment in
      let* environment =
        List.fold_left
          (fun result value ->
            let* reversed = result in
            let* pair = fields "validation environment addition" 2 value in
            match pair with
            | [ name; value ] ->
                let* name = text_field "validation environment name" name in
                let* value = text_field "validation environment value" value in
                Ok ((name, value) :: reversed)
            | _ -> assert false)
          (Ok []) environment
        |> Result.map List.rev
      in
      let* retain_output = boolean "validation retain output" retain_output in
      let* mandatory_features =
        integer "validation command mandatory features" mandatory_features
      in
      let command =
        {
          executable;
          arguments;
          working_directory;
          timeout_ms;
          max_stdout_bytes;
          max_stderr_bytes;
          environment_policy;
          environment;
          retain_output;
          format_version;
          mandatory_features;
        }
      in
      let* command = make_command command in
      let* canonical = command_payload command in
      if Encoding.equal canonical value then Ok command
      else Error (Decode_error "validation command bytes are noncanonical")
  | _ -> assert false

let command_equal left right =
  match (command_payload left, command_payload right) with
  | Ok left, Ok right -> Encoding.equal left right
  | Error _, Error _ -> true
  | Error _, Ok _ | Ok _, Error _ -> false

let status_code = function
  | Passed -> 0L
  | Failed -> 1L
  | Timed_out -> 2L
  | Execution_error -> 3L

let status_of_code = function
  | 0L -> Ok Passed
  | 1L -> Ok Failed
  | 2L -> Ok Timed_out
  | 3L -> Ok Execution_error
  | value ->
      Error
        (Decode_error (Printf.sprintf "unknown validation status: %Ld" value))

let optional_integer = function
  | None -> Encoding.null
  | Some value -> Encoding.integer (Int64.of_int value)

let optional_raw_bytes = function
  | None -> Encoding.null
  | Some value -> Encoding.bytes value

let optional_stored = function
  | None -> Encoding.null
  | Some value -> Encoding.bytes (raw_stored value)

let optional_text value =
  match value with None -> Ok Encoding.null | Some value -> text value

let evidence_identity_value ~snapshot ~command ~command_index
    ~(result : process_result) ~stdout_output ~stderr_output =
  let* command = command_payload command in
  let* execution_error = optional_text result.runner_execution_error in
  let environment_fingerprint =
    optional_raw_bytes result.runner_environment_fingerprint
  in
  value_array
    [
      Encoding.integer 1L;
      Encoding.bytes (raw_snapshot snapshot);
      command;
      Encoding.integer (Int64.of_int command_index);
      Encoding.integer (status_code result.runner_status);
      optional_integer result.runner_exit_code;
      optional_integer result.runner_signal;
      execution_error;
      Encoding.bytes result.runner_stdout.digest;
      Encoding.bytes result.runner_stderr.digest;
      Encoding.bool result.runner_stdout.truncated;
      Encoding.bool result.runner_stderr.truncated;
      optional_stored stdout_output;
      optional_stored stderr_output;
      environment_fingerprint;
      Encoding.integer 1L;
    ]

let validate_stream name limit stream =
  if String.length stream.digest <> Hash.digest_size then
    Error (Invalid_evidence (name ^ " digest must be 32 bytes"))
  else if String.length stream.retained > limit then
    Error (Invalid_evidence (name ^ " retained output exceeds limit"))
  else if
    (not stream.truncated)
    && not
         (String.equal stream.digest
            (Hash.digest_string stream.retained |> Hash.to_raw_string))
  then
    Error
      (Invalid_evidence
         (name ^ " digest disagrees with complete retained output"))
  else Ok ()

let validate_result command (result : process_result) =
  let* () =
    validate_stream "stdout" command.max_stdout_bytes result.runner_stdout
  in
  let* () =
    validate_stream "stderr" command.max_stderr_bytes result.runner_stderr
  in
  if Int64.compare result.runner_duration_ms 0L < 0 then
    Error (Invalid_evidence "duration must be non-negative")
  else
    match result.runner_status with
    | Passed
      when result.runner_exit_code = Some 0
           && result.runner_signal = None
           && result.runner_execution_error = None ->
        Ok ()
    | Failed when result.runner_execution_error = None -> Ok ()
    | Timed_out
      when result.runner_exit_code = None
           && result.runner_execution_error = None ->
        Ok ()
    | Execution_error
      when result.runner_exit_code = None
           && result.runner_signal = None
           && Option.is_some result.runner_execution_error ->
        Ok ()
    | Passed ->
        Error (Invalid_evidence "passed evidence must record exit code zero")
    | Failed ->
        Error
          (Invalid_evidence
             "failed evidence must not contain an execution error")
    | Timed_out ->
        Error
          (Invalid_evidence "timeout evidence has incompatible status fields")
    | Execution_error ->
        Error (Invalid_evidence "execution error requires an error message")

let create_evidence ~snapshot ~command ~command_index ~result ~stdout_output
    ~stderr_output ~observed_at =
  let* command = make_command command in
  if command_index < 0 then
    Error (Invalid_evidence "command index must be non-negative")
  else
    let* () = validate_result command result in
    let* identity =
      evidence_identity_value ~snapshot ~command ~command_index ~result
        ~stdout_output ~stderr_output
    in
    let id =
      hash "yeokcham:validation-evidence:v1\000" (Encoding.encode identity)
      |> id_from_digest
    in
    Ok
      {
        id;
        snapshot;
        command;
        command_index;
        status = result.runner_status;
        exit_code = result.runner_exit_code;
        signal = result.runner_signal;
        execution_error = result.runner_execution_error;
        duration_ms = result.runner_duration_ms;
        stdout = result.runner_stdout;
        stderr = result.runner_stderr;
        stdout_output;
        stderr_output;
        environment_fingerprint = result.runner_environment_fingerprint;
        runner_format_version = 1L;
        observed_at;
      }

let evidence_id (evidence : evidence) = evidence.id
let evidence_snapshot (evidence : evidence) = evidence.snapshot
let evidence_command (evidence : evidence) = evidence.command
let evidence_command_index (evidence : evidence) = evidence.command_index
let evidence_status (evidence : evidence) = evidence.status
let evidence_exit_code (evidence : evidence) = evidence.exit_code
let evidence_signal (evidence : evidence) = evidence.signal
let evidence_execution_error (evidence : evidence) = evidence.execution_error
let evidence_duration_ms (evidence : evidence) = evidence.duration_ms
let evidence_stdout_digest (evidence : evidence) = evidence.stdout.digest
let evidence_stderr_digest (evidence : evidence) = evidence.stderr.digest
let evidence_stdout_truncated (evidence : evidence) = evidence.stdout.truncated
let evidence_stderr_truncated (evidence : evidence) = evidence.stderr.truncated
let evidence_stdout_output (evidence : evidence) = evidence.stdout_output
let evidence_stderr_output (evidence : evidence) = evidence.stderr_output

let evidence_environment_fingerprint (evidence : evidence) =
  evidence.environment_fingerprint

let evidence_runner_format_version (evidence : evidence) =
  evidence.runner_format_version

let evidence_observed_at (evidence : evidence) = evidence.observed_at
let evidence_passed (evidence : evidence) = evidence.status = Passed

let evidence_payload evidence =
  let result : process_result =
    {
      runner_status = evidence.status;
      runner_exit_code = evidence.exit_code;
      runner_signal = evidence.signal;
      runner_execution_error = evidence.execution_error;
      runner_duration_ms = evidence.duration_ms;
      runner_stdout = evidence.stdout;
      runner_stderr = evidence.stderr;
      runner_environment_fingerprint = evidence.environment_fingerprint;
    }
  in
  let* identity =
    evidence_identity_value ~snapshot:evidence.snapshot
      ~command:evidence.command ~command_index:evidence.command_index ~result
      ~stdout_output:evidence.stdout_output
      ~stderr_output:evidence.stderr_output
  in
  let derived =
    hash "yeokcham:validation-evidence:v1\000" (Encoding.encode identity)
    |> id_from_digest
  in
  if not (Id.Validation_id.equal evidence.id derived) then
    Error Logical_identity_mismatch
  else
    let* command = command_payload evidence.command in
    let* execution_error = optional_text evidence.execution_error in
    let environment_fingerprint =
      optional_raw_bytes evidence.environment_fingerprint
    in
    value_array
      [
        Encoding.integer 1L;
        Encoding.bytes (raw_validation evidence.id);
        Encoding.bytes (raw_snapshot evidence.snapshot);
        command;
        Encoding.integer (Int64.of_int evidence.command_index);
        Encoding.integer (status_code evidence.status);
        optional_integer evidence.exit_code;
        optional_integer evidence.signal;
        execution_error;
        Encoding.integer evidence.duration_ms;
        Encoding.bytes evidence.stdout.digest;
        Encoding.bytes evidence.stderr.digest;
        Encoding.bool evidence.stdout.truncated;
        Encoding.bool evidence.stderr.truncated;
        optional_stored evidence.stdout_output;
        optional_stored evidence.stderr_output;
        environment_fingerprint;
        Encoding.integer evidence.runner_format_version;
        Encoding.integer evidence.observed_at;
      ]

let parse_optional_integer name = function
  | Encoding.Null -> Ok None
  | ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Array _
    | Encoding.Map _ | Encoding.Bool _ ) as value ->
      let* value = integer name value in
      if
        Int64.compare value (Int64.of_int min_int) < 0
        || Int64.compare value (Int64.of_int max_int) > 0
      then Error (Decode_error (name ^ " is out of range"))
      else Ok (Some (Int64.to_int value))

let parse_optional_text name = optional name text_field
let parse_optional_stored name = optional name parse_raw_stored
let parse_optional_raw_bytes name = optional name bytes

let decode_evidence_payload value =
  let* values = fields "validation evidence" 19 value in
  match values with
  | [
   version;
   supplied_id;
   snapshot;
   command;
   command_index;
   status;
   exit_code;
   signal;
   execution_error;
   duration_ms;
   stdout_digest;
   stderr_digest;
   stdout_truncated;
   stderr_truncated;
   stdout_output;
   stderr_output;
   environment_fingerprint;
   runner_format_version;
   observed_at;
  ] ->
      let* version = integer "validation evidence version" version in
      if version <> 1L then Error (Unsupported_schema_version version)
      else
        let* supplied_id =
          parse_validation "validation evidence ID" supplied_id
        in
        let* snapshot = parse_snapshot "validation snapshot ID" snapshot in
        let* command = decode_command_payload command in
        let* command_index =
          parse_nonnegative_int "validation command index" command_index
        in
        let* status =
          integer "validation status" status |> fun result ->
          Result.bind result status_of_code
        in
        let* exit_code =
          parse_optional_integer "validation exit code" exit_code
        in
        let* signal = parse_optional_integer "validation signal" signal in
        let* execution_error =
          parse_optional_text "validation execution error" execution_error
        in
        let* duration_ms = integer "validation duration" duration_ms in
        let* stdout_digest = bytes "validation stdout digest" stdout_digest in
        let* stderr_digest = bytes "validation stderr digest" stderr_digest in
        let* stdout_truncated =
          boolean "validation stdout truncation" stdout_truncated
        in
        let* stderr_truncated =
          boolean "validation stderr truncation" stderr_truncated
        in
        let* stdout_output =
          parse_optional_stored "validation stdout output" stdout_output
        in
        let* stderr_output =
          parse_optional_stored "validation stderr output" stderr_output
        in
        let* environment_fingerprint =
          parse_optional_raw_bytes "validation environment fingerprint"
            environment_fingerprint
        in
        let* runner_format_version =
          integer "validation runner format version" runner_format_version
        in
        let* observed_at = integer "validation observed at" observed_at in
        if runner_format_version <> 1L then
          Error (Decode_error "unsupported validation runner format version")
        else
          let result : process_result =
            {
              runner_status = status;
              runner_exit_code = exit_code;
              runner_signal = signal;
              runner_execution_error = execution_error;
              runner_duration_ms = duration_ms;
              runner_stdout =
                {
                  digest = stdout_digest;
                  retained = "";
                  truncated = stdout_truncated;
                };
              runner_stderr =
                {
                  digest = stderr_digest;
                  retained = "";
                  truncated = stderr_truncated;
                };
              runner_environment_fingerprint = environment_fingerprint;
            }
          in
          let* () =
            if
              String.length stdout_digest <> Hash.digest_size
              || String.length stderr_digest <> Hash.digest_size
            then Error (Invalid_evidence "stream digest must be 32 bytes")
            else
              match status with
              | Passed
                when exit_code = Some 0 && signal = None
                     && execution_error = None ->
                  Ok ()
              | Failed when execution_error = None -> Ok ()
              | Timed_out when exit_code = None && execution_error = None ->
                  Ok ()
              | Execution_error
                when exit_code = None && signal = None
                     && Option.is_some execution_error ->
                  Ok ()
              | Passed | Failed | Timed_out | Execution_error ->
                  Error (Invalid_evidence "status fields are incompatible")
          in
          let* identity =
            evidence_identity_value ~snapshot ~command ~command_index ~result
              ~stdout_output ~stderr_output
          in
          let derived =
            hash "yeokcham:validation-evidence:v1\000"
              (Encoding.encode identity)
            |> id_from_digest
          in
          if not (Id.Validation_id.equal supplied_id derived) then
            Error Logical_identity_mismatch
          else
            let evidence =
              {
                id = supplied_id;
                snapshot;
                command;
                command_index;
                status;
                exit_code;
                signal;
                execution_error;
                duration_ms;
                stdout =
                  {
                    digest = stdout_digest;
                    retained = "";
                    truncated = stdout_truncated;
                  };
                stderr =
                  {
                    digest = stderr_digest;
                    retained = "";
                    truncated = stderr_truncated;
                  };
                stdout_output;
                stderr_output;
                environment_fingerprint;
                runner_format_version;
                observed_at;
              }
            in
            let* canonical = evidence_payload evidence in
            if Encoding.equal canonical value then Ok evidence
            else
              Error (Decode_error "validation evidence bytes are noncanonical")
  | _ -> assert false

let object_envelope object_type payload =
  Envelope.create ~object_type ~object_format_version:1 ~mandatory_features:0L
    ~payload ()
  |> Result.map_error (fun error -> Envelope_error error)

let store_evidence store evidence =
  let* payload = evidence_payload evidence in
  let* envelope = object_envelope Envelope.Validation payload in
  Store.put store envelope |> Result.map_error (fun error -> Store_error error)

let validate_output store = function
  | None -> Ok ()
  | Some object_id ->
      Snapshot.Content.load store
        (Snapshot.Content.of_stored_object_id object_id)
      |> Result.map_error (fun error -> Snapshot_error error)
      |> Result.map (fun _ -> ())

let load_evidence store object_id =
  let* envelope =
    Store.get store object_id
    |> Result.map_error (fun error -> Store_error error)
  in
  if Envelope.object_type envelope <> Envelope.Validation then
    Error
      (Unexpected_object_type
         {
           expected = Envelope.Validation;
           actual = Envelope.object_type envelope;
         })
  else
    let* evidence = decode_evidence_payload (Envelope.payload envelope) in
    let* _ =
      Snapshot.Snapshot.load store evidence.snapshot
      |> Result.map_error (fun error -> Snapshot_error error)
    in
    let* () = validate_output store evidence.stdout_output in
    let* () = validate_output store evidence.stderr_output in
    Ok evidence

let remove_tree path =
  let rec remove path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
        Sys.readdir path
        |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path
    | { Unix.st_kind = Unix.S_REG; _ }
    | { Unix.st_kind = Unix.S_CHR; _ }
    | { Unix.st_kind = Unix.S_BLK; _ }
    | { Unix.st_kind = Unix.S_LNK; _ }
    | { Unix.st_kind = Unix.S_FIFO; _ }
    | { Unix.st_kind = Unix.S_SOCK; _ } ->
        Unix.unlink path
  in
  try remove path with Unix.Unix_error _ | Sys_error _ -> ()

let fresh_directory () =
  try
    let path = Filename.temp_file "yeokcham-validation-" "" in
    Sys.remove path;
    Unix.mkdir path 0o700;
    Ok path
  with Sys_error message | Unix.Unix_error (_, _, message) ->
    Error (Temporary_directory_error message)

let fingerprint_environment environment =
  String.concat "\000" (Array.to_list environment)
  |> hash "yeokcham:validation-environment:v1\000"
  |> Option.some

module Unix_runner : Process_runner = struct
  type accumulator = {
    mutable context : Hash.context;
    retained_bytes : Buffer.t;
    limit : int;
    mutable was_truncated : bool;
  }

  let accumulator limit =
    {
      context = Hash.empty;
      retained_bytes = Buffer.create (min limit 4096);
      limit;
      was_truncated = false;
    }

  let feed accumulator bytes length =
    accumulator.context <-
      Hash.feed_bytes accumulator.context ~off:0 ~len:length bytes;
    let available =
      accumulator.limit - Buffer.length accumulator.retained_bytes
    in
    if available > 0 then
      Buffer.add_subbytes accumulator.retained_bytes bytes 0
        (min available length);
    if length > available then accumulator.was_truncated <- true

  let finish accumulator : captured_stream =
    {
      digest = Hash.get accumulator.context |> Hash.to_raw_string;
      retained = Buffer.contents accumulator.retained_bytes;
      truncated = accumulator.was_truncated;
    }

  let environment command =
    let inherited =
      match command.environment_policy with
      | Empty -> []
      | Inherit -> Array.to_list (Unix.environment ())
    in
    let without_overrides =
      List.filter
        (fun item ->
          not
            (List.exists
               (fun (name, _) -> String.starts_with ~prefix:(name ^ "=") item)
               command.environment))
        inherited
    in
    List.map (fun (name, value) -> name ^ "=" ^ value) command.environment
    |> List.rev_append without_overrides
    |> Array.of_list

  let kill_group pid signal =
    try Unix.kill (-pid) signal
    with Unix.Unix_error _ -> (
      try Unix.kill pid signal with Unix.Unix_error _ -> ())

  let run command ~working_directory =
    let started = Unix.gettimeofday () in
    let deadline = started +. (Int64.to_float command.timeout_ms /. 1000.) in
    let stdout_read, stdout_write = Unix.pipe () in
    let stderr_read, stderr_write = Unix.pipe () in
    let error_read, error_write = Unix.pipe () in
    Unix.set_close_on_exec error_write;
    let child = Unix.fork () in
    if child = 0 then (
      (try ignore (Unix.setsid ()) with Unix.Unix_error _ -> ());
      Unix.close stdout_read;
      Unix.close stderr_read;
      Unix.close error_read;
      try
        Unix.chdir working_directory;
        Unix.dup2 stdout_write Unix.stdout;
        Unix.dup2 stderr_write Unix.stderr;
        Unix.close stdout_write;
        Unix.close stderr_write;
        let argv = Array.of_list (command.executable :: command.arguments) in
        Unix.execve command.executable argv (environment command)
      with
      | Unix.Unix_error (error, function_name, argument) ->
          let message =
            Unix.error_message error ^ ": " ^ function_name ^ " " ^ argument
          in
          ignore
            (Unix.write_substring error_write message 0 (String.length message));
          Unix.close error_write;
          exit 127
      | Sys_error message ->
          ignore
            (Unix.write_substring error_write message 0 (String.length message));
          Unix.close error_write;
          exit 127)
    else (
      Unix.close stdout_write;
      Unix.close stderr_write;
      Unix.close error_write;
      List.iter Unix.set_nonblock [ stdout_read; stderr_read; error_read ];
      let stdout = accumulator command.max_stdout_bytes in
      let stderr = accumulator command.max_stderr_bytes in
      let error_text = Buffer.create 128 in
      let open_stdout = ref true in
      let open_stderr = ref true in
      let open_error = ref true in
      let process_status = ref None in
      let timed_out = ref false in
      let sent_kill = ref false in
      let terminated_at = ref None in
      let read_stream descriptor accumulator open_ =
        let buffer = Bytes.create 8192 in
        let rec loop () =
          try
            match Unix.read descriptor buffer 0 (Bytes.length buffer) with
            | 0 ->
                Unix.close descriptor;
                open_ := false
            | length ->
                feed accumulator buffer length;
                loop ()
          with
          | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
          | Unix.Unix_error _ ->
              Unix.close descriptor;
              open_ := false
        in
        loop ()
      in
      let read_error () =
        let buffer = Bytes.create 512 in
        let rec loop () =
          try
            match Unix.read error_read buffer 0 (Bytes.length buffer) with
            | 0 ->
                Unix.close error_read;
                open_error := false
            | length ->
                Buffer.add_subbytes error_text buffer 0 length;
                loop ()
          with
          | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
          | Unix.Unix_error _ ->
              Unix.close error_read;
              open_error := false
        in
        loop ()
      in
      while
        Option.is_none !process_status
        || !open_stdout || !open_stderr || !open_error
      do
        (if Option.is_none !process_status then
           match Unix.waitpid [ Unix.WNOHANG ] child with
           | 0, _ -> ()
           | _, status -> process_status := Some status);
        let now = Unix.gettimeofday () in
        if Option.is_none !process_status && (not !timed_out) && now >= deadline
        then (
          timed_out := true;
          terminated_at := Some now;
          kill_group child Sys.sigterm);
        if
          !timed_out && (not !sent_kill)
          && Option.is_none !process_status
          && Option.fold ~none:false
               ~some:(fun at -> now -. at >= 0.1)
               !terminated_at
        then (
          sent_kill := true;
          kill_group child Sys.sigkill);
        let descriptors =
          (if !open_stdout then [ stdout_read ] else [])
          @ (if !open_stderr then [ stderr_read ] else [])
          @ if !open_error then [ error_read ] else []
        in
        if descriptors <> [] then (
          let ready, _, _ = Unix.select descriptors [] [] 0.01 in
          if List.mem stdout_read ready then
            read_stream stdout_read stdout open_stdout;
          if List.mem stderr_read ready then
            read_stream stderr_read stderr open_stderr;
          if List.mem error_read ready then read_error ())
        else if Option.is_none !process_status then
          ignore (Unix.select [] [] [] 0.01)
      done;
      let duration_ms =
        Int64.of_float ((Unix.gettimeofday () -. started) *. 1000.)
      in
      let status, exit_code, signal, execution_error =
        let execution_error = Buffer.contents error_text in
        if not (String.is_empty execution_error) then
          (Execution_error, None, None, Some execution_error)
        else if !timed_out then
          let signal =
            match !process_status with
            | Some (Unix.WSIGNALED signal | Unix.WSTOPPED signal) -> Some signal
            | Some (Unix.WEXITED _) | None -> Some Sys.sigterm
          in
          (Timed_out, None, signal, None)
        else
          match !process_status with
          | Some (Unix.WEXITED 0) -> (Passed, Some 0, None, None)
          | Some (Unix.WEXITED code) -> (Failed, Some code, None, None)
          | Some (Unix.WSIGNALED signal | Unix.WSTOPPED signal) ->
              (Failed, None, Some signal, None)
          | None ->
              ( Execution_error,
                None,
                None,
                Some "process status was unavailable" )
      in
      {
        runner_status = status;
        runner_exit_code = exit_code;
        runner_signal = signal;
        runner_execution_error = execution_error;
        runner_duration_ms = max 0L duration_ms;
        runner_stdout = finish stdout;
        runner_stderr = finish stderr;
        runner_environment_fingerprint =
          fingerprint_environment (environment command);
      })
end

let execution_error_result message =
  let digest = Hash.digest_string "" |> Hash.to_raw_string in
  {
    runner_status = Execution_error;
    runner_exit_code = None;
    runner_signal = None;
    runner_execution_error = Some message;
    runner_duration_ms = 0L;
    runner_stdout = { digest; retained = ""; truncated = false };
    runner_stderr = { digest; retained = ""; truncated = false };
    runner_environment_fingerprint = None;
  }

let retain_output store command stream =
  if not command.retain_output then Ok None
  else
    Snapshot.Content.store store stream.retained
    |> Result.map (fun output ->
        Some (Snapshot.Content.stored_object_id output))
    |> Result.map_error (fun error -> Snapshot_error error)

let run ?(runner = (module Unix_runner : Process_runner)) ~store ~snapshot
    ~command ~command_index ~observed_at () =
  let* command = make_command command in
  let* materialised =
    Snapshot.Snapshot.load store snapshot
    |> Result.map_error (fun error -> Snapshot_error error)
  in
  let* temporary = fresh_directory () in
  let finished =
    try
      match
        Snapshot.Materialize.write ~destination:temporary store materialised
      with
      | Error error -> Error (Materialize_error error)
      | Ok () ->
          let working_directory =
            List.fold_left Filename.concat temporary command.working_directory
          in
          let module Runner = (val runner : Process_runner) in
          let result =
            try Runner.run command ~working_directory with
            | Unix.Unix_error (error, function_name, argument) ->
                execution_error_result
                  (Unix.error_message error ^ ": " ^ function_name ^ " "
                 ^ argument)
            | Sys_error message -> execution_error_result message
          in
          let* stdout_output =
            retain_output store command result.runner_stdout
          in
          let* stderr_output =
            retain_output store command result.runner_stderr
          in
          let* evidence =
            create_evidence ~snapshot ~command ~command_index ~result
              ~stdout_output ~stderr_output ~observed_at
          in
          let* object_id = store_evidence store evidence in
          Ok (evidence, object_id)
    with Unix.Unix_error (error, function_name, argument) ->
      Error
        (Temporary_directory_error
           (Unix.error_message error ^ ": " ^ function_name ^ " " ^ argument))
  in
  remove_tree temporary;
  finished
