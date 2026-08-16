module Object_id = Yeokcham_store.Stored_object_id

type error =
  | Protocol_error of Yeokcham_exchange.error
  | Source_store_error of Yeokcham_store.error
  | Destination_store_error of Yeokcham_store.error
  | Envelope_error of Yeokcham_envelope.decode_error
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
  Yeokcham_store.repository ->
  session_id:Yeokcham_exchange.session_id ->
  sequence:int64 ->
  Object_id.t ->
  (Yeokcham_exchange.message, error) result

val receive_object :
  Yeokcham_store.repository ->
  Yeokcham_exchange.receiver ->
  Yeokcham_exchange.message ->
  (Yeokcham_exchange.receiver * Object_id.t, error) result

val transfer :
  ?interrupt_after:int ->
  ?on_progress:(completed:int -> total:int -> unit) ->
  ?object_byte_budget:int ->
  source:Yeokcham_store.repository ->
  destination:Yeokcham_store.repository ->
  session_id:Yeokcham_exchange.session_id ->
  object_ids:Object_id.t list ->
  unit ->
  (outcome, error) result
