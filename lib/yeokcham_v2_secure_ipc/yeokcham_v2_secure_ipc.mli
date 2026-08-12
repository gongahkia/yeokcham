(** ADR-069's bounded, local secure-runtime IPC contract.

    The protocol carries no repository object semantics and persists no frame,
    session, payload, or secret. Socket ownership and peer authentication are
    separate adapters. *)

module Model = Yeokcham_v2_model
module Session_id = Model.Secure_runtime_session_id

type capability = Mls | Device_crypto | Mesh
type operation = Mls_operation | Device_crypto_operation | Mesh_operation
type result_kind = Completed | Refused
type hello
type hello_ack
type negotiated
type request
type response
type server

type message =
  | Hello of hello
  | Hello_ack of hello_ack
  | Request of request
  | Response of response

type error =
  | Invalid_session_id of Model.identity_error
  | Invalid_protocol_versions of string
  | Invalid_capabilities of string
  | Invalid_payload_size of int
  | Invalid_sequence of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unsupported_frame_version of int64
  | Unsupported_message_kind of int64
  | Invalid_message of string
  | Frame_too_large of int
  | Noncanonical_message
  | Incompatible_protocol
  | Missing_required_capability of capability
  | Acknowledgement_mismatch of string
  | Session_already_active of Session_id.t
  | Unknown_or_stale_session of Session_id.t
  | Sequence_mismatch of { expected : int64; actual : int64 }
  | Operation_not_negotiated of operation
  | Response_mismatch of string

val error_to_string : error -> string
val protocol_version : int64
val supported_mandatory_features : int64
val max_frame_bytes : int
val max_payload_bytes : int
val capability_to_string : capability -> string
val operation_to_string : operation -> string
val operation_capability : operation -> capability

val make_hello :
  session_id:Session_id.t ->
  supported_versions:int64 list ->
  required_capabilities:capability list ->
  optional_capabilities:capability list ->
  mandatory_features:int64 ->
  (hello, error) result

val make_server :
  supported_versions:int64 list ->
  capabilities:capability list ->
  (server, error) result

val accept_hello : server -> hello -> (server * hello_ack, error) result
val validate_hello_ack : hello:hello -> hello_ack -> (negotiated, error) result

val make_request :
  negotiated:negotiated ->
  sequence:int64 ->
  operation:operation ->
  payload:string ->
  mandatory_features:int64 ->
  (request, error) result

val make_response :
  request:request ->
  result:result_kind ->
  payload:string ->
  mandatory_features:int64 ->
  (response, error) result

val accept_request : server -> request -> (server, error) result
val validate_response : request:request -> response -> (unit, error) result
val encode : message -> string
val decode : string -> (message, error) result

module Transport : sig
  type error =
    | End_of_stream
    | Truncated_frame
    | Oversized_frame of int
    | Io_error of { operation : string; message : string }
    | Protocol_error of string

  val error_to_string : error -> string
  val write : Unix.file_descr -> message -> (unit, error) result
  val read : Unix.file_descr -> (message, error) result
end
