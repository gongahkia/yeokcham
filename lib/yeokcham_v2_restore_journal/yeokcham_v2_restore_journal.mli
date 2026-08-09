(** Canonical opaque recovery state for one non-no-op V2 restore.

    These records are intentionally unable to describe filesystem bytes or
    paths. They bind the safety event and the encrypted snapshot references an
    effectful restore adapter must use. *)

module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_v2_model

type phase = Prepared | Applying of int | Materialized | Published
type t

type error =
  | Nonpositive_action_count of int
  | Too_many_actions of int
  | Identical_snapshot_references
  | Invalid_generation of int64
  | Generation_exhausted
  | Invalid_progress of { completed : int; action_count : int }
  | Invalid_phase_for_generation of { phase : phase; generation : int64 }
  | Invalid_transition of { previous : phase; next : phase }
  | Invalid_mandatory_features of int64
  | Unsupported_mandatory_features of int64
  | Unsupported_schema_version of int64
  | Unknown_phase of int64
  | Invalid_payload of string
  | Noncanonical_record

val error_to_string : error -> string
val current_schema_version : int64
val supported_mandatory_features : int64
val max_actions : int
val max_record_bytes : int

val make_prepared :
  repository_id:Model.Repository_id.t ->
  operation_id:Model.Transaction_id.t ->
  safety_event_id:Ledger.Event_id.t ->
  safety_snapshot:Model.Opaque_object_ref.t ->
  target_snapshot:Model.Opaque_object_ref.t ->
  action_count:int ->
  mandatory_features:int64 ->
  (t, error) result

val repository_id : t -> Model.Repository_id.t
val operation_id : t -> Model.Transaction_id.t
val safety_event_id : t -> Ledger.Event_id.t
val safety_snapshot : t -> Model.Opaque_object_ref.t
val target_snapshot : t -> Model.Opaque_object_ref.t
val generation : t -> int64
val phase : t -> phase
val action_count : t -> int
val completed_actions : t -> int

val advance : t -> phase -> (t, error) result
(** A legal advancement creates the next immutable generation. The first
    [Applying 0] record is written before the first destructive action; an
    adapter then appends one greater [Applying] count after each completed
    action. *)

val encode : t -> string
val decode : string -> (t, error) result
