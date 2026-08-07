type identity_error =
  | Invalid_byte_length of { expected : int; actual : int }
  | Invalid_hex_length of { expected : int; actual : int }
  | Invalid_hex_character of { offset : int; character : char }

val identity_error_to_string : identity_error -> string

module type Identity = sig
  type t

  val byte_length : int
  val of_bytes : string -> (t, identity_error) result
  val to_bytes : t -> string
  val of_hex : string -> (t, identity_error) result
  val to_hex : t -> string
  val short_hex : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module Repository_id : Identity
module Organization_id : Identity
module Account_id : Identity
module Device_id : Identity
module Opaque_object_ref : Identity
module Ref_event_id : Identity

module Encrypted_ref_event : sig
  type t

  val create : id:Ref_event_id.t -> object_ref:Opaque_object_ref.t -> t
  val id : t -> Ref_event_id.t
  val object_ref : t -> Opaque_object_ref.t
  val compare : t -> t -> int
end

type state_error =
  | Duplicate_object_ref of Opaque_object_ref.t
  | Noncanonical_object_ref_order of {
      previous : Opaque_object_ref.t;
      current : Opaque_object_ref.t;
    }
  | Duplicate_ref_event of Ref_event_id.t
  | Noncanonical_ref_event_order of {
      previous : Ref_event_id.t;
      current : Ref_event_id.t;
    }
  | Dangling_ref_event of {
      event_id : Ref_event_id.t;
      object_ref : Opaque_object_ref.t;
    }

val state_error_to_string : state_error -> string

type local_state
type verified_repository_state

val create_local_state :
  repository_id:Repository_id.t ->
  device_id:Device_id.t ->
  object_refs:Opaque_object_ref.t list ->
  ref_events:Encrypted_ref_event.t list ->
  (local_state, state_error) result

val verify : local_state -> (verified_repository_state, state_error) result
val verified_repository_id : verified_repository_state -> Repository_id.t
val verified_device_id : verified_repository_state -> Device_id.t
val verified_object_refs : verified_repository_state -> Opaque_object_ref.t list

val verified_ref_events :
  verified_repository_state -> Encrypted_ref_event.t list
