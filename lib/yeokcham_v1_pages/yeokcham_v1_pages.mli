type error =
  | Invalid_input of string
  | Integrity of string
  | Store_error of Yeokcham_store.error

val error_to_string : error -> string
val max_page_bytes : int
val max_value_bytes : int

val store :
  Yeokcham_store.repository ->
  namespace:string ->
  (string * string) list ->
  (Yeokcham_store.Stored_object_id.t, error) result
(** Immutable byte-key/value collection. Input order is immaterial; duplicate
    keys refuse. The namespace binds every page, including value chunks. *)

val load :
  Yeokcham_store.repository ->
  namespace:string ->
  Yeokcham_store.Stored_object_id.t ->
  ((string * string) list, error) result

val closure :
  Yeokcham_store.repository ->
  namespace:string ->
  Yeokcham_store.Stored_object_id.t ->
  (Yeokcham_store.Stored_object_id.t list, error) result
(** Both readers bound every page before decoding, verify identities and scope,
    and reconstruct the canonical root without writing objects. No mutable ref,
    history allocation, or working file is changed. *)
