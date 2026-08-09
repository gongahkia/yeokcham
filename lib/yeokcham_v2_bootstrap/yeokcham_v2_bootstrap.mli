(** V2 local repository bootstrap and role-separated capabilities.

    This is the deliberately narrow V2-01.5 authority boundary. It binds one
    repository and local device to one ledger signing public key, but does not
    claim user identity, membership, trust policy, or a mutable ref authority.
    Private material is supplied by an external provider and is never encoded.
*)

module Model = Yeokcham_v2_model
module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger

type capability
type t
type role = Envelope_encryption | Opaque_address | Ledger_signing

module Key_handle : sig
  type t

  val byte_length : int
  val of_bytes : string -> (t, Model.identity_error) result
  val to_bytes : t -> string
  val to_hex : t -> string
  val equal : t -> t -> bool
end

type error =
  | Reused_key_material of { first : role; second : role }
  | Invalid_public_key_length of int
  | Invalid_signature_length of int
  | Invalid_key_commitment_length of int
  | Invalid_key_handle_length of int
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unsupported_schema_version of int64
  | Invalid_payload of string
  | Invalid_signer_key_id
  | Noncanonical_bootstrap
  | Signature_verification_failed
  | Cryptographic_failure of string
  | Capability_signer_mismatch
  | Capability_encryption_key_mismatch
  | Capability_address_key_mismatch
  | Ledger_error of Ledger.error

val error_to_string : error -> string
val role_to_string : role -> string
val current_schema_version : int64
val supported_mandatory_features : int64
val max_bootstrap_bytes : int

val make_capability :
  encryption_key:Envelope.key ->
  address_key:Address.key ->
  signing_key:Mirage_crypto_ec.Ed25519.priv ->
  (capability, error) result
(** Rejects reused raw key material across the three roles. *)

val secret_material : capability -> string * string * string
(** The envelope, opaque-address, and signing private-key octets, in that
    order. This is only for a platform custody adapter; it must not be written
    to repository storage, diagnostics, or fixture files. *)

val capability_of_secret_material :
  encryption_key:string ->
  address_key:string ->
  signing_key:string ->
  (capability, error) result

val envelope_key : capability -> Envelope.key
val address_key : capability -> Address.key
val capability_signer_key_id : capability -> Ledger.Signer_key_id.t
val capability_signer_public_key : capability -> string
val sign_ledger : capability -> Ledger.unsigned -> string

val public_key_registry :
  capability -> (Ledger.public_key_registry, error) result

val make :
  repository_id:Model.Repository_id.t ->
  device_id:Model.Device_id.t ->
  key_handle:Key_handle.t ->
  capability:capability ->
  mandatory_features:int64 ->
  (t, error) result

val encode : t -> string
val decode : string -> (t, error) result
val repository_id : t -> Model.Repository_id.t
val device_id : t -> Model.Device_id.t
val key_handle : t -> Key_handle.t
val signer_key_id : t -> Ledger.Signer_key_id.t
val signer_public_key : t -> string
val mandatory_features : t -> int64

val validate_capability : capability:capability -> t -> (unit, error) result
(** Proves that the injected capability matches every public bootstrap binding.
    It does not grant any authorization beyond this local bootstrap scope. *)
