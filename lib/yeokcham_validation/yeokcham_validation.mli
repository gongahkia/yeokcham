module Snapshot = Yeokcham_snapshot

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

module Unix_runner : Process_runner

type evidence
type error

val error_to_string : error -> string
val make_command : command -> (command, error) result
val command_payload : command -> (Yeokcham_encoding.t, error) result
val decode_command_payload : Yeokcham_encoding.t -> (command, error) result
val command_equal : command -> command -> bool
val evidence_id : evidence -> Yeokcham_id.Validation_id.t
val evidence_snapshot : evidence -> Snapshot.Snapshot.id
val evidence_command : evidence -> command
val evidence_command_index : evidence -> int
val evidence_status : evidence -> status
val evidence_exit_code : evidence -> int option
val evidence_signal : evidence -> int option
val evidence_execution_error : evidence -> string option
val evidence_duration_ms : evidence -> int64
val evidence_stdout_digest : evidence -> string
val evidence_stderr_digest : evidence -> string
val evidence_stdout_truncated : evidence -> bool
val evidence_stderr_truncated : evidence -> bool
val evidence_stdout_output : evidence -> Yeokcham_store.Stored_object_id.t option
val evidence_stderr_output : evidence -> Yeokcham_store.Stored_object_id.t option
val evidence_environment_fingerprint : evidence -> string option
val evidence_runner_format_version : evidence -> int64
val evidence_observed_at : evidence -> int64
val evidence_passed : evidence -> bool

val create_evidence :
  snapshot:Snapshot.Snapshot.id ->
  command:command ->
  command_index:int ->
  result:process_result ->
  stdout_output:Yeokcham_store.Stored_object_id.t option ->
  stderr_output:Yeokcham_store.Stored_object_id.t option ->
  observed_at:int64 ->
  (evidence, error) result

val evidence_payload : evidence -> (Yeokcham_encoding.t, error) result
val decode_evidence_payload : Yeokcham_encoding.t -> (evidence, error) result

val store_evidence :
  Yeokcham_store.repository ->
  evidence ->
  (Yeokcham_store.Stored_object_id.t, error) result

val load_evidence :
  Yeokcham_store.repository ->
  Yeokcham_store.Stored_object_id.t ->
  (evidence, error) result

val run :
  ?runner:(module Process_runner) ->
  store:Yeokcham_store.repository ->
  snapshot:Snapshot.Snapshot.id ->
  command:command ->
  command_index:int ->
  observed_at:int64 ->
  unit ->
  (evidence * Yeokcham_store.Stored_object_id.t, error) result
