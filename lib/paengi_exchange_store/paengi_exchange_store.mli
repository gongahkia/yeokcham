module Object_id = Paengi_store.Stored_object_id

type error =
  | Protocol_error of Paengi_exchange.error
  | Source_store_error of Paengi_store.error
  | Destination_store_error of Paengi_store.error
  | Envelope_error of Paengi_envelope.decode_error
  | Noncanonical_envelope_bytes
  | Object_identity_mismatch of { expected : Object_id.t; actual : Object_id.t }
  | Interrupted_after of int
  | Invalid_transfer_input of string

type outcome = {
  offered : int;
  requested : int;
  transferred : Object_id.t list;
}

val error_to_string : error -> string

val object_message :
  Paengi_store.repository ->
  session_id:Paengi_exchange.session_id ->
  sequence:int64 ->
  Object_id.t ->
  (Paengi_exchange.message, error) result

val receive_object :
  Paengi_store.repository ->
  Paengi_exchange.receiver ->
  Paengi_exchange.message ->
  (Paengi_exchange.receiver * Object_id.t, error) result

val transfer :
  ?interrupt_after:int ->
  ?object_byte_budget:int ->
  source:Paengi_store.repository ->
  destination:Paengi_store.repository ->
  session_id:Paengi_exchange.session_id ->
  object_ids:Object_id.t list ->
  unit ->
  (outcome, error) result
