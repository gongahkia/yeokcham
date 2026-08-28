(** Canonical V4 relay-publication records and local transport bookkeeping.

    A publication is a signed courier statement. It is not a revision, authority
    action, decision, or delivery record. Network and filesystem adapters use
    this pure module before handing package bytes to the V4 package verifier. *)

module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust

type publication
type publication_reference
type remote_state
type local_state

type error =
  | Invalid_digest of string
  | Invalid_remote_name of string
  | Invalid_publication of string
  | Noncanonical_bytes
  | Duplicate_publication of string
  | Missing_feed_parent of string
  | Cross_publisher_parent of string
  | Feed_cycle of string
  | Repository_mismatch
  | Unknown_publisher_certificate
  | Publisher_certificate_mismatch
  | Publisher_not_active
  | Trust_error of Trust.error
  | Encoding_error of Yeokcham_encoding.construction_error
  | Decode_error of Yeokcham_encoding.decode_error

val error_to_string : error -> string
val publication_schema_version : int64
val local_state_schema_version : int64
val sha256 : string -> string
val valid_digest : string -> bool

val create_publication :
  repository:Trust.Repository_id.t ->
  publisher:Trust.device ->
  certificate:string ->
  parents:string list ->
  manifest:string ->
  signing_capability:Trust.signing_capability ->
  (publication, error) result

val publication_id : publication -> string
val publication_repository : publication -> Trust.Repository_id.t
val publication_publisher : publication -> Model.Device_id.t
val publication_certificate : publication -> string
val publication_parents : publication -> string list
val publication_manifest : publication -> string
val encode_publication : publication -> string
val decode_publication : string -> (publication, error) result

val verify_publication :
  authority:Trust.authority -> publication -> (unit, error) result
(** Verifies repository binding, certificate/device consistency, active
    publisher status in at least one current authority head, and signature. *)

val publication_reference : publication -> publication_reference
val reference_id : publication_reference -> string
val reference_publisher : publication_reference -> Model.Device_id.t
val reference_certificate : publication_reference -> string

val validate_feed :
  known:publication_reference list -> publication list -> (unit, error) result
(** Verifies parent availability, publisher continuity, duplicate IDs, and
    acyclicity. A known reference must have been cryptographically verified
    before it is persisted. *)

val empty_local_state : local_state

val remote_state :
  name:string ->
  cursor:string option ->
  known:publication_reference list ->
  announced_manifests:string list ->
  announced_revisions:Model.Revision_id.t list ->
  review_inbox:string list ->
  (remote_state, error) result

val remote_name : remote_state -> string
val remote_cursor : remote_state -> string option
val remote_known_publications : remote_state -> publication_reference list
val remote_announced_manifests : remote_state -> string list
val remote_announced_revisions : remote_state -> Model.Revision_id.t list
val remote_review_inbox : remote_state -> string list
val remotes : local_state -> remote_state list
val find_remote : local_state -> name:string -> remote_state option
val with_remote : local_state -> remote_state -> (local_state, error) result
val remove_remote : local_state -> name:string -> local_state
val encode_local_state : local_state -> (string, error) result
val decode_local_state : string -> (local_state, error) result
