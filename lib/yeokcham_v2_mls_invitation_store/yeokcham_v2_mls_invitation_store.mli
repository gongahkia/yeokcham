(** Create-only durable records for V2-030 MLS invitations and membership
    lifecycle events. These bytes are already signed and contain encrypted
    payloads; this adapter only validates, publishes, and enumerates them. *)

module Authority = Yeokcham_v2_authority
module Invitation = Yeokcham_v2_mls_invitation

type publication = Published | Already_published

type error =
  | Cutover_error of Yeokcham_cutover.error
  | Not_v2_root of Yeokcham_cutover.classification
  | Invitation_error of Invitation.error
  | Missing_record of string
  | Invalid_record_path of string
  | Record_collision of string
  | Io_error of { operation : string; path : string; message : string }
  | Temporary_name_exhausted of string

val error_to_string : error -> string
val invitation_directory : root:string -> string
val membership_event_directory : root:string -> string

val invitation_path :
  root:string -> Invitation.Model.Mls_invitation_id.t -> string

val membership_event_path :
  root:string -> Invitation.Model.Mls_invitation_id.t -> string

val write_invitation :
  root:string ->
  authority:Authority.repository_authority ->
  Invitation.member_invitation ->
  (publication, error) result

val write_membership_event :
  root:string ->
  authority:Authority.repository_authority ->
  Invitation.membership_event ->
  (publication, error) result

val read_invitation :
  root:string ->
  authority:Authority.repository_authority ->
  Invitation.Model.Mls_invitation_id.t ->
  (Invitation.member_invitation, error) result

val read_membership_events :
  root:string ->
  authority:Authority.repository_authority ->
  (Invitation.membership_event list, error) result
