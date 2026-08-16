module Policy : sig
  type t

  type error =
    | Negative_recent_window of int64
    | Negative_periodic_interval of int64
    | Negative_storage_budget of int64

  type decision =
    | Protected_by of Yeokcham_scratch.retention_reason
    | Recent_window
    | Periodic_bucket of int64
    | Required_for_replay
    | Budget_excluded
    | Expired

  type checkpoint = {
    id : Yeokcham_scratch.Checkpoint_id.t;
    created_at : int64;
    effective_retention : Yeokcham_scratch.retention_reason list;
    storage_bytes : int64;
  }

  type selection = { checkpoint : checkpoint; decision : decision }

  val error_to_string : error -> string

  val create :
    recent_window_seconds:int64 ->
    periodic_interval_seconds:int64 ->
    storage_budget_bytes:int64 option ->
    (t, error) result

  val default : t
  val recent_window_seconds : t -> int64
  val periodic_interval_seconds : t -> int64
  val storage_budget_bytes : t -> int64 option

  val select :
    ?required:Yeokcham_scratch.Checkpoint_id.t list ->
    t ->
    now:int64 ->
    checkpoint list ->
    selection list

  val checkpoint : selection -> checkpoint
  val decision : selection -> decision
  val retained : selection -> bool
end

val eliminate_exact_inverse_pairs :
  Yeokcham_scratch.operation list -> Yeokcham_scratch.operation list * int

type error

val error_to_string : error -> string

type blocked_removal = {
  checkpoint : Yeokcham_scratch.Checkpoint_id.t;
  reason : string;
}

type cleanup_candidate = {
  candidate_object_id : Yeokcham_store.Stored_object_id.t;
  candidate_expected_type : Yeokcham_envelope.object_type;
}

type cleanup_metric = {
  metric_object_id : Yeokcham_store.Stored_object_id.t;
  metric_expected_type : Yeokcham_envelope.object_type;
  stored_bytes : int64;
}

module Fault : sig
  type boundary = Before_candidate of int | After_candidate of int
  type t

  val before_candidate : int -> t
  val after_candidate : int -> t
end

type plan
type execution

type cleanup_report = {
  generation : Yeokcham_scratch.Generation_id.t;
  quarantined_objects : int;
  quarantined_bytes : int64;
  pruned_objects : int;
  pruned_bytes : int64;
  already_quarantined_objects : int;
  already_pruned_objects : int;
  quarantined_candidates : cleanup_metric list;
  pruned_candidates : cleanup_metric list;
  already_quarantined_candidates : cleanup_candidate list;
  already_pruned_candidates : cleanup_candidate list;
}

val policy : plan -> Policy.t
val selections : plan -> Policy.selection list
val reachable_object_count : plan -> int
val estimated_before_bytes : plan -> int64
val estimated_after_bytes : plan -> int64
val budget_retained_checkpoint_bytes : plan -> int64
val budget_protected_checkpoint_bytes : plan -> int64
val inverse_pairs_eliminated : plan -> int
val removable_checkpoints : plan -> Yeokcham_scratch.Checkpoint_id.t list
val removable_events : plan -> Yeokcham_scratch.Event_id.t list
val removable_objects : plan -> Yeokcham_store.Stored_object_id.t list
val planned_cleanup : plan -> cleanup_metric list
val planned_cleanup_count : plan -> int
val planned_cleanup_bytes : plan -> int64
val blocked_removals : plan -> blocked_removal list
val budget_exceeded_by : plan -> int64 option

val analyze :
  store:Yeokcham_store.repository ->
  Yeokcham_scratch.repository ->
  policy:Policy.t ->
  now:int64 ->
  (plan, error) result

val render_explain : plan -> string list

val activate :
  ?cleanup:bool ->
  ?cleanup_fault:Fault.t ->
  ?before_publish:(unit -> unit) ->
  ?on_progress:(completed:int -> total:int -> unit) ->
  store:Yeokcham_store.repository ->
  Yeokcham_scratch.repository ->
  policy:Policy.t ->
  now:int64 ->
  (execution, error) result

val execution_generation : execution -> Yeokcham_scratch.Generation_id.t
val execution_plan : execution -> plan
val execution_cleanup : execution -> cleanup_report

val resume_cleanup :
  ?fault:Fault.t ->
  ?expected_generation:Yeokcham_scratch.Generation_id.t ->
  ?on_progress:(completed:int -> total:int -> unit) ->
  store:Yeokcham_store.repository ->
  Yeokcham_scratch.repository ->
  (cleanup_report, error) result

val prune :
  ?fault:Fault.t ->
  ?expected_generation:Yeokcham_scratch.Generation_id.t ->
  ?on_progress:(completed:int -> total:int -> unit) ->
  store:Yeokcham_store.repository ->
  Yeokcham_scratch.repository ->
  (cleanup_report, error) result
