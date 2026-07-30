type path = string list
type source = Explicit | Scan

type retention_reason =
  | User_pinned
  | Capsule_boundary of Paengi_id.Capsule_id.t
  | Release_boundary of Paengi_id.Release_id.t
  | Validation_passed of Paengi_id.Validation_id.t
  | Periodic_retention
  | Recent_window
  | Conflict_reference of Paengi_id.Conflict_id.t

type entry =
  | Directory
  | File of {
      mode : Paengi_snapshot.file_mode;
      content : Paengi_snapshot.Content.id;
    }

type operation =
  | Create of { path : path; entry : entry }
  | Delete of { path : path; prior : entry }
  | Modify_content of {
      path : path;
      expected : Paengi_snapshot.Content.id;
      replacement : Paengi_snapshot.Content.id;
    }
  | Change_mode of {
      path : path;
      expected : Paengi_snapshot.file_mode;
      replacement : Paengi_snapshot.file_mode;
    }
  | Move of { source : path; destination : path; prior : entry }

type error

val error_to_string : error -> string
val retention_reason_to_string : retention_reason -> string

module Event_id : sig
  type t

  val of_stored_object_id : Paengi_store.Stored_object_id.t -> t
  val stored_object_id : t -> Paengi_store.Stored_object_id.t
  val equal : t -> t -> bool
end

module Checkpoint_id : sig
  type t

  val of_stored_object_id : Paengi_store.Stored_object_id.t -> t
  val stored_object_id : t -> Paengi_store.Stored_object_id.t
  val equal : t -> t -> bool
end

module Retention_change_id : sig
  type t

  val of_stored_object_id : Paengi_store.Stored_object_id.t -> t
  val stored_object_id : t -> Paengi_store.Stored_object_id.t
  val equal : t -> t -> bool
end

module Generation_id : sig
  type t

  val of_stored_object_id : Paengi_store.Stored_object_id.t -> t
  val stored_object_id : t -> Paengi_store.Stored_object_id.t
  val equal : t -> t -> bool
end

module Cleanup_manifest_id : sig
  type t

  val of_stored_object_id : Paengi_store.Stored_object_id.t -> t
  val stored_object_id : t -> Paengi_store.Stored_object_id.t
  val equal : t -> t -> bool
end

module State : sig
  type t

  val create : (path * entry) list -> (t, error) result
  val entries : t -> (path * entry) list
  val find : t -> path -> entry option
  val equal : t -> t -> bool

  val of_snapshot :
    Paengi_store.repository -> Paengi_snapshot.Snapshot.t -> (t, error) result

  val apply : t -> operation list -> (t, error) result
  val diff : from:t -> to_:t -> operation list
end

module Event : sig
  type t

  val create :
    parent:Checkpoint_id.t ->
    base:Paengi_snapshot.Snapshot.id ->
    resulting:Paengi_snapshot.Snapshot.id ->
    operations:operation list ->
    source:source ->
    observed_at:int64 ->
    t

  val id : t -> Event_id.t
  val parent : t -> Checkpoint_id.t
  val base : t -> Paengi_snapshot.Snapshot.id
  val resulting : t -> Paengi_snapshot.Snapshot.id
  val operations : t -> operation list
  val source : t -> source
  val observed_at : t -> int64
  val store : Paengi_store.repository -> t -> (Event_id.t, error) result
  val load : Paengi_store.repository -> Event_id.t -> (t, error) result
end

module Checkpoint : sig
  type t

  val create_initial :
    snapshot:Paengi_snapshot.Snapshot.id -> created_at:int64 -> t

  val create :
    parent:Checkpoint_id.t ->
    event:Event_id.t ->
    snapshot:Paengi_snapshot.Snapshot.id ->
    created_at:int64 ->
    t

  val create_initial_with_retention :
    snapshot:Paengi_snapshot.Snapshot.id ->
    created_at:int64 ->
    intrinsic_retention:retention_reason list ->
    t

  val create_with_retention :
    parent:Checkpoint_id.t ->
    event:Event_id.t ->
    snapshot:Paengi_snapshot.Snapshot.id ->
    created_at:int64 ->
    intrinsic_retention:retention_reason list ->
    t

  val id : t -> Checkpoint_id.t
  val parent : t -> Checkpoint_id.t option
  val event : t -> Event_id.t option
  val snapshot : t -> Paengi_snapshot.Snapshot.id
  val created_at : t -> int64
  val intrinsic_retention : t -> retention_reason list
  val store : Paengi_store.repository -> t -> (Checkpoint_id.t, error) result
  val load : Paengi_store.repository -> Checkpoint_id.t -> (t, error) result
end

module Cleanup_manifest : sig
  type candidate = {
    object_id : Paengi_store.Stored_object_id.t;
    expected_type : Paengi_envelope.object_type;
  }

  type t

  val create : candidate list -> (t, error) result
  val id : t -> Cleanup_manifest_id.t
  val candidates : t -> candidate list

  val store :
    Paengi_store.repository -> t -> (Cleanup_manifest_id.t, error) result

  val load :
    Paengi_store.repository -> Cleanup_manifest_id.t -> (t, error) result
end

