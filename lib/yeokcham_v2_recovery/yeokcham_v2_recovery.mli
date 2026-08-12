(** Offline V2 authority-root recovery packages. The secret is generated and
    retained outside repository/service state; recovery creates only a proposed
    replacement certificate, never an active authority transition. *)

module Authority = Yeokcham_v2_authority
module Bootstrap = Yeokcham_v2_bootstrap
module Model = Yeokcham_v2_model

type recovery_secret
type package
type recovered

type ceremony = {
  secret : recovery_secret;
  verification_phrase : string;
  package : package;
}

type error =
  | Invalid_recovery_secret of string
  | Verification_phrase_mismatch
  | Invalid_package_id of Model.identity_error
  | Entropy_failure
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Noncanonical_package
  | Authority_error of Authority.error
  | Envelope_error of Yeokcham_v2_envelope.error
  | Authority_root_mismatch
  | Package_binding_mismatch of string

val error_to_string : error -> string
val current_schema_version : int64
val supported_mandatory_features : int64
val max_package_bytes : int
val recovery_secret_of_bytes : string -> (recovery_secret, error) result
val recovery_secret_of_hex : string -> (recovery_secret, error) result
val recovery_secret_to_hex : recovery_secret -> string
val verification_phrase : recovery_secret -> string
val verify_phrase : recovery_secret -> string -> (unit, error) result
val generate_recovery_secret : unit -> (recovery_secret, error) result

val make :
  secret:recovery_secret ->
  package_id:Model.Recovery_package_id.t ->
  nonce:Yeokcham_v2_envelope.nonce ->
  authority:Authority.repository_authority ->
  root:Authority.root_signing_capability ->
  mandatory_features:int64 ->
  (package, error) result

val create :
  authority:Authority.repository_authority ->
  root:Authority.root_signing_capability ->
  (ceremony, error) result

val encode : package -> string
val decode : string -> (package, error) result
val package_id : package -> Model.Recovery_package_id.t
val repository_id : package -> Model.Repository_id.t
val user_id : package -> Model.User_id.t

val recover :
  secret:recovery_secret ->
  verification_phrase:string ->
  package:package ->
  (recovered, error) result

val recovered_authority : recovered -> Authority.repository_authority

val make_replacement_device_certificate :
  recovered:recovered ->
  device_id:Model.Device_id.t ->
  key_handle:Bootstrap.Key_handle.t ->
  capability:Bootstrap.capability ->
  (Authority.device_certificate, error) result
