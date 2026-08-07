type key
type nonce
type t

type error =
  | Invalid_key_length of int
  | Invalid_nonce_length of int
  | Plaintext_too_large of int
  | Ciphertext_too_large of int
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Unsupported_algorithm of string
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Authentication_failed
  | Cryptographic_failure of string

val error_to_string : error -> string
val algorithm : string
val current_schema_version : int64
val supported_mandatory_features : int64
val max_plaintext_bytes : int
val max_ciphertext_bytes : int
val key_of_bytes : string -> (key, error) result
val key_to_bytes : key -> string
val nonce_of_bytes : string -> (nonce, error) result
val nonce_to_bytes : nonce -> string

val seal :
  key:key ->
  nonce:nonce ->
  mandatory_features:int64 ->
  string ->
  (t, error) result

val encode : t -> string
val header_bytes : t -> string
val decode : string -> (t, error) result
val open_envelope : key:key -> t -> (string, error) result
