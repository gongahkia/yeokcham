(** V2-030's root-authorized, encrypted MLS invitation lifecycle.

    The repository authority's root is the sole currently modeled invitation
    policy role. An invitation encrypts only a recipient's joined MLS state
    under a caller-held 32-byte invitation secret; the secret is never encoded
    in an invitation or membership event. A successful acceptance reopens and
    reloads that state through the MLS runtime before it records acceptance. *)

module Authority = Yeokcham_v2_authority
module Envelope = Yeokcham_v2_envelope
module Group = Yeokcham_v2_mls_group
module Model = Yeokcham_v2_model
module Runtime = Yeokcham_v2_mls_runtime

type member_invitation
type membership_event
type lifecycle = Open | Revoked | Accepted

type issue = {
  invitation : member_invitation;
  issued_event : membership_event;
  issuer_state : Group.t;
}

type acceptance = {
  recipient_state : Group.t;
  accepted_event : membership_event;
}

type error =
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Invalid_time_range
  | Invitation_expired of { now : int64; expires_at : int64 }
  | Unauthorized_issuer
  | Authority_error of Authority.error
  | Group_error of Group.error
  | Envelope_error of Envelope.error
  | Signature_verification_failed
  | Identity_mismatch of string
  | Noncanonical_record
  | Missing_issued_event
  | Duplicate_issued_event
  | Replayed_invitation
  | Revoked_invitation
  | Entropy_failure

val error_to_string : error -> string
val current_schema_version : int64
val supported_mandatory_features : int64
val invitation_key : unit -> (Envelope.key, error) result
val encode_invitation : member_invitation -> string

val decode_invitation :
  authority:Authority.repository_authority ->
  string ->
  (member_invitation, error) result

val encode_membership_event : membership_event -> string

val decode_membership_event :
  authority:Authority.repository_authority ->
  string ->
  (membership_event, error) result

val invitation_id : member_invitation -> Model.Mls_invitation_id.t
val invitation_repository_id : member_invitation -> Model.Repository_id.t
val invitation_group_id : member_invitation -> Model.Mls_group_id.t
val invitation_recipient_device_id : member_invitation -> Model.Device_id.t
val invitation_expires_at : member_invitation -> int64
val membership_event_id : membership_event -> Model.Mls_invitation_id.t

val membership_event_invitation_id :
  membership_event -> Model.Mls_invitation_id.t

val issue :
  runtime:Runtime.configuration ->
  authority:Authority.repository_authority ->
  root:Authority.root_signing_capability ->
  issuer_state:Group.t ->
  recipient_device_id:Model.Device_id.t ->
  issued_at:int64 ->
  expires_at:int64 ->
  invitation_key:Envelope.key ->
  invitation_nonce:Envelope.nonce ->
  event_nonce:Envelope.nonce ->
  (issue, error) result
(** Performs the MLS add/commit/join, then root-signs an encrypted invitation
    and its encrypted issued event. The returned [issuer_state] must replace the
    issuer's previous durable MLS snapshot through a later state adapter. *)

val lifecycle :
  authority:Authority.repository_authority ->
  invitation:member_invitation ->
  membership_event list ->
  (lifecycle, error) result

val revoke :
  authority:Authority.repository_authority ->
  root:Authority.root_signing_capability ->
  invitation:member_invitation ->
  history:membership_event list ->
  revoked_at:int64 ->
  invitation_key:Envelope.key ->
  event_nonce:Envelope.nonce ->
  (membership_event, error) result

val accept :
  runtime:Runtime.configuration ->
  authority:Authority.repository_authority ->
  root:Authority.root_signing_capability ->
  invitation:member_invitation ->
  history:membership_event list ->
  now:int64 ->
  invitation_key:Envelope.key ->
  event_nonce:Envelope.nonce ->
  (acceptance, error) result
(** Rejects expired, revoked, replayed, tampered, foreign, and runtime-invalid
    invitations. The current root-only policy signs acceptance after its
    encrypted MLS snapshot has been decoded, bound, and verified by the MLS
    runtime. *)
