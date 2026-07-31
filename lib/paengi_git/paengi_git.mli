type object_format = Sha1 | Sha256
type inspection = { bare : bool; object_format : object_format }

type configuration = {
  git : string;
  timeout_ms : int64;
  max_stdout_bytes : int;
  max_stderr_bytes : int;
}

val default_configuration : configuration

val configuration_with :
  ?git:string ->
  ?timeout_ms:int64 ->
  ?max_stdout_bytes:int ->
  ?max_stderr_bytes:int ->
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

val error_to_string : error -> string
val object_format_to_string : object_format -> string
val inspection_bare : inspection -> bool
val inspection_object_format : inspection -> object_format

val inspect :
  ?runner:(module Paengi_validation.Process_runner) ->
  configuration ->
  repository:string ->
  (inspection, error) result
