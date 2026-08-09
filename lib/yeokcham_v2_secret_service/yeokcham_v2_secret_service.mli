(** Linux Secret Service custody for one local V2 bootstrap capability.

    The adapter uses only public fixed application/schema labels and the signed
    random bootstrap key handle as lookup attributes. Private capability bytes
    are sent to [secret-tool] only over standard input, never command arguments,
    repository storage, diagnostics, or fixture files. *)

module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Model = Yeokcham_v2_model

type command = { program : string; arguments : string list; stdin : string }
type command_result = { exit_code : int; stdout : string }
type command_error = Spawn_failed | Timed_out | Output_limit_exceeded
type runner = command -> (command_result, command_error) result
type service
type initialization = Initialized | Already_initialized

type enrollment = {
  initialization : initialization;
  repository : Bootstrap_store.repository;
}

type error =
  | Secret_service_unavailable
  | Secret_service_locked
  | Secret_missing
  | Secret_handle_in_use
  | Invalid_secret_material
  | Bootstrap_error of Bootstrap.error
  | Bootstrap_store_error of Bootstrap_store.error
  | Entropy_failure

val error_to_string : error -> string
val default_service : unit -> service
val service : runner:runner -> secret_tool:string -> busctl:string -> service

val key_handle_of_bytes :
  string -> (Bootstrap.Key_handle.t, Model.identity_error) result

val generate_capability : unit -> (Bootstrap.capability, error) result
val generate_key_handle : unit -> (Bootstrap.Key_handle.t, error) result

val enroll :
  service:service ->
  root:string ->
  repository_id:Model.Repository_id.t ->
  device_id:Model.Device_id.t ->
  key_handle:Bootstrap.Key_handle.t ->
  capability:Bootstrap.capability ->
  (enrollment, error) result
(** Writes the Secret Service record before the create-only public bootstrap. A
    failed repository publication can leave an unreachable Secret Service item;
    the adapter never clears it automatically. *)

val create_and_enroll :
  service:service ->
  root:string ->
  repository_id:Model.Repository_id.t ->
  device_id:Model.Device_id.t ->
  (enrollment, error) result

val open_repository :
  service:service -> root:string -> (Bootstrap_store.repository, error) result
