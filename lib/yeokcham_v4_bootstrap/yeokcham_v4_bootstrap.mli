(** Explicit V4 bootstrap bases.

    A basis is a signed, immutable courier artifact for a new replica. It is
    intentionally separate from ordinary package-manifest-v1 transport: it
    imports verified shared history into a fresh local draft and never imports
    another replica's scratch state, credentials, or mutable transport state. *)

module Model = Yeokcham_v4_model
module Package = Yeokcham_v4_package
module Store = Yeokcham_v4_store
module Trust = Yeokcham_v4_trust

type basis
type verified

type error =
  | Invalid_basis of string
  | Noncanonical_bytes
  | Record_error of Yeokcham_v4_record.error
  | Package_error of Package.error
  | Store_error of Store.error
  | Trust_error of Trust.error
  | Model_error of Model.error
  | Transport_error of Yeokcham_v4_transport.error
  | Envelope_error of Yeokcham_envelope.decode_error

val error_to_string : error -> string
val schema_version : int64
val signature_domain : string

val create :
  source:Yeokcham_store.repository ->
  destination:string ->
  project:Model.project ->
  authority:Trust.authority ->
  revisions:Trust.signed_revision list ->
  authorizations:Trust.authorization list ->
  adoptions:Trust.adoption list ->
  publisher:Trust.device ->
  certificate:string ->
  signing_capability:Trust.signing_capability ->
  (basis * Package.artifact, error) result
(** Creates one directory package with every shared-history object and returns a
    separately signed basis bound to that exact manifest. *)

val encode : basis -> string
val decode : string -> (basis, error) result
val id : basis -> string
val manifest : basis -> string

val verify :
  repository:Trust.Repository_id.t ->
  package:string ->
  bytes:string ->
  (verified, error) result
(** Fully validates a basis and its package in staging. It writes no destination
    object, state head, remote alias, credential, or working-tree path. *)

val authority : verified -> Trust.authority
val root_certificate : verified -> (Trust.certificate, error) result

val verified_id : verified -> string
(** The immutable SHA-256 ID of the canonical basis that was fully verified. *)

val import :
  destination:Yeokcham_store.repository ->
  verified ->
  creator:Model.Device_id.t ->
  username:Model.Username.t ->
  initial_draft:Model.Draft_id.t ->
  title:string ->
  local_certificate:string ->
  (Model.project * Store.collaboration, error) result
(** Copies only previously verified immutable objects, then constructs fresh
    local state from the portable shared projection. Call only from the store's
    initial collaborative bootstrap callback. *)
