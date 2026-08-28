(** HTTPS relay client using a bounded external TLS implementation.

    The client accepts only HTTPS base URLs and passes bearer credentials via a
    private temporary curl configuration file, never command arguments. *)

type client
type kind = Object | Manifest | Publication

type error =
  | Invalid_url of string
  | Invalid_token
  | Invalid_identifier of string
  | Missing_curl
  | Command_failed of int
  | Unexpected_status of int
  | Response_too_large
  | Invalid_response of string
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
