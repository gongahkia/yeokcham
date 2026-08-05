type error =
  | Store_error of Paengi_store.error
  | Event_error of Paengi_ref_event.error
  | Envelope_error of Paengi_envelope.creation_error
  | Unexpected_object_type of {
      expected : Paengi_envelope.object_type;
      actual : Paengi_envelope.object_type;
    }

val error_to_string : error -> string

val ref_state_of_mutable_ref :
  Paengi_store.Mutable_ref.t -> (Paengi_ref_event.ref_state, error) result

val read_ref_state :
  Paengi_store.repository ->
  name:string ->
  (Paengi_ref_event.ref_state option, error) result

val store_event :
  Paengi_store.repository ->
  Paengi_ref_event.t ->
  (Paengi_store.Stored_object_id.t, error) result

val load_event :
  Paengi_store.repository ->
  Paengi_store.Stored_object_id.t ->
  (Paengi_ref_event.t, error) result
