(** Pure V4 device identity, administrator enrolment, and signed revision
    records. Private-key custody and filesystem publication are adapters. *)

module Model = Yeokcham_v4_model

module Repository_id : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val generate : unit -> (t, string) result
end

type device
type signing_capability
type generated_device
type certificate
type membership
type signed_revision
type role = Member | Administrator

type error =
  | Invalid_public_key of int
  | Invalid_signature of int
  | Invalid_private_key
  | Entropy_failure
  | Unsupported_algorithm of string
  | Unsupported_features of int64
  | Invalid_record of string
  | Noncanonical_record
  | Identity_mismatch of string
  | Signature_verification_failed
  | Duplicate_certificate
  | Unknown_issuer_certificate
  | Unauthorized_issuer
  | Invalid_root_certificate
  | Cross_repository_certificate
  | Duplicate_device
  | Unknown_author_certificate
  | Revision_author_mismatch
  | Record_error of Yeokcham_v4_record.error

val error_to_string : error -> string
val algorithm : string
val generate_device : unit -> (generated_device, error) result
val device_of_public_key : string -> (device, error) result

val signing_capability_of_private_key :
  string -> (signing_capability, error) result

val signing_public_key : signing_capability -> string
val generated_identity : generated_device -> device
val generated_signing_capability : generated_device -> signing_capability
val device_id : device -> Model.Device_id.t
val device_public_key : device -> string
val device_equal : device -> device -> bool

val root_certificate :
  repository:Repository_id.t ->
  device:device ->
  signing_capability ->
  (certificate, error) result

val certificate_id : certificate -> string
val certificate_repository : certificate -> Repository_id.t
val certificate_subject : certificate -> device
val certificate_role : certificate -> role
val certificate_issuer : certificate -> string option
val encode_certificate : certificate -> string
val decode_certificate : string -> (certificate, error) result

val verify_membership :
  repository:Repository_id.t -> certificate list -> (membership, error) result
(** Verifies all certificate identities, signatures, and causal administrator
    authority. There must be exactly one self-signed administrator root. *)

val enroll :
  membership ->
  issuer:string ->
  signing_capability ->
  subject:device ->
  role:role ->
  (certificate, error) result

val certificates : membership -> certificate list
val repository : membership -> Repository_id.t
val is_authorized : membership -> device -> bool
val is_administrator : membership -> device -> bool

val sign_revision :
  membership ->
  certificate:string ->
  signing_capability ->
  Model.change_revision ->
  (signed_revision, error) result

val signed_revision_id : signed_revision -> Model.Revision_id.t
val signed_revision_certificate : signed_revision -> string
val signed_revision_value : signed_revision -> Model.change_revision
val encode_signed_revision : signed_revision -> string
val decode_signed_revision : string -> (signed_revision, error) result

val verify_signed_revision :
  membership -> signed_revision -> (unit, error) result
