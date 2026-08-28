(** Minimal bounded HTTP/1.1 listener for the untrusted V4 relay. TLS belongs to
    the operator-managed reverse proxy in front of this listener. *)

type error =
  | Invalid_listen of string
  | Invalid_token_file of string
  | Io_error of { path : string; operation : string; message : string }
  | Relay_error of Yeokcham_v4_relay.error

val error_to_string : error -> string

val serve :
  root:string -> listen:string -> token_file:string -> (unit, error) result
