(** OS-custodied V4 relay bearer credentials.

    A test token is available only when both documented test environment
    switches are present. Production calls use the Linux Secret Service and
    never return a token in diagnostics. *)

type error = Unavailable | Missing | Rejected | Invalid

val error_to_string : error -> string
val save : remote:string -> token:string -> (unit, error) result
val load : remote:string -> (string, error) result
