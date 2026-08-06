module Object_id = Yeokcham_store.Stored_object_id

type error =
  | Store_error of Yeokcham_store.error
  | Bundle_error of Yeokcham_bundle.error
  | Entropy_failure of string

val error_to_string : error -> string

val export :
  Yeokcham_store.repository ->
  key:Yeokcham_bundle.key ->
  object_ids:Object_id.t list ->
  (string, error) result

val import :
  Yeokcham_store.repository ->
  key:Yeokcham_bundle.key ->
  string ->
  (Object_id.t list, error) result
