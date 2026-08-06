module Object_id = Yeokcham_store.Stored_object_id

type server
type endpoint

type error =
  | Invalid_endpoint of int
  | Transport_error of string
  | Timeout of string
  | Header_too_large of int
  | Body_too_large of int
  | Malformed_http of string
  | Unsupported_method of string
  | Unsupported_path of string
  | Unsupported_content_type of string option
  | Protocol_error of Yeokcham_exchange.error
  | Adapter_error of Yeokcham_exchange_store.error
  | Session_in_progress
  | Unexpected_client_message of string
  | Unexpected_response of string
  | Peer_rejected of { status : int; detail : string }
  | Interrupted_after of int
  | Invalid_transfer_input of string

type outcome = {
  offered : int;
  requested : int;
  transferred : Object_id.t list;
}

val max_header_bytes : int
val max_body_bytes : int
val io_timeout_seconds : float
val error_to_string : error -> string

val create_server :
  ?object_byte_budget:int -> Yeokcham_store.repository -> (server, error) result

val handle : server -> string -> (server * string, error) result
val serve_once : server -> Unix.file_descr -> (server, error) result
val endpoint : address:Unix.inet_addr -> port:int -> (endpoint, error) result
val request : endpoint -> string -> (string, error) result

val transfer_with :
  ?interrupt_after:int ->
  source:Yeokcham_store.repository ->
  send:(string -> (string, error) result) ->
  session_id:Yeokcham_exchange.session_id ->
  object_ids:Object_id.t list ->
  unit ->
  (outcome, error) result

val transfer :
  ?interrupt_after:int ->
  source:Yeokcham_store.repository ->
  endpoint:endpoint ->
  session_id:Yeokcham_exchange.session_id ->
  object_ids:Object_id.t list ->
  unit ->
  (outcome, error) result
