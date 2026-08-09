(** Canonical V2 retention records and pure ordinal/quota planning from ADR-058.

    This module has no filesystem, clock, key, or ledger-selection effect. Its
    callers supply one already-verified causal history in oldest-to-newest
    order. *)

module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_v2_model

type protection_reason =
  | User_pin
  | Capsule_boundary of Model.Opaque_object_ref.t
  | Release_boundary of Model.Opaque_object_ref.t

type protection_action = Protect | Unprotect

type protection = {
  protected_snapshot_ref : Model.Opaque_object_ref.t;
  protection_action : protection_action;
  protection_reason : protection_reason;
}

type cleanup_kind = Ledger_event | Scratch_snapshot

type cleanup_candidate = {
  candidate_object_ref : Model.Opaque_object_ref.t;
  candidate_kind : cleanup_kind;
}

type generation = {
  active_ref : Ledger.Ref_name.t;
  active_head : Ledger.Event_id.t;
  retired_refs : Ledger.Ref_name.t list;
  cleanup_candidates : cleanup_candidate list;
}

type checkpoint = {
  event_id : Ledger.Event_id.t;
  event_object_ref : Model.Opaque_object_ref.t;
  checkpoint_snapshot_ref : Model.Opaque_object_ref.t;
}

type object_size = {
  sized_object_ref : Model.Opaque_object_ref.t;
  stored_bytes : int64;
}

type policy

type retention_decision =
  | Current_head
  | Protected of protection_reason list
  | Recent
  | Expired
  | Budget_excluded

type planned_checkpoint = {
  checkpoint : checkpoint;
  decision : retention_decision;
}

type plan = {
  retained : planned_checkpoint list;
  excluded : planned_checkpoint list;
  retained_bytes : int64;
  required_overrun : int64 option;
}

type error =
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Duplicate_retired_ref of string
  | Empty_retired_refs
  | Active_ref_is_retired of string
  | Duplicate_cleanup_candidate of Model.Opaque_object_ref.t
  | Invalid_recent_count of int
  | Negative_storage_budget of int64
  | Empty_history
  | Duplicate_checkpoint_event of Ledger.Event_id.t
  | Duplicate_checkpoint_object of Model.Opaque_object_ref.t
  | Duplicate_object_size of Model.Opaque_object_ref.t
  | Negative_object_size of {
      object_ref : Model.Opaque_object_ref.t;
      bytes : int64;
    }
  | Missing_object_size of Model.Opaque_object_ref.t
  | Size_overflow
  | Cleanup_kind_collision of Model.Opaque_object_ref.t

val error_to_string : error -> string

val protection :
  snapshot_ref:Model.Opaque_object_ref.t ->
  action:protection_action ->
  reason:protection_reason ->
  protection

val encode_protection : protection -> string
val decode_protection : string -> (protection, error) result

val make_generation :
  active_ref:Ledger.Ref_name.t ->
  active_head:Ledger.Event_id.t ->
  retired_refs:Ledger.Ref_name.t list ->
  cleanup_candidates:cleanup_candidate list ->
  (generation, error) result

val encode_generation : generation -> string
val decode_generation : string -> (generation, error) result

val make_policy :
  recent_count:int ->
  storage_budget_bytes:int64 option ->
  (policy, error) result
(** [recent_count] is ordinal newest-to-oldest chain selection; V2 has no
    accepted checkpoint timestamp. *)

val select :
  policy:policy ->
  claims:protection list ->
  history:checkpoint list ->
  object_sizes:object_size list ->
  (plan, error) result
(** Current head and effective claims are retained regardless of quota. Other
    entries in the ordinal recent window are considered newest-first. *)

val cleanup_candidates :
  history:checkpoint list ->
  retained:checkpoint list ->
  externally_referenced:Model.Opaque_object_ref.t list ->
  (cleanup_candidate list, error) result
(** Builds a canonical candidate list for an already activated generation:
    source events are candidates; an unretained source snapshot is a candidate
    only when no retained checkpoint or external live ledger target names it. *)
