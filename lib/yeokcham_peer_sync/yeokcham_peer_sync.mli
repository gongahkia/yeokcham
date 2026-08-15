(** Authenticated peer-sync primitives.  These records are deliberately
    separate from scratch, capsule, workspace, and release history. *)

module Peer_id = Yeokcham_id.Peer_id
module Contact_id = Yeokcham_id.Peer_contact_id

type identity
type contact
type endpoint = Local_path of string | Ssh of { target : string; root : string } | Relay of string
type unsigned_session
type session_proof

type error =
  | Invalid_peer_id of int
  | Invalid_public_key of int
  | Invalid_private_key of string
  | Invalid_signature of int
  | Invalid_nonce of int
  | Invalid_name of string
  | Invalid_endpoint of string
  | Duplicate_endpoint
  | Invalid_repository_format
  | Repository_format_mismatch
  | Identity_mismatch
  | Contact_mismatch
  | Signature_verification_failed
  | Entropy_failure of string
  | Unsupported_schema_version of int64
  | Invalid_payload of string
  | Envelope_error of Yeokcham_envelope.creation_error
  | Store_error of Yeokcham_store.error
  | Binding_error of string
  | Unexpected_object_type of {
      expected : Yeokcham_envelope.object_type;
      actual : Yeokcham_envelope.object_type;
    }

val error_to_string : error -> string
val algorithm : string
val max_endpoints : int
val nonce_bytes : int

val peer_id : identity -> Peer_id.t
val public_key : identity -> string
val identity_equal : identity -> identity -> bool
val make_identity : public_key:string -> (identity, error) result
val generate : unit -> (identity * Mirage_crypto_ec.Ed25519.priv, error) result

val identity_payload : identity -> (Yeokcham_encoding.t, error) result
val decode_identity_payload : Yeokcham_encoding.t -> (identity, error) result
val store_identity :
  Yeokcham_store.repository -> identity -> (Yeokcham_store.Stored_object_id.t, error) result
val load_identity :
  Yeokcham_store.repository -> Peer_id.t -> (identity, error) result

val contact_id : contact -> Contact_id.t
val contact_name : contact -> string
val contact_identity : contact -> identity
val contact_endpoints : contact -> endpoint list
val make_contact :
  name:string -> identity:identity -> endpoints:endpoint list -> (contact, error) result
val contact_payload : contact -> (Yeokcham_encoding.t, error) result
val decode_contact_payload : Yeokcham_encoding.t -> (contact, error) result
val store_contact :
  Yeokcham_store.repository -> contact -> (Yeokcham_store.Stored_object_id.t, error) result
val load_contact :
  Yeokcham_store.repository -> Contact_id.t -> (contact, error) result

val make_unsigned_session :
  repository_format:string ->
  initiator:identity ->
  responder:identity ->
  nonce:string ->
  transcript:string ->
  (unsigned_session, error) result
val unsigned_session_nonce : unsigned_session -> string
val unsigned_session_initiator : unsigned_session -> Peer_id.t
val unsigned_session_responder : unsigned_session -> Peer_id.t
val session_signing_bytes : unsigned_session -> (string, error) result
val sign_session :
  unsigned_session ->
  private_key:Mirage_crypto_ec.Ed25519.priv ->
  (session_proof, error) result
val verify_session :
  repository_format:string ->
  expected_signer:contact ->
  expected_initiator:Peer_id.t ->
  expected_responder:Peer_id.t ->
  expected_nonce:string ->
  expected_transcript:string ->
  session_proof ->
  (unit, error) result
val session_proof_payload : session_proof -> (Yeokcham_encoding.t, error) result
val decode_session_proof_payload : Yeokcham_encoding.t -> (session_proof, error) result
