(** Canonical root-signed V2 authority records from ADR-065.

    This pure core verifies independently constructible repository authority,
    device certificate, and device revocation records. It deliberately does not
    make a record active: an authority-scoped causal ledger supplies that
    ordering in a later adapter. *)

module Repository_id = Yeokcham_v2_model.Repository_id
module User_id = Yeokcham_v2_model.User_id
module Root_key_id = Yeokcham_v2_model.Root_key_id
module Device_id = Yeokcham_v2_model.Device_id
module Device_certificate_id = Yeokcham_v2_model.Device_certificate_id
module Device_revocation_id = Yeokcham_v2_model.Device_revocation_id
module Signer_key_id = Yeokcham_v2_model.Signer_key_id

type root_signing_capability
type repository_authority
type device_certificate
type device_revocation
type authority_state
type device_status = Active | Revoked of device_revocation

type error =
  | Invalid_root_private_key of string
  | Invalid_root_public_key of string
  | Invalid_device_signer_public_key of int
  | Invalid_signature_length of int
  | Invalid_key_commitment_length of { field : string; actual : int }
  | Invalid_key_handle_length of int
  | Reused_root_as_device_signer
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unsupported_schema_version of int64
  | Unsupported_algorithm of string
  | Invalid_payload of string
  | Invalid_identity of string
  | Authority_mismatch of string
  | Signature_verification_failed
  | Cryptographic_failure of string
  | Noncanonical_record
  | Duplicate_device_certificate of Device_certificate_id.t
  | Duplicate_device of Device_id.t
  | Duplicate_device_revocation of Device_revocation_id.t
  | Multiple_revocations of Device_certificate_id.t
  | Unknown_revocation_certificate of Device_certificate_id.t

val error_to_string : error -> string
val current_schema_version : int64
val supported_mandatory_features : int64
val algorithm : string

val root_signing_capability_of_private_key :
  string -> (root_signing_capability, error) result

val root_public_key : root_signing_capability -> string

(* Raw private bytes are only for an encrypted, caller-owned recovery package;
   callers must not persist them in repository or service state. *)
val root_private_key_bytes : root_signing_capability -> string
val root_key_id : root_signing_capability -> Root_key_id.t
val user_id : root_signing_capability -> User_id.t
val user_id_of_root_public_key : string -> (User_id.t, error) result
val root_key_id_of_public_key : string -> (Root_key_id.t, error) result

val sign_root_message :
  root_signing_capability -> domain:string -> string -> (string, error) result
(** Signs a caller-owned, domain-separated protocol message. The caller must
    use a fixed protocol domain; raw private key bytes remain unnecessary. *)

val verify_root_message :
  public_key:string -> domain:string -> string -> signature:string -> (unit, error) result

val make_repository_authority :
  repository_id:Repository_id.t ->
  root:root_signing_capability ->
  mandatory_features:int64 ->
  (repository_authority, error) result

val repository_authority_id :
  repository_authority -> Yeokcham_v2_model.Repository_authority_id.t

val repository_authority_repository_id : repository_authority -> Repository_id.t
val repository_authority_user_id : repository_authority -> User_id.t
val repository_authority_root_key_id : repository_authority -> Root_key_id.t
val repository_authority_root_public_key : repository_authority -> string
val repository_authority_mandatory_features : repository_authority -> int64
val encode_repository_authority : repository_authority -> string
val decode_repository_authority : string -> (repository_authority, error) result

val make_device_certificate :
  authority:repository_authority ->
  root:root_signing_capability ->
  device_id:Device_id.t ->
  signer_public_key:string ->
  envelope_key_commitment:string ->
  address_key_commitment:string ->
  key_handle:string ->
  mandatory_features:int64 ->
  (device_certificate, error) result

val device_certificate_id : device_certificate -> Device_certificate_id.t
val device_certificate_repository_id : device_certificate -> Repository_id.t
val device_certificate_user_id : device_certificate -> User_id.t
val device_certificate_device_id : device_certificate -> Device_id.t
val device_certificate_signer_key_id : device_certificate -> Signer_key_id.t
val device_certificate_signer_public_key : device_certificate -> string
val device_certificate_envelope_key_commitment : device_certificate -> string
val device_certificate_address_key_commitment : device_certificate -> string
val device_certificate_key_handle : device_certificate -> string
val device_certificate_mandatory_features : device_certificate -> int64
val encode_device_certificate : device_certificate -> string

val validate_device_certificate_payload : string -> (unit, error) result
(** Checks the strict canonical public record shape and its derived bindings.
    Root-signature verification requires [decode_device_certificate]. *)

val decode_device_certificate :
  authority:repository_authority -> string -> (device_certificate, error) result

val make_device_revocation :
  authority:repository_authority ->
  root:root_signing_capability ->
  certificate:device_certificate ->
  mandatory_features:int64 ->
  (device_revocation, error) result

val device_revocation_id : device_revocation -> Device_revocation_id.t
val device_revocation_repository_id : device_revocation -> Repository_id.t
val device_revocation_user_id : device_revocation -> User_id.t

val device_revocation_certificate_id :
  device_revocation -> Device_certificate_id.t

val device_revocation_mandatory_features : device_revocation -> int64
val encode_device_revocation : device_revocation -> string

val validate_device_revocation_payload : string -> (unit, error) result
(** Checks the strict canonical public record shape and its derived bindings.
    Root-signature verification requires [decode_device_revocation]. *)

val decode_device_revocation :
  authority:repository_authority -> string -> (device_revocation, error) result

val evaluate :
  authority:repository_authority ->
  certificates:device_certificate list ->
  revocations:device_revocation list ->
  (authority_state, error) result

val authority_state_authority : authority_state -> repository_authority
val authority_state_certificates : authority_state -> device_certificate list
val authority_state_revocations : authority_state -> device_revocation list
val device_status : authority_state -> Device_id.t -> device_status option
