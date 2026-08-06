module Event_id = Yeokcham_id.Ref_event_id
module Object_id = Yeokcham_store.Stored_object_id

type signer_key_id
type ref_state
type unsigned
type t
type verified
type trusted_key = { key_id : signer_key_id; public_key : string }
type verification = Verified | Untrusted

type evaluation =
  | Ready
  | Replayed of Event_id.t
  | Stale_observed_ref
  | Missing_predecessor of Event_id.t
  | Signer_sequence_reused of int64
  | Divergent of Event_id.t list

type error =
  | Invalid_ref_name of string
  | Invalid_generation of int64
  | Invalid_proposed_generation of { observed : int64; proposed : int64 }
  | Invalid_signer_sequence of int64
  | Invalid_signer_key_id of int
  | Invalid_event_id of int
  | Invalid_public_key of int
  | Invalid_signature of int
  | Unsupported_algorithm of string
  | Unsupported_mandatory_features of int64
  | Invalid_repository_format
  | Repository_format_mismatch
  | Invalid_identity of string
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Trust_map_too_large of int
  | Invalid_trust_map of string
  | Signature_verification_failed
  | Cryptographic_failure of string
  | Evaluation_too_large of int

val error_to_string : error -> string
val evaluation_to_string : evaluation -> string
val verification_to_string : verification -> string
val max_trusted_keys : int
val max_candidate_events : int
val max_total_event_bytes : int
val algorithm : string
val signer_key_id_of_bytes : string -> (signer_key_id, error) result
val signer_key_id_to_bytes : signer_key_id -> string
val signer_key_id_of_public_key : string -> (signer_key_id, error) result
val signer_key_id_compare : signer_key_id -> signer_key_id -> int
val event_id_of_bytes : string -> (Event_id.t, error) result
val event_id_to_bytes : Event_id.t -> string

val make_ref_state :
  generation:int64 -> target:Object_id.t option -> (ref_state, error) result

val ref_state_generation : ref_state -> int64
val ref_state_target : ref_state -> Object_id.t option
val ref_state_equal : ref_state -> ref_state -> bool

val make_unsigned :
  repository_format:string ->
  ref_name:string ->
  signer_key_id:signer_key_id ->
  signer_sequence:int64 ->
  previous:Event_id.t option ->
  observed:ref_state ->
  proposed:ref_state ->
  mandatory_features:int64 ->
  (unsigned, error) result

val unsigned_event_id : unsigned -> Event_id.t
val unsigned_repository_format_digest : unsigned -> string
val unsigned_ref_name : unsigned -> string
val unsigned_signer_key_id : unsigned -> signer_key_id
val unsigned_signer_sequence : unsigned -> int64
val unsigned_previous : unsigned -> Event_id.t option
val unsigned_observed : unsigned -> ref_state
val unsigned_proposed : unsigned -> ref_state
val unsigned_payload : unsigned -> (Yeokcham_encoding.t, error) result
val signing_bytes : unsigned -> (string, error) result

val make :
  unsigned:unsigned -> algorithm:string -> signature:string -> (t, error) result

val event_unsigned : t -> unsigned
val event_algorithm : t -> string
val event_signature : t -> string
val event_payload : t -> (Yeokcham_encoding.t, error) result
val decode_event_payload : Yeokcham_encoding.t -> (t, error) result

val verify :
  repository_format:string ->
  trusted_keys:trusted_key list ->
  t ->
  (verification, error) result

val verify_for_device :
  repository_format:string ->
  trusted_keys:trusted_key list ->
  t ->
  (verified option, error) result

val verified_event : verified -> t

val evaluate_verified :
  current:ref_state -> known:t list -> t -> (evaluation, error) result
