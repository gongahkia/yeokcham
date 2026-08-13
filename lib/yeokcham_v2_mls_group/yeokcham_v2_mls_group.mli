(** V2-029's repository-scoped initial MLS group model.

    A state contains MLS-library bytes but never exposes them to callers. It is
    a strict canonical plaintext only for immediate encryption under the
    existing device envelope key; it is not a repository object or authority
    decision. *)

module Model = Yeokcham_v2_model
module Runtime = Yeokcham_v2_mls_runtime

type t

type add_member_result = {
  issuer_state : t;
  recipient_state : t;
  commit : string;
  welcome : string;
}

type error =
  | Invalid_runtime_state of string
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Noncanonical_state
  | Group_binding_mismatch of string
  | Runtime_error of Runtime.error
  | Envelope_error of Yeokcham_v2_envelope.error
  | Entropy_failure

val error_to_string : error -> string
val current_schema_version : int64
val supported_mandatory_features : int64
val metadata_plaintext_limit : int
val group_id_for_repository : Model.Repository_id.t -> Model.Mls_group_id.t

val create :
  runtime:Runtime.configuration ->
  repository_id:Model.Repository_id.t ->
  device_id:Model.Device_id.t ->
  (t, error) result
(** Creates an MLS group with exactly the supplied initial device member. *)

val encode : t -> string
val decode : string -> (t, error) result
val repository_id : t -> Model.Repository_id.t
val device_id : t -> Model.Device_id.t
val group_id : t -> Model.Mls_group_id.t

val seal_state :
  key:Yeokcham_v2_envelope.key ->
  nonce:Yeokcham_v2_envelope.nonce ->
  t ->
  (Yeokcham_v2_envelope.t, error) result

val open_state :
  key:Yeokcham_v2_envelope.key -> Yeokcham_v2_envelope.t -> (t, error) result

val verify : runtime:Runtime.configuration -> t -> (unit, error) result
(** Loading the snapshot and deriving the domain-separated exporter key proves
    that the runtime accepts the state for its declared repository group. *)

val add_member :
  runtime:Runtime.configuration ->
  issuer_state:t ->
  recipient_device_id:Model.Device_id.t ->
  (add_member_result, error) result
(** Advances an issuer snapshot by one MLS Add/Commit and joins the requested
    recipient device through the emitted Welcome. The runtime must verify both
    resulting snapshots before they are returned. *)

val encrypt_metadata :
  runtime:Runtime.configuration ->
  state:t ->
  nonce:Yeokcham_v2_envelope.nonce ->
  string ->
  (Yeokcham_v2_envelope.t, error) result

val decrypt_metadata :
  runtime:Runtime.configuration ->
  state:t ->
  Yeokcham_v2_envelope.t ->
  (string, error) result
