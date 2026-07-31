module Validation = Paengi_validation

type object_format = Sha1 | Sha256
type inspection = { bare : bool; object_format : object_format }

type configuration = {
  git : string;
  timeout_ms : int64;
  max_stdout_bytes : int;
  max_stderr_bytes : int;
}

let default_configuration =
  {
    git = "git";
    timeout_ms = 5_000L;
    max_stdout_bytes = 1_024;
    max_stderr_bytes = 4_096;
  }

let configuration_with ?git ?timeout_ms ?max_stdout_bytes ?max_stderr_bytes
    configuration =
  {
    git = Option.value ~default:configuration.git git;
    timeout_ms = Option.value ~default:configuration.timeout_ms timeout_ms;
    max_stdout_bytes =
      Option.value ~default:configuration.max_stdout_bytes max_stdout_bytes;
    max_stderr_bytes =
      Option.value ~default:configuration.max_stderr_bytes max_stderr_bytes;
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

let object_format_to_string = function Sha1 -> "sha1" | Sha256 -> "sha256"
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
