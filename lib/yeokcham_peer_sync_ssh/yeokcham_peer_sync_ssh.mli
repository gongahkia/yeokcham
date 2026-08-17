(** Noncanonical OpenSSH transport for an authenticated peer-sync graph. The
    remote command is fixed; repository and graph values travel only in framed
    protocol data. *)

module Peer_id = Yeokcham_id.Peer_id
module Sync_node_id = Yeokcham_id.Peer_sync_node_id

type request
type response

type error =
  | Invalid_request of string
  | Invalid_response of string
  | Protocol_error of Yeokcham_exchange.error
  | Exchange_error of Yeokcham_exchange_store.error
  | Peer_error of Yeokcham_peer_sync.error
  | Remote_error of { code : string; detail : string }
  | Transport_error of string

val error_to_string : error -> string
val max_handshake_bytes : int
val capability_path : root:string -> string

val make_request :
  remote_root:string ->
  source:Peer_id.t ->
  destination:Yeokcham_peer_sync.identity ->
  nonce:string ->
  tracking_name:string ->
  head:Sync_node_id.t ->
  (request, error) result

val request_remote_root : request -> string
val request_source : request -> Peer_id.t
val request_destination : request -> Yeokcham_peer_sync.identity
val request_nonce : request -> string
val request_tracking_name : request -> string
val request_head : request -> Sync_node_id.t
val request_payload : request -> (Yeokcham_encoding.t, error) result
val decode_request_payload : Yeokcham_encoding.t -> (request, error) result
val write_request : out_channel -> request -> (unit, error) result
val read_request : in_channel -> (request, error) result

val write_remote_error :
  out_channel -> code:string -> detail:string -> (unit, error) result

val ssh_arguments :
  target:string ->
  known_hosts:string ->
  ?ssh_config:string ->
  unit ->
  (string array, error) result

val serve_stream :
  source:Yeokcham_store.repository ->
  source_identity:Yeokcham_peer_sync.identity ->
  source_private_key:Mirage_crypto_ec.Ed25519.priv ->
  request:request ->
  input:in_channel ->
  output:out_channel ->
  (unit, error) result

val sync_stream :
  ?interrupt_after:int ->
  destination:Yeokcham_store.repository ->
  contact:Yeokcham_peer_sync.contact ->
  destination_identity:Yeokcham_peer_sync.identity ->
  request:request ->
  input:in_channel ->
  output:out_channel ->
  unit ->
  ( Yeokcham_exchange_store.outcome * Yeokcham_peer_sync.direct_sync,
    error )
  result

val sync_ssh :
  ?interrupt_after:int ->
  destination:Yeokcham_store.repository ->
  contact:Yeokcham_peer_sync.contact ->
  destination_identity:Yeokcham_peer_sync.identity ->
  known_hosts:string ->
  ?ssh_config:string ->
  nonce:string ->
  tracking_name:string ->
  head:Sync_node_id.t ->
  unit ->
  ( Yeokcham_exchange_store.outcome * Yeokcham_peer_sync.direct_sync,
    error )
  result
