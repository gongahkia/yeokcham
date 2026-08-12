(** Narrow client for the V2 secure runtime's MLS bootstrap operations.

    It speaks ADR-069 frames over private pipes and never persists a request,
    MLS snapshot, exporter secret, or response. The Rust runtime owns MLS
    operations; this adapter owns only bounded request construction and reply
    binding. *)

module Model = Yeokcham_v2_model

type configuration

type error =
  | Runtime_missing of string
  | Runtime_start_failed of string
  | Runtime_io_error of { operation : string; message : string }
  | Runtime_exit of {
      exit_code : int option;
      signal : int option;
      message : string;
    }
  | Ipc_error of Yeokcham_v2_secure_ipc.error
  | Invalid_runtime_response of string
  | Runtime_refused of string
  | Entropy_failure

val error_to_string : error -> string
val default_configuration : configuration
val configuration_with : ?runtime_path:string -> configuration -> configuration
val max_runtime_state_bytes : int

val bootstrap :
  configuration ->
  group_id:Model.Mls_group_id.t ->
  device_id:Model.Device_id.t ->
  (string, error) result
(** Creates exactly one initial MLS member. The returned bytes are an opaque
    MLS-library snapshot and must be immediately encrypted by the caller. *)

val derive_metadata_key :
  configuration ->
  group_id:Model.Mls_group_id.t ->
  device_id:Model.Device_id.t ->
  runtime_state:string ->
  (Yeokcham_v2_envelope.key, error) result
(** Derives one 32-byte exporter secret from a verified group snapshot. *)