module Generation : sig
  type entry
  type t

  val max_entries_per_segment : int

  val entry :
    logical:Checkpoint_id.t ->
    physical:Checkpoint_id.t ->
    snapshot:Paengi_snapshot.Snapshot.id ->
    previous_logical:Checkpoint_id.t option ->
    effective_retention:retention_reason list ->
    entry

  val logical : entry -> Checkpoint_id.t
  val physical : entry -> Checkpoint_id.t
  val snapshot : entry -> Paengi_snapshot.Snapshot.id
  val previous_logical : entry -> Checkpoint_id.t option
  val effective_retention : entry -> retention_reason list

  val store :
    Paengi_store.repository ->
    previous:Generation_id.t option ->
    source_scratch_head:Checkpoint_id.t ->
    source_scratch_ref_generation:int64 ->
    source_retention_head:Retention_change_id.t option ->
    source_retention_ref_generation:int64 option ->
    recent_window_seconds:int64 ->
    periodic_interval_seconds:int64 ->
    storage_budget_bytes:int64 option ->
    entries:entry list ->
    physical_head:Checkpoint_id.t ->
    retention_cutoff:Retention_change_id.t option ->
    cleanup_manifest:Cleanup_manifest_id.t ->
    (Generation_id.t, error) result

  val load : Paengi_store.repository -> Generation_id.t -> (t, error) result
  val id : t -> Generation_id.t
  val previous : t -> Generation_id.t option
  val source_scratch_head : t -> Checkpoint_id.t
  val source_scratch_ref_generation : t -> int64
  val source_retention_head : t -> Retention_change_id.t option
  val source_retention_ref_generation : t -> int64 option
  val recent_window_seconds : t -> int64
  val periodic_interval_seconds : t -> int64
  val storage_budget_bytes : t -> int64 option
  val segment_ids : t -> Generation_id.t list
  val entries : t -> entry list
  val physical_head : t -> Checkpoint_id.t
  val retention_cutoff : t -> Retention_change_id.t option
  val cleanup_manifest : t -> Cleanup_manifest_id.t
end

module Retention_change : sig
  type action = Add | Remove
  type t

  val create :
    previous:Retention_change_id.t option ->
    checkpoint:Checkpoint_id.t ->
    action:action ->
    reason:retention_reason ->
    changed_at:int64 ->
    t

  val id : t -> Retention_change_id.t
  val previous : t -> Retention_change_id.t option
  val checkpoint : t -> Checkpoint_id.t
  val action : t -> action
  val reason : t -> retention_reason
  val changed_at : t -> int64

  val store :
    Paengi_store.repository -> t -> (Retention_change_id.t, error) result

  val load :
    Paengi_store.repository -> Retention_change_id.t -> (t, error) result
end

type repository
type checkpoint_result = Created of Checkpoint.t | Unchanged of Checkpoint.t
type resolved_checkpoint

val resolved_logical_id : resolved_checkpoint -> Checkpoint_id.t
val resolved_physical_id : resolved_checkpoint -> Checkpoint_id.t
val resolved_checkpoint : resolved_checkpoint -> Checkpoint.t

type timeline_entry = {
  logical_id : Checkpoint_id.t;
  checkpoint : Checkpoint.t;
  depth : int;
  effective_retention : retention_reason list;
}

val open_repository : Paengi_store.repository -> repository
val active_generation : repository -> (Generation.t option, error) result

val resolve_checkpoint :
  repository -> Checkpoint_id.t -> (resolved_checkpoint, error) result

val head_id : repository -> (Checkpoint_id.t option, error) result

val create_initial :
  repository ->
  snapshot:Paengi_snapshot.Snapshot.id ->
  created_at:int64 ->
  (Checkpoint.t, error) result

val checkpoint :
  repository ->
  snapshot:Paengi_snapshot.Snapshot.id ->
  source:source ->
  observed_at:int64 ->
  created_at:int64 ->
  (checkpoint_result, error) result

val head : repository -> (Checkpoint.t option, error) result

val timeline :
  repository ->
  ?start:Checkpoint_id.t ->
  limit:int ->
  unit ->
  (timeline_entry list, error) result

val pin :
  repository -> Checkpoint_id.t -> changed_at:int64 -> (unit, error) result

val unpin :
  repository -> Checkpoint_id.t -> changed_at:int64 -> (unit, error) result

val pin_capsule_boundary :
  repository ->
  Checkpoint_id.t ->
  capsule:Paengi_id.Capsule_id.t ->
  changed_at:int64 ->
  (unit, error) result

module Polling : sig
  type t

  val create : debounce_ms:int -> t

  val observe :
    t ->
    head:Paengi_snapshot.Snapshot.id ->
    observed:Paengi_snapshot.Snapshot.id ->
    now_ms:int64 ->
    t * bool
end

module Restore : sig
  type plan

  val current_snapshot : plan -> Paengi_snapshot.Snapshot.id
  val target_checkpoint : plan -> Checkpoint_id.t
  val safety_checkpoint : plan -> Checkpoint_id.t option
  val actions : plan -> operation list

  val dry_run :
    repository -> root:string -> target:Checkpoint_id.t -> (plan, error) result

  val prepare :
    repository ->
    root:string ->
    target:Checkpoint_id.t ->
    observed_at:int64 ->
    created_at:int64 ->
    (plan, error) result

  val apply : repository -> root:string -> plan -> (unit, error) result

  val restore :
    repository ->
    root:string ->
    target:Checkpoint_id.t ->
    observed_at:int64 ->
    created_at:int64 ->
    (Checkpoint_id.t option, error) result
end
