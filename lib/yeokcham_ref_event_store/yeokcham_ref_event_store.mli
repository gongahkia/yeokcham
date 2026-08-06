type error =
  | Store_error of Yeokcham_store.error
  | Event_error of Yeokcham_ref_event.error
  | Envelope_error of Yeokcham_envelope.creation_error
  | Unexpected_object_type of {
      expected : Yeokcham_envelope.object_type;
      actual : Yeokcham_envelope.object_type;
    }

val error_to_string : error -> string

val ref_state_of_mutable_ref :
  Yeokcham_store.Mutable_ref.t -> (Yeokcham_ref_event.ref_state, error) result

val read_ref_state :
  Yeokcham_store.repository ->
  name:string ->
  (Yeokcham_ref_event.ref_state option, error) result

val store_event :
  Yeokcham_store.repository ->
  Yeokcham_ref_event.t ->
  (Yeokcham_store.Stored_object_id.t, error) result

val load_event :
  Yeokcham_store.repository ->
  Yeokcham_store.Stored_object_id.t ->
  (Yeokcham_ref_event.t, error) result
