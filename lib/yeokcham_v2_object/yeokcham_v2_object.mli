(** Canonical typed plaintext frames carried by V2 encrypted envelopes.

    The outer envelope and opaque address hide the frame kind from unkeyed
    storage. A frame has exactly one strict payload decoder; callers must not
    decode every plaintext as a ledger event. *)

module Ledger = Yeokcham_v2_ledger
module Retention = Yeokcham_v2_retention
module Snapshot = Yeokcham_model.Snapshot
module Capsule = Yeokcham_v2_capsule
module Release_record = Yeokcham_v2_release_record
module Workspace_record = Yeokcham_v2_workspace_record
module Authority = Yeokcham_v2_authority

type kind =
  | Ledger_event
  | Scratch_snapshot
  | Scratch_protection
  | Scratch_generation
  | Capsule
  | Capsule_revision
  | Workspace
  | Workspace_revision
  | Workspace_attempt
  | Conflict
  | Resolution
  | Validation_evidence
  | Release
  | Repository_authority
  | Device_certificate
  | Device_revocation

type t

type error =
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unknown_kind of int64
  | Ledger_error of Ledger.error
  | Retention_error of Retention.error
  | Capsule_error of Capsule.error
  | Workspace_record_error of Workspace_record.error
  | Release_record_error of Release_record.error
  | Authority_error of Authority.error
  | Snapshot_error of Yeokcham_model.canonical_decode_error
  | Noncanonical_frame

val error_to_string : error -> string
val current_schema_version : int64
val supported_mandatory_features : int64
val max_payload_bytes : int
val ledger_event : Ledger.t -> t
val scratch_snapshot : Snapshot.t -> t
val scratch_protection : Retention.protection -> t
val scratch_generation : Retention.generation -> t
val capsule : Capsule.capsule -> t
val capsule_revision : Capsule.revision -> t
val workspace : Workspace_record.workspace -> t
val workspace_revision : Workspace_record.workspace_revision -> t
val workspace_attempt : Workspace_record.workspace_attempt -> t
val conflict : Workspace_record.conflict -> t
val resolution : Workspace_record.resolution -> t
val validation_evidence : Release_record.validation_evidence -> t
val release : Release_record.release -> t
val repository_authority : Authority.repository_authority -> t
val device_certificate : Authority.device_certificate -> t
val device_revocation : Authority.device_revocation -> t
val kind : t -> kind
val all_kinds : kind list
val kind_code : kind -> int64
val ledger : t -> Ledger.t option
val snapshot : t -> Snapshot.t option
val protection : t -> Retention.protection option
val generation : t -> Retention.generation option
val capsule_record : t -> Capsule.capsule option
val capsule_revision_record : t -> Capsule.revision option
val workspace_record : t -> Workspace_record.workspace option
val workspace_revision_record : t -> Workspace_record.workspace_revision option
val workspace_attempt_record : t -> Workspace_record.workspace_attempt option
val conflict_record : t -> Workspace_record.conflict option
val resolution_record : t -> Workspace_record.resolution option
val validation_evidence_record : t -> Release_record.validation_evidence option
val release_record : t -> Release_record.release option
val repository_authority_record : t -> Authority.repository_authority option

(* A strict canonical certificate record whose root signature still needs its
    repository-authority anchor before it becomes an authority decision. *)
val device_certificate_payload : t -> string option

(* A strict canonical revocation record whose root signature still needs its
    repository-authority anchor before it becomes an authority decision. *)
val device_revocation_payload : t -> string option
val encode : t -> string
val decode : string -> (t, error) result
