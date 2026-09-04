(** Bounded immutable byte storage for the V4 HTTP relay.

    The relay validates identities and idempotent create semantics but has no V4
    authority, model, package, or working-tree behaviour. *)

type repository
type kind = Object | Manifest | Publication | Bootstrap

type error =
  | Invalid_repository of string
  | Invalid_identifier of string
  | Invalid_cursor of string
  | Invalid_limit of int
  | Invalid_object of string
  | Already_exists_with_different_bytes of string
  | Missing of string
  | Io_error of { path : string; operation : string; message : string }

val error_to_string : error -> string
val is_missing : error -> bool
val is_immutable_conflict : error -> bool
val max_body_bytes : int
val max_page_size : int
val open_repository : root:string -> (repository, error) result

val create :
  repository ->
  project:string ->
  kind:kind ->
  id:string ->
  bytes:string ->
  (unit, error) result
(** Repeating identical content succeeds. A different body for an existing ID
    fails and never overwrites the first immutable body. *)

val get :
  repository ->
  project:string ->
  kind:kind ->
  id:string ->
  (string, error) result

val list_publications :
  repository ->
  project:string ->
  cursor:string option ->
  limit:int ->
  (string list * string option, error) result

module V2 : sig
  (** Relay-local resumable raw-object sessions. They are deliberately outside
      V4's canonical store and history model. *)

  type cleanup = { expired_sessions : int; reclaimed_bytes : int }

  type error =
    | Invalid_expiry
    | Invalid_quota
    | Invalid_session_id of string
    | Session_missing of string
    | Session_binding_mismatch
    | Duplicate_segment_mismatch
    | Corrupt_session of string
    | Session_io_error of {
        path : string;
        operation : string;
        message : string;
      }
    | Transfer_error of Yeokcham_v4_transport.V2.error
    | Relay_error of string
    | Entropy_failure

  val default_expiry_seconds : int64
  val default_project_quota_bytes : int
  val max_project_quota_bytes : int
  val error_to_string : error -> string
  val is_session_missing : error -> bool

  val start_upload :
    repository ->
    now:int64 ->
    project:string ->
    object_id:string ->
    raw_size:int ->
    credential_id:string ->
    expires_in:int64 ->
    project_quota_bytes:int ->
    (Yeokcham_v4_transport.V2.transfer_session, error) result

  val resume_upload :
    repository ->
    now:int64 ->
    project:string ->
    session_id:string ->
    credential_id:string ->
    (Yeokcham_v4_transport.V2.transfer_session, error) result

  val receive_upload_segment :
    repository ->
    now:int64 ->
    project:string ->
    session_id:string ->
    credential_id:string ->
    offset:int ->
    length:int ->
    raw_sha256:string ->
    bytes:string ->
    (Yeokcham_v4_transport.V2.session_progress, error) result

  val complete_upload :
    repository ->
    now:int64 ->
    project:string ->
    session_id:string ->
    credential_id:string ->
    (unit, error) result

  val cleanup_expired : repository -> now:int64 -> (cleanup, error) result
end
