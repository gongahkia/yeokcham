(** Narrow client for the V2 secure runtime's MLS bootstrap operations.

    It speaks ADR-069 frames over private pipes and never persists a request,
    MLS snapshot, exporter secret, or response. The Rust runtime owns MLS
    operations; this adapter owns only bounded request construction and reply
    binding. *)

module Model = Yeokcham_v2_model

type configuration

type add_member_result = {
  add_issuer_runtime_state : string;
  add_recipient_runtime_state : string;
  add_commit : string;
  add_welcome : string;
  add_previous_epoch : int64;
  add_next_epoch : int64;
}

type remove_member_result = {
  remove_issuer_runtime_state : string;
  remove_commit : string;
  remove_previous_epoch : int64;
  remove_next_epoch : int64;
}

type apply_commit_result =
  | Applied of {
      applied_runtime_state : string;
      applied_previous_epoch : int64;
      applied_next_epoch : int64;
    }
  | Removed of {
      removed_previous_epoch : int64;
      removed_observed_epoch : int64;
    }

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

val add_member :
  configuration ->
  group_id:Model.Mls_group_id.t ->
  issuer_device_id:Model.Device_id.t ->
  issuer_runtime_state:string ->
  recipient_device_id:Model.Device_id.t ->
  (add_member_result, error) result
(** Performs one MLS Add proposal, Commit, and Welcome join entirely in the
    isolated runtime. Both returned snapshots are opaque MLS-library state. *)

val remove_member :
  configuration ->
  group_id:Model.Mls_group_id.t ->
  issuer_device_id:Model.Device_id.t ->
  issuer_runtime_state:string ->
  removed_device_id:Model.Device_id.t ->
  (remove_member_result, error) result
(** Removes one distinct current device through a MLS Commit and advances the
    issuer snapshot exactly one MLS epoch. *)

val apply_commit :
  configuration ->
  group_id:Model.Mls_group_id.t ->
  device_id:Model.Device_id.t ->
  runtime_state:string ->
  commit:string ->
  (apply_commit_result, error) result
(** Applies an externally delivered MLS Commit to an active local device. A
    removed device receives [Removed] and never gets a successor snapshot. *)
