module Policy : sig
  type t

  type error =
    | Negative_recent_window of int64
    | Negative_periodic_interval of int64
    | Negative_storage_budget of int64

  type decision =
    | Protected_by of Paengi_scratch.retention_reason
    | Recent_window
    | Periodic_bucket of int64
    | Expired

  type checkpoint = {
    id : Paengi_scratch.Checkpoint_id.t;
    created_at : int64;
    effective_retention : Paengi_scratch.retention_reason list;
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
  val select : t -> now:int64 -> checkpoint list -> selection list
  val checkpoint : selection -> checkpoint
  val decision : selection -> decision
  val retained : selection -> bool
end

type error

val error_to_string : error -> string

type blocked_removal = {
  checkpoint : Paengi_scratch.Checkpoint_id.t;
  reason : string;
}

type plan

val policy : plan -> Policy.t
val selections : plan -> Policy.selection list
val reachable_object_count : plan -> int
val estimated_before_bytes : plan -> int64
val estimated_after_bytes : plan -> int64
val removable_checkpoints : plan -> Paengi_scratch.Checkpoint_id.t list
val removable_events : plan -> Paengi_scratch.Event_id.t list
val removable_objects : plan -> Paengi_store.Stored_object_id.t list
val blocked_removals : plan -> blocked_removal list
val budget_exceeded_by : plan -> int64 option

val analyze :
  store:Paengi_store.repository ->
  Paengi_scratch.repository ->
  policy:Policy.t ->
  now:int64 ->
  (plan, error) result

val render_explain : plan -> string list
