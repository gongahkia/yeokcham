module Device_id = Paengi_id.Device_id
module Object_id = Paengi_store.Stored_object_id

type t
type signing_capability
type generated
type registry_entry
type registry

type resolution =
  | Device_resolved of { device_id : Device_id.t; object_id : Object_id.t }
  | Device_unmapped of Paengi_ref_event.signer_key_id
  | Device_ambiguous of {
      signer_key_id : Paengi_ref_event.signer_key_id;
      device_ids : Device_id.t list;
    }

type error =
  | Invalid_device_id of int
  | Invalid_public_key of int
  | Unsupported_algorithm of string
  | Unsupported_mandatory_features of int64
  | Unsupported_schema_version of int64
  | Invalid_identity of string
  | Invalid_payload of string
  | Entropy_failure of string
  | Registry_too_large of int
  | Invalid_registry of string
  | Object_id_mismatch of { expected : Object_id.t; actual : Object_id.t }
  | Event_error of Paengi_ref_event.error
  | Envelope_error of Paengi_envelope.creation_error

val error_to_string : error -> string
val resolution_to_string : resolution -> string
val algorithm : string
val max_registry_entries : int
val device_id_of_bytes : string -> (Device_id.t, error) result
val device_id_to_bytes : Device_id.t -> string
val signer_key_id_to_hex : Paengi_ref_event.signer_key_id -> string

val make :
  device_id:Device_id.t ->
  public_key:string ->
  mandatory_features:int64 ->
  (t, error) result

val make_generated :
  device_id:Device_id.t ->
  private_key:Mirage_crypto_ec.Ed25519.priv ->
  mandatory_features:int64 ->
  (generated, error) result

val generate : unit -> (generated, error) result
val generated_identity : generated -> t
val generated_signing_capability : generated -> signing_capability
val signing_private_key : signing_capability -> Mirage_crypto_ec.Ed25519.priv
val device_id : t -> Device_id.t
val signer_key_id : t -> Paengi_ref_event.signer_key_id
val public_key : t -> string
val mandatory_features : t -> int64
val identity_equal : t -> t -> bool
val identity_payload : t -> (Paengi_encoding.t, error) result
val decode_identity_payload : Paengi_encoding.t -> (t, error) result
val identity_envelope : t -> (Paengi_envelope.t, error) result
val stored_object_id : t -> (Object_id.t, error) result

val registry_entry :
  identity:t -> object_id:Object_id.t -> (registry_entry, error) result

val make_registry : registry_entry list -> (registry, error) result
val resolve_verified : registry -> Paengi_ref_event.verified -> resolution
