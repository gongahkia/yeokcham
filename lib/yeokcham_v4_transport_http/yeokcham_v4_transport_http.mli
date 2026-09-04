(** HTTPS relay client using a bounded external TLS implementation.

    The client accepts only HTTPS base URLs and passes bearer credentials via a
    private temporary curl configuration file, never command arguments. *)

type client
type kind = Object | Manifest | Publication | Bootstrap

type error =
  | Invalid_url of string
  | Invalid_token
  | Invalid_identifier of string
  | Missing_curl
  | Command_failed of int
  | Unexpected_status of int
  | Response_too_large
  | Invalid_response of string
  | Test_interrupted_upload
  | Io_error of { path : string; operation : string; message : string }

val error_to_string : error -> string
val create : url:string -> token:string -> (client, error) result

val get :
  client -> project:string -> kind:kind -> id:string -> (string, error) result

val put :
  client ->
  project:string ->
  kind:kind ->
  id:string ->
  bytes:string ->
  (unit, error) result

val list_publications :
  client ->
  project:string ->
  cursor:string option ->
  limit:int ->
  (string list * string option, error) result

module V2 : sig
  type error =
    | V2_unavailable
    | Http_error of string
    | Protocol_error of string
    | Transfer_error of Yeokcham_v4_transport.V2.error
    | Wire_error of Yeokcham_v4_transport.V2_wire.error

  val error_to_string : error -> string

  val negotiate_upload :
    client ->
    project:string ->
    sender:Yeokcham_v4_transport.V2.capability ->
    offered:string list ->
    (Yeokcham_v4_transport.V2.capability, error) result

  val start_upload :
    client ->
    project:string ->
    object_id:string ->
    raw_size:int ->
    expires_in:int ->
    (Yeokcham_v4_transport.V2.transfer_session, error) result

  val resume_upload :
    client ->
    project:string ->
    session_id:string ->
    (Yeokcham_v4_transport.V2.transfer_session, error) result

  val put_segment :
    client ->
    project:string ->
    session_id:string ->
    offset:int ->
    raw:string ->
    (unit, error) result

  val complete_upload :
    client -> project:string -> session_id:string -> (unit, error) result

  val get_segment :
    client ->
    project:string ->
    object_id:string ->
    offset:int ->
    length:int ->
    (string, error) result
end
