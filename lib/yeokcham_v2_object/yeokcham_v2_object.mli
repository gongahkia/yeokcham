(** Canonical typed plaintext frames carried by V2 encrypted envelopes.

    The outer envelope and opaque address hide the frame kind from unkeyed
    storage. A frame has exactly one strict payload decoder; callers must not
    decode every plaintext as a ledger event. *)

module Ledger = Yeokcham_v2_ledger
module Retention = Yeokcham_v2_retention
module Snapshot = Yeokcham_model.Snapshot
module Capsule = Yeokcham_v2_capsule

type kind =
  | Ledger_event
  | Scratch_snapshot
  | Scratch_protection
  | Scratch_generation
  | Capsule
  | Capsule_revision

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
val kind : t -> kind
val ledger : t -> Ledger.t option
val snapshot : t -> Snapshot.t option
val protection : t -> Retention.protection option
val generation : t -> Retention.generation option
val capsule_record : t -> Capsule.capsule option
val capsule_revision_record : t -> Capsule.revision option
val encode : t -> string
val decode : string -> (t, error) result
