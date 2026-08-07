module Repository_id = Yeokcham_v2_model.Repository_id
module Opaque_object_ref = Yeokcham_v2_model.Opaque_object_ref

type key

type error =
  | Invalid_key_length of int
  | Address_mismatch of {
      expected : Opaque_object_ref.t;
      actual : Opaque_object_ref.t;
    }

val error_to_string : error -> string
val key_of_bytes : string -> (key, error) result
val key_to_bytes : key -> string

val derive :
  repository_id:Repository_id.t ->
  key:key ->
  envelope:Yeokcham_v2_envelope.t ->
  Opaque_object_ref.t

val verify :
  repository_id:Repository_id.t ->
  key:key ->
  address:Opaque_object_ref.t ->
  envelope:Yeokcham_v2_envelope.t ->
  (unit, error) result
