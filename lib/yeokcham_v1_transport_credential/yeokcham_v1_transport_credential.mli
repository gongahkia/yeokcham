(** OS-custodied V1 relay bearer credentials.

    A test token is available only when both documented test environment
    switches are present. Production calls use the Linux Secret Service and
    never return a token in diagnostics. *)

type error = Unavailable | Missing | Rejected | Invalid

val error_to_string : error -> string
val save : remote:string -> token:string -> (unit, error) result
val load : remote:string -> (string, error) result
val native_scope : url:string -> repository:string -> (string, error) result

val load_for_repository :
  url:string -> repository:string -> (string, error) result

val save_for_repository :
  url:string -> repository:string -> token:string -> (unit, error) result
(** Native credentials bind the exact HTTPS endpoint and repository, so equal
    local aliases in different workspaces cannot send another relay's token. *)
