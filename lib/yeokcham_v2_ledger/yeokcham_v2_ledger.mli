(** Canonical immutable V2 ref-ledger events from ADR-048.

    This module proves cryptographic validity against caller-supplied public
    keys. It deliberately does not establish trust, enrolment, ownership, or
    permission. *)

module Repository_id = Yeokcham_v2_model.Repository_id
module Opaque_object_ref = Yeokcham_v2_model.Opaque_object_ref
module Event_id = Yeokcham_v2_model.Ref_event_id
module Signer_key_id = Yeokcham_v2_model.Signer_key_id

module Ref_name : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
  val compare : t -> t -> int
  val equal : t -> t -> bool
end

module Ref_target : sig
  type t

  val of_opaque_object_ref : Opaque_object_ref.t -> t
  val to_opaque_object_ref : t -> Opaque_object_ref.t
end

type unsigned
type t
type verified
type public_key_registry

type verification =
  | Cryptographically_valid of verified
  | Unknown_signer of Signer_key_id.t

type divergence
type head_set

type error =
  | Invalid_public_key_length of int
  | Invalid_signature_length of int
  | Invalid_ref_name of string
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unsupported_schema_version of int64
  | Unsupported_algorithm of string
  | Invalid_payload of string
  | Invalid_event_id
  | Noncanonical_event
  | Too_many_public_keys of int
  | Duplicate_public_key of Signer_key_id.t
  | Noncanonical_public_key_order of {
      previous : Signer_key_id.t;
      current : Signer_key_id.t;
    }
  | Cryptographic_failure of string
  | Signature_verification_failed
  | Duplicate_event of Event_id.t
  | Missing_predecessor of { event : Event_id.t; predecessor : Event_id.t }
  | Cross_scope_predecessor of { event : Event_id.t; predecessor : Event_id.t }
  | Causal_cycle of Event_id.t

val error_to_string : error -> string
val algorithm : string
val supported_mandatory_features : int64
val max_public_keys : int
val max_candidate_events : int
val signer_key_id_of_public_key : string -> (Signer_key_id.t, error) result

val make_public_key_registry :
  (Signer_key_id.t * string) list -> (public_key_registry, error) result

val make_unsigned :
  repository_id:Repository_id.t ->
  ref_name:Ref_name.t ->
  signer_key_id:Signer_key_id.t ->
  predecessor:Event_id.t option ->
  target:Ref_target.t option ->
  mandatory_features:int64 ->
  (unsigned, error) result

val unsigned_event_id : unsigned -> Event_id.t
val unsigned_repository_id : unsigned -> Repository_id.t
val unsigned_ref_name : unsigned -> Ref_name.t
val unsigned_signer_key_id : unsigned -> Signer_key_id.t
val unsigned_predecessor : unsigned -> Event_id.t option
val unsigned_target : unsigned -> Ref_target.t option
val unsigned_bytes : unsigned -> string
val signing_bytes : unsigned -> string

val make :
  unsigned:unsigned -> algorithm:string -> signature:string -> (t, error) result

val event_id : t -> Event_id.t
val event_unsigned : t -> unsigned
val event_signature : t -> string
val encode : t -> string
val decode : string -> (t, error) result

val verify :
  public_keys:public_key_registry -> t -> (verification, error) result

val verified_event : verified -> t

val evaluate :
  repository_id:Repository_id.t ->
  ref_name:Ref_name.t ->
  verified list ->
  (head_set, error) result

val heads : head_set -> verified list
val divergences : head_set -> divergence list
val divergence_predecessor : divergence -> Event_id.t option
val divergence_children : divergence -> Event_id.t list
