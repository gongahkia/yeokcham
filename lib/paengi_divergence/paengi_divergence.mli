module Event = Paengi_ref_event
module Object_id = Paengi_store.Stored_object_id

type entry
type link
type t

type error =
  | Invalid_repository_format
  | Invalid_ref_name of string
  | Invalid_repository_digest of int
  | Invalid_entry_count of int
  | Duplicate_event_id of Event.Event_id.t
  | Event_context_mismatch of string
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Unsupported_mandatory_features of int64
  | Set_too_large of int
  | Incompatible_sets
  | Event_error of Event.error
  | Envelope_error of Paengi_envelope.creation_error

val error_to_string : error -> string
val max_entries : int
val max_encoded_bytes : int
val entry_of_verified : object_id:Object_id.t -> Event.verified -> entry
val entry_event_id : entry -> Event.Event_id.t
val entry_object_id : entry -> Object_id.t
val entry_verified_event : entry -> Event.verified
val make : repository_format:string -> entry list -> (t, error) result
val ref_name : t -> string
val observed : t -> Event.ref_state
val entries : t -> link list
val link_event_id : link -> Event.Event_id.t
val link_object_id : link -> Object_id.t
val payload : t -> (Paengi_encoding.t, error) result
val decode_payload : Paengi_encoding.t -> (t, error) result
val envelope : t -> (Paengi_envelope.t, error) result
val union : t -> t -> (t, error) result
