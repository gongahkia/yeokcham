(** A filesystem mailbox transport for authenticated peer-sync closures.

    Relay packages, advertisements, receipts, and staging repositories are
    runtime data. None is a canonical Yeokcham object or ref. *)

module Peer_id = Yeokcham_id.Peer_id
module Sync_node_id = Yeokcham_id.Peer_sync_node_id

type package
type advertisement

type error =
  | Invalid_relay_path of string
  | Invalid_package of string
  | Invalid_advertisement of string
  | Package_too_large of int
  | Signature_verification_failed
  | Repository_format_mismatch
  | Contact_mismatch
  | Destination_mismatch
  | Tracking_mismatch
  | Expired of { issued_at : int64; expires_at : int64; now : int64 }
  | Replay of string
  | Missing_package of string
  | Publication_conflict of string
  | Io_error of string
  | Peer_error of Yeokcham_peer_sync.error
  | Store_error of Yeokcham_store.error

val error_to_string : error -> string
val is_replay_error : error -> bool
val max_package_bytes : int
val max_package_objects : int
val max_advertisement_age_seconds : int64

val make_package :
  source:Yeokcham_store.repository ->
  source_identity:Yeokcham_peer_sync.identity ->
  source_private_key:Mirage_crypto_ec.Ed25519.priv ->
  destination:Yeokcham_peer_sync.identity ->
  tracking_name:string ->
  head:Sync_node_id.t ->
  issued_at:int64 ->
  expires_at:int64 ->
  nonce:string ->
  (package, error) result

val package_id : package -> string
val package_sender : package -> Yeokcham_peer_sync.identity
val package_destination : package -> Peer_id.t
val package_tracking_name : package -> string
val package_head : package -> Sync_node_id.t
val package_payload : package -> (Yeokcham_encoding.t, error) result
val decode_package_payload : Yeokcham_encoding.t -> (package, error) result

val make_advertisement :
  package ->
  private_key:Mirage_crypto_ec.Ed25519.priv ->
  (advertisement, error) result

val advertisement_id : advertisement -> string
val advertisement_package_id : advertisement -> string
val advertisement_sender : advertisement -> Yeokcham_peer_sync.identity
val advertisement_destination : advertisement -> Peer_id.t
val advertisement_tracking_name : advertisement -> string
val advertisement_head : advertisement -> Sync_node_id.t
val advertisement_payload : advertisement -> (Yeokcham_encoding.t, error) result

val decode_advertisement_payload :
  Yeokcham_encoding.t -> (advertisement, error) result

val publish :
  relay:string ->
  package:package ->
  advertisement:advertisement ->
  (unit, error) result
(** Publishes a package and its signed advertisement through two atomically
    published files. Retrying the exact same values is idempotent. *)

val list_advertisements :
  relay:string -> now:int64 -> (advertisement list, error) result
(** Returns valid, currently fresh advertisements only. It does not create
    contacts, update pins, write objects, or alter tracking refs. *)

val import_advertisement :
  destination:Yeokcham_store.repository ->
  contact:Yeokcham_peer_sync.contact ->
  destination_identity:Yeokcham_peer_sync.identity ->
  relay:string ->
  tracking_name:string ->
  now:int64 ->
  advertisement:advertisement ->
  (Yeokcham_peer_sync.direct_sync, error) result
(** Imports one advertised package only when it matches the supplied pinned
    contact and destination identity. The closure is first checked in an
    isolated staging repository. *)
