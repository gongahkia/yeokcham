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
type epoch
type authority
type authorization
type adoption
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
  | Unknown_epoch
  | Invalid_epoch of string
  | Duplicate_epoch
  | Authority_fork
  | Revoked_device
  | Unauthorized_epoch_issuer
  | Invalid_recovery_authority
  | Unknown_authorization
  | Authorization_mismatch
  | Duplicate_authorization
  | Record_error of Yeokcham_v4_record.error

val error_to_string : error -> string
val algorithm : string
val generate_device : unit -> (generated_device, error) result
val device_of_public_key : string -> (device, error) result

val signing_capability_of_private_key :
  string -> (signing_capability, error) result

val signing_private_key_bytes : signing_capability -> string
(** Available only to signer-provider adapters for transfer into an OS secret
    store. Callers must never persist, render, package, or log these bytes. *)

val signing_public_key : signing_capability -> string

(* Signs protocol-owned, domain-separated bytes without exposing private key
   material. Callers must use a fixed protocol domain, never user input. *)
val sign_detached : signing_capability -> domain:string -> string -> string

(* Verifies a detached protocol signature against an explicit public device. *)
val verify_detached :
  device:device ->
  domain:string ->
  signature:string ->
  string ->
  (unit, error) result

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

val extend_membership :
  membership -> certificate list -> (membership, error) result
(** Extends a verified membership only with certificates compatible with its
    existing causal root. Exact repeats are harmless; a conflicting record or an
    alternate root is rejected. *)

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
(** Retained only to reject authority-less call paths explicitly. Released V4
    signed revisions require [sign_revision_at]. *)

val sign_resolution :
  membership ->
  certificate:string ->
  signing_capability ->
  decision:Model.Decision_id.t ->
  Model.change_revision ->
  (signed_revision, error) result
(** Retained only to reject authority-less call paths explicitly. Released V4
    signed resolutions require [sign_resolution_at]. *)

val signed_revision_id : signed_revision -> Model.Revision_id.t
val signed_revision_certificate : signed_revision -> string
val signed_revision_value : signed_revision -> Model.change_revision
val signed_revision_resolution : signed_revision -> Model.Decision_id.t option
val encode_signed_revision : signed_revision -> string
val decode_signed_revision : string -> (signed_revision, error) result

val verify_signed_revision :
  membership -> signed_revision -> (unit, error) result
(** Retained only to reject authority-less call paths explicitly. Released V4
    signed revisions require [verify_signed_revision_at]. *)

val epoch_id : epoch -> string
(** Branching authority epochs are a public, immutable policy graph. They are
    deliberately separate from username registration and private-key custody. *)

val epoch_parents : epoch -> string list
val epoch_revoked : epoch -> Model.Device_id.t list
val epoch_frontier : epoch -> Model.Revision_id.t list
val epoch_recovery_device : epoch -> device
val encode_epoch : epoch -> string
val decode_epoch : string -> (epoch, error) result

val root_epoch :
  membership:membership ->
  root_certificate:string ->
  recovery_device:device ->
  signing_capability ->
  (epoch, error) result

val successor_epoch :
  authority ->
  parents:string list ->
  certificates:certificate list ->
  revoked:Model.Device_id.t list ->
  frontier:Model.Revision_id.t list ->
  recovery_device:device ->
  issuer:string ->
  signing_capability ->
  (epoch, error) result
(** Creates a one-parent lifecycle epoch or an explicit multi-parent
    reconciliation. The issuer must be an administrator in every parent. *)

val recover_epoch :
  authority ->
  parents:string list ->
  certificates:certificate list ->
  revoked:Model.Device_id.t list ->
  frontier:Model.Revision_id.t list ->
  recovery_device:device ->
  signing_capability ->
  (epoch, error) result
(** Uses the recovery authority shared by every selected parent. Recovery
    replaces that authority atomically, so a consumed recovery key cannot remain
    active in the resulting epoch. *)

val recover_enroll :
  authority ->
  parents:string list ->
  subject:device ->
  role:role ->
  signing_capability ->
  (certificate, error) result
(** Creates a replacement device certificate signed by the recovery authority
    shared by [parents]. It has no effect until the same recovery successor
    epoch explicitly includes it. *)

val verify_authority :
  membership:membership -> epoch list -> (authority, error) result

val extend_authority : authority -> epoch list -> (authority, error) result
val authority_membership : authority -> membership
val authority_epochs : authority -> epoch list
val authority_heads : authority -> string list
val authority_epoch : authority -> string -> (epoch, error) result
val authority_device_active : authority -> epoch:string -> device -> bool
val authority_device_administrator : authority -> epoch:string -> device -> bool
val authority_epoch_is_head : authority -> string -> bool

val requires_late_review : authority -> signed_revision -> (bool, error) result
(** [requires_late_review] is true when the record was valid in its named
    historical epoch, but at least one current authority head causally descends
    from that epoch and revokes its signer. Such a record is never accepted
    automatically on receive: a current-head adoption is required. *)

val sign_revision_at :
  authority ->
  epoch:string ->
  certificate:string ->
  signing_capability ->
  Model.change_revision ->
  (signed_revision, error) result

val sign_resolution_at :
  authority ->
  epoch:string ->
  certificate:string ->
  signing_capability ->
  decision:Model.Decision_id.t ->
  Model.change_revision ->
  (signed_revision, error) result

val signed_revision_epoch : signed_revision -> string option

val verify_signed_revision_at :
  authority -> signed_revision -> (unit, error) result

val make_authorization :
  authority ->
  epoch:string ->
  issuer:string ->
  signing_capability ->
  device:device ->
  revision:Model.Revision_id.t ->
  change:Model.Change_id.t ->
  (authorization, error) result

val encode_authorization : authorization -> string
val decode_authorization : string -> (authorization, error) result
val authorization_revision : authorization -> Model.Revision_id.t
val authorization_epoch : authorization -> string
val verify_authorization : authority -> authorization -> (unit, error) result

val authorization_matches_signed_revision :
  authorization -> signed_revision -> bool

val make_adoption :
  authority ->
  epoch:string ->
  issuer:string ->
  signing_capability ->
  signed_revision:signed_revision ->
  (adoption, error) result

val encode_adoption : adoption -> string
val decode_adoption : string -> (adoption, error) result
val adoption_revision : adoption -> Model.Revision_id.t
val adoption_epoch : adoption -> string
val verify_adoption : authority -> adoption -> (unit, error) result
val adoption_matches_signed_revision : adoption -> signed_revision -> bool
