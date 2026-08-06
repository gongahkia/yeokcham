module Object_id = Paengi_store.Stored_object_id

type error =
  | Store_error of Paengi_store.error
  | Bundle_error of Paengi_bundle.error
  | Entropy_failure of string

val error_to_string : error -> string

val export :
  Paengi_store.repository ->
  key:Paengi_bundle.key ->
  object_ids:Object_id.t list ->
  (string, error) result

val import :
  Paengi_store.repository ->
  key:Paengi_bundle.key ->
  string ->
  (Object_id.t list, error) result
