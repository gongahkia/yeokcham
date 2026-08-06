module Divergence = Paengi_divergence
module Event = Paengi_ref_event
module Object_id = Paengi_store.Stored_object_id

type error =
  | Store_error of Paengi_store.error
  | Divergence_error of Divergence.error
  | Event_error of Event.error
  | Ref_event_store_error of Paengi_ref_event_store.error
  | Unexpected_object_type of {
      expected : Paengi_envelope.object_type;
      actual : Paengi_envelope.object_type;
    }
  | Binding_error of string
  | Event_id_mismatch of Event.Event_id.t
  | Untrusted_event of Event.Event_id.t
  | Cas_retry_exhausted of int

val error_to_string : error -> string
val max_cas_retries : int
val binding_components : ref_name:string -> string list
val encode_binding : Object_id.t -> string
val decode_binding : string -> (Object_id.t, error) result

val store_set :
  Paengi_store.repository -> Divergence.t -> (Object_id.t, error) result

val load_set :
  Paengi_store.repository -> Object_id.t -> (Divergence.t, error) result

val load_published :
  Paengi_store.repository ->
  trusted_keys:Event.trusted_key list ->
  ref_name:string ->
  (Divergence.t option, error) result

val publish :
  Paengi_store.repository ->
  trusted_keys:Event.trusted_key list ->
  Divergence.entry list ->
  (Object_id.t, error) result
