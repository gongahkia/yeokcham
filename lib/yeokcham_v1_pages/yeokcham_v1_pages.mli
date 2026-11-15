type error =
  | Invalid_input of string
  | Integrity of string
  | Store_error of Yeokcham_store.error

val error_to_string : error -> string
val max_page_bytes : int
val max_value_bytes : int

val page_references :
  namespace:string ->
  expected:Yeokcham_store.Stored_object_id.t ->
  string ->
  (Yeokcham_store.Stored_object_id.t list, error) result
(** Bounded structural references from one identity-checked, scoped page. Does
    not fetch children or prove complete canonical collection/value boundaries;
    use [load]/[load_bounded] after fetching the closure. Transfer callers must
    bound their graph traversal and reject repeated collection tree pages. *)

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

val load_bounded :
  Yeokcham_store.repository ->
  namespace:string ->
  max_rows:int ->
  max_value_bytes:int ->
  max_total_value_bytes:int ->
  Yeokcham_store.Stored_object_id.t ->
  ((string * string) list, error) result
(** Reject excessive rows before loading their values and excessive values
    before allocating their reconstruction buffer. Canonical format is
    unchanged. *)
