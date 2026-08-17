(** Authenticated peer-sync primitives. These records are deliberately separate
    from scratch, capsule, workspace, and release history. *)

module Peer_id = Yeokcham_id.Peer_id
module Contact_id = Yeokcham_id.Peer_contact_id

type identity
type contact

type endpoint =
  | Local_path of string
  | Ssh of { target : string; root : string }
  | Relay of string

type unsigned_session
type session_proof
type sync_node
type sync_conflict

type reconciliation =
  | Fast_forward of sync_node
  | Already_current of sync_node
  | Merged of sync_node
  | Conflict of sync_conflict

type direct_sync =
  | Tracking_advanced of sync_node
  | Tracking_already_current of sync_node
  | Tracking_diverged of {
      current : Yeokcham_id.Peer_sync_node_id.t;
      received : sync_node;
    }

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
  | Invalid_sync_node of string
  | Invalid_tracking_name of string
  | Tracking_ref_conflict of string
  | No_common_ancestor
  | Exchange_error of Yeokcham_exchange_store.error
  | Snapshot_error of Yeokcham_snapshot.error
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
  Yeokcham_store.repository ->
  identity ->
  (Yeokcham_store.Stored_object_id.t, error) result

val load_identity :
  Yeokcham_store.repository -> Peer_id.t -> (identity, error) result

val contact_id : contact -> Contact_id.t
val contact_name : contact -> string
val contact_identity : contact -> identity
val contact_endpoints : contact -> endpoint list

val make_contact :
  name:string ->
  identity:identity ->
  endpoints:endpoint list ->
  (contact, error) result

val contact_payload : contact -> (Yeokcham_encoding.t, error) result
val decode_contact_payload : Yeokcham_encoding.t -> (contact, error) result

val store_contact :
  Yeokcham_store.repository ->
  contact ->
  (Yeokcham_store.Stored_object_id.t, error) result

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

val decode_session_proof_payload :
  Yeokcham_encoding.t -> (session_proof, error) result

val ssh_transcript :
  tracking_name:string ->
  head:Yeokcham_id.Peer_sync_node_id.t ->
  (string, error) result

val ssh_session_id :
  session_proof -> (Yeokcham_exchange.session_id, error) result

val sync_node_id : sync_node -> Yeokcham_id.Peer_sync_node_id.t
val sync_node_author : sync_node -> Peer_id.t
val sync_node_snapshot : sync_node -> Yeokcham_snapshot.Snapshot.id
val sync_node_parents : sync_node -> Yeokcham_id.Peer_sync_node_id.t list

val make_sync_node :
  author:identity ->
  private_key:Mirage_crypto_ec.Ed25519.priv ->
  snapshot:Yeokcham_snapshot.Snapshot.id ->
  parents:Yeokcham_id.Peer_sync_node_id.t list ->
  (sync_node, error) result

val sync_node_payload : sync_node -> (Yeokcham_encoding.t, error) result
val decode_sync_node_payload : Yeokcham_encoding.t -> (sync_node, error) result

val store_sync_node :
  Yeokcham_store.repository ->
  sync_node ->
  (Yeokcham_store.Stored_object_id.t, error) result

val load_sync_node :
  Yeokcham_store.repository ->
  Yeokcham_id.Peer_sync_node_id.t ->
  (sync_node, error) result

val verify_sync_node :
  Yeokcham_store.repository -> sync_node -> (unit, error) result

val tracking_head :
  Yeokcham_store.repository ->
  contact:contact ->
  name:string ->
  (Yeokcham_id.Peer_sync_node_id.t option, error) result

val update_tracking_head :
  Yeokcham_store.repository ->
  contact:contact ->
  name:string ->
  expected:Yeokcham_id.Peer_sync_node_id.t option ->
  Yeokcham_id.Peer_sync_node_id.t ->
  (unit, error) result

val sync_local :
  ?interrupt_after:int ->
  source:Yeokcham_store.repository ->
  destination:Yeokcham_store.repository ->
  contact:contact ->
  destination_identity:identity ->
  source_private_key:Mirage_crypto_ec.Ed25519.priv ->
  nonce:string ->
  transcript:string ->
  tracking_name:string ->
  head:Yeokcham_id.Peer_sync_node_id.t ->
  unit ->
  (Yeokcham_exchange_store.outcome * direct_sync, error) result

val verify_sync_snapshot_closure :
  Yeokcham_store.repository ->
  Yeokcham_snapshot.Snapshot.id ->
  (unit, error) result

val advance_tracking :
  Yeokcham_store.repository ->
  contact:contact ->
  tracking_name:string ->
  head:Yeokcham_id.Peer_sync_node_id.t ->
  (direct_sync, error) result

val sync_transfer_closure :
  Yeokcham_store.repository ->
  Yeokcham_id.Peer_sync_node_id.t ->
  ( Yeokcham_store.Stored_object_id.t list * Yeokcham_store.Stored_object_id.t,
    error )
  result

val reconcile :
  Yeokcham_store.repository ->
  author:identity ->
  private_key:Mirage_crypto_ec.Ed25519.priv ->
  local:Yeokcham_id.Peer_sync_node_id.t ->
  remote:Yeokcham_id.Peer_sync_node_id.t ->
  (reconciliation, error) result

val conflict_id : sync_conflict -> Yeokcham_id.Peer_sync_conflict_id.t
val conflict_paths : sync_conflict -> string list list
val conflict_base : sync_conflict -> Yeokcham_id.Peer_sync_node_id.t
val conflict_local : sync_conflict -> Yeokcham_id.Peer_sync_node_id.t
val conflict_remote : sync_conflict -> Yeokcham_id.Peer_sync_node_id.t

val store_sync_conflict :
  Yeokcham_store.repository ->
  sync_conflict ->
  (Yeokcham_store.Stored_object_id.t, error) result
