module Object_id = Paengi_store.Stored_object_id

type key
type nonce
type entry
type plaintext
type t

type error =
  | Invalid_key_length of int
  | Invalid_nonce_length of int
  | Invalid_repository_format
  | Repository_format_mismatch
  | Invalid_entry_count of int
  | Duplicate_object_id of Object_id.t
  | Object_identity_mismatch of { expected : Object_id.t; actual : Object_id.t }
  | Plaintext_too_large of int
  | Ciphertext_too_large of int
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Unsupported_algorithm of string
  | Unsupported_mandatory_features of int64
  | Authentication_failed
  | Envelope_error of Paengi_envelope.decode_error
  | Cryptographic_failure of string

val error_to_string : error -> string
val algorithm : string
val max_entries : int
val max_plaintext_bytes : int
val max_ciphertext_bytes : int
val key_of_bytes : string -> (key, error) result
val nonce_of_bytes : string -> (nonce, error) result
val nonce_to_bytes : nonce -> string

val entry_of_envelope :
  object_id:Object_id.t -> Paengi_envelope.t -> (entry, error) result

val entry_object_id : entry -> Object_id.t
val entry_envelope : entry -> Paengi_envelope.t
val make_plaintext : entry list -> (plaintext, error) result
val plaintext_entries : plaintext -> entry list
val plaintext_bytes : plaintext -> string
val decode_plaintext : string -> (plaintext, error) result

val seal :
  repository_format:string ->
  key:key ->
  nonce:nonce ->
  plaintext ->
  (t, error) result

val encode : t -> string
val header_bytes : t -> string
val decode : string -> (t, error) result

val open_bundle :
  repository_format:string -> key:key -> t -> (plaintext, error) result
