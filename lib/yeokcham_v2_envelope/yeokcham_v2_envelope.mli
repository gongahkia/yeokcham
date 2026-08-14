type key
type nonce
type t
type context

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
  | Invalid_repository_context_length of int
  | Invalid_context_epoch of int64
  | Invalid_object_kind of int64
  | Context_required
  | Context_mismatch
  | Authentication_failed
  | Cryptographic_failure of string

val error_to_string : error -> string
val algorithm : string
val current_schema_version : int64
val bound_schema_version : int64
val supported_mandatory_features : int64
val max_plaintext_bytes : int
val max_ciphertext_bytes : int
val key_of_bytes : string -> (key, error) result
val key_to_bytes : key -> string
val nonce_of_bytes : string -> (nonce, error) result
val nonce_to_bytes : nonce -> string

val make_context :
  repository_id:string -> epoch:int64 -> object_kind:int64 -> (context, error) result
(** Constructs authenticated context for one repository object. The context is
    never encoded in cleartext in a bound envelope. *)

val seal :
  key:key ->
  nonce:nonce ->
  mandatory_features:int64 ->
  string ->
  (t, error) result

val seal_bound :
  key:key ->
  nonce:nonce ->
  mandatory_features:int64 ->
  context:context ->
  string ->
  (t, error) result
(** Encrypts one repository object under a key derived from [context] and an
    opaque per-object commitment. *)

val encode : t -> string
val header_bytes : t -> string
val mandatory_features : t -> int64
val decode : string -> (t, error) result
val open_envelope : key:key -> t -> (string, error) result

val open_bound :
  key:key -> context:context -> t -> (string, error) result
(** Authenticates the supplied repository, epoch, and type context before any
    plaintext is returned. *)

val is_bound : t -> bool
