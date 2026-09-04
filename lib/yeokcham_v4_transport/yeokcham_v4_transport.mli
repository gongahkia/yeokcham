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

module V2 : sig
  (** Pure V2 relay-transfer planning. These values describe only raw immutable
      bytes and relay-local sessions; they are not V4 history or state. *)

  type scope = Upload | Download

  type error =
    | Invalid_capability of string
    | Unsupported_protocol
    | Compression_unavailable
    | Invalid_offer of string
    | Invalid_range of { offset : int; length : int }
    | Range_not_offered of { offset : int; length : int }
    | Invalid_session of string
    | Session_expired
    | Session_complete
    | Quota_exceeded
    | Credential_session_limit
    | Transient_network
    | Http_server_error of int
    | Authentication_failure
    | Capability_failure
    | Range_failure
    | Decompression_failure
    | Canonical_bytes_failure
    | Identity_failure

  type capability
  type object_offer
  type missing_set
  type range
  type segment
  type transfer_session
  type session_progress
  type retry = Retry_after_ms of int | Do_not_retry

  val protocol_version : int
  val segment_bytes : int
  val max_raw_object_bytes : int
  val max_missing_objects : int
  val default_parallelism : int
  val max_parallelism : int
  val retry_delays_ms : int list
  val capability_schema_version : int64
  val session_schema_version : int64
  val error_to_string : error -> string

  val capability :
    versions:int list ->
    zstd:bool ->
    max_segment_bytes:int ->
    max_in_flight:int ->
    missing:string list ->
    (capability, error) result

  val intersect_capability :
    sender:capability -> receiver:capability -> (capability, error) result

  val capability_versions : capability -> int list
  val capability_zstd : capability -> bool
  val capability_max_segment_bytes : capability -> int
  val capability_max_in_flight : capability -> int
  val missing_objects : capability -> missing_set
  val missing_ids : missing_set -> string list
  val encode_capability : capability -> (string, error) result
  val decode_capability : string -> (capability, error) result

  val plan_missing :
    offered:string list -> missing_set -> (string list, error) result

  val object_offer :
    project:string ->
    object_id:string ->
    raw_size:int ->
    (object_offer, error) result

  val offer_project : object_offer -> string
  val offer_object_id : object_offer -> string
  val offer_raw_size : object_offer -> int
  val partition : object_offer -> (range list, error) result
  val range_offset : range -> int
  val range_length : range -> int
  val segment : range:range -> raw_sha256:string -> (segment, error) result
  val segment_range : segment -> range
  val segment_raw_sha256 : segment -> string

  val session :
    id:string ->
    offer:object_offer ->
    credential_id:string ->
    scope:scope ->
    expires_at:int64 ->
    quota_bytes:int ->
    credential_session_count:int ->
    (transfer_session, error) result

  val session_progress : transfer_session -> session_progress
  val session_id : transfer_session -> string
  val session_offer : transfer_session -> object_offer
  val session_credential_id : transfer_session -> string
  val session_scope : transfer_session -> scope
  val session_expires_at : transfer_session -> int64
  val progress_ranges : session_progress -> range list
  val progress_complete : session_progress -> bool

  val receive_segment :
    now:int64 ->
    session:transfer_session ->
    segment ->
    (transfer_session, error) result

  val completion_eligible :
    now:int64 -> transfer_session -> (unit, error) result

  val encode_session : transfer_session -> (string, error) result
  val decode_session : string -> (transfer_session, error) result
  val retry : attempt:int -> error -> retry
end
