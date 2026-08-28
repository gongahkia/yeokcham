(** Bounded immutable byte storage for the V4 HTTP relay.

    The relay validates identities and idempotent create semantics but has no V4
    authority, model, package, or working-tree behaviour. *)

type repository
type kind = Object | Manifest | Publication

type error =
  | Invalid_repository of string
  | Invalid_identifier of string
  | Invalid_cursor of string
  | Invalid_limit of int
  | Invalid_object of string
  | Already_exists_with_different_bytes of string
  | Missing of string
  | Io_error of { path : string; operation : string; message : string }

val error_to_string : error -> string
val is_missing : error -> bool
val is_immutable_conflict : error -> bool
val max_body_bytes : int
val max_page_size : int
val open_repository : root:string -> (repository, error) result

val create :
  repository ->
  project:string ->
  kind:kind ->
  id:string ->
  bytes:string ->
  (unit, error) result
(** Repeating identical content succeeds. A different body for an existing ID
    fails and never overwrites the first immutable body. *)

val get :
  repository ->
  project:string ->
  kind:kind ->
  id:string ->
  (string, error) result

val list_publications :
  repository ->
  project:string ->
  cursor:string option ->
  limit:int ->
  (string list * string option, error) result
