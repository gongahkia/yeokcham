module Core = Yeokcham_v1_model.Core

type stage = Before_apply | During_apply | Before_commit

type phase =
  | Prepared
  | Applying
  | Materialized
  | Committed
  | Completed
  | Paused of stage * string

type recovery_phase =
  | Recovery_prepared
  | Recovery_applying
  | Recovery_materialized
  | Recovery_committed
  | Recovery_completed

type recovery_mode = Restore_safety | Keep_current

type recovery = private {
  attempt : Core.Operation_id.t;
  plan_id : Core.Digest.t;
  observed : Core.Object_id.t;
  application_digest : Core.Digest.t;
  started_at : int64;
  progress : recovery_phase;
  retained : bool;
  mode : recovery_mode;
  pause_reason : string option;
  previous : Yeokcham_store.Stored_object_id.t option;
}

type t = private {
  token : Core.Operation_id.t;
  plan : Core.Plan_id.t;
  plan_object : Yeokcham_store.Stored_object_id.t;
  branch : Core.Branch_id.t;
  source : Core.History_id.t;
  plan_cursor : Core.History_id.t;
  working_basis : Core.Record_id.t;
  protected : Core.Object_id.t list;
  target_sequence : int64;
  safety : Core.Object_id.t;
  target : Core.Object_id.t;
  accepted : Core.Record_id.t;
  staged : (Core.Record_id.t * Yeokcham_store.Stored_object_id.t) list;
  physical_digest : Core.Digest.t;
  expected_generation : int64;
  expected_root : Yeokcham_store.Stored_object_id.t;
  created_at : int64;
  phase : phase;
  serial : int64;
  acknowledged : bool;
  recovery : recovery option;
  previous_recoveries : recovery list;
}

val make :
  store:Yeokcham_store.repository ->
  repository:Core.Repository_id.t ->
  token:Core.Operation_id.t ->
  plan:Core.Plan_id.t ->
  plan_object:Yeokcham_store.Stored_object_id.t ->
  source:Core.History_id.t ->
  target_sequence:int64 ->
  accepted:Core.Record_id.t ->
  staged:(Core.Record_id.t * Yeokcham_store.Stored_object_id.t) list ->
  physical_digest:Core.Digest.t ->
  expected:Yeokcham_store.Mutable_ref.t ->
  created_at:int64 ->
  (t, string) result
(** Binds an already revalidated Ready plan to staged physical/signed work.
    Construction does not allocate history or publish files/metadata. *)

val pending : t -> bool
val committed : t -> bool
val recovered : t -> bool
val retention_roots : t -> Core.Object_id.t list
val advance : t -> phase -> (t, string) result
val acknowledge : t -> (t, string) result

val start_recovery :
  store:Yeokcham_store.repository ->
  repository:Core.Repository_id.t ->
  attempt:Core.Operation_id.t ->
  plan:Core.Digest.t ->
  observed:Core.Object_id.t ->
  mode:recovery_mode ->
  physical_digest:Core.Digest.t ->
  created_at:int64 ->
  t ->
  (t, string) result

val advance_recovery : t -> recovery_phase -> (t, string) result
val pause_recovery : t -> string option -> (t, string) result

val forget_recovery_roots : t -> (t, string) result
(** Recovery uses the original provisional sequence for its actual chosen
    private-result child. It never publishes the original acceptance. The
    unaccepted proposed target stays protected until explicit release. *)

val validate_update : previous:t -> t -> (unit, string) result
val validate_history : Yeokcham_v1_undo.t -> t list -> (unit, string) result

val store :
  Yeokcham_store.repository ->
  scope:Core.Repository_id.t ->
  t list ->
  (Yeokcham_store.Stored_object_id.t, string) result

val load :
  Yeokcham_store.repository ->
  scope:Core.Repository_id.t ->
  Yeokcham_store.Stored_object_id.t ->
  (t list, string) result

val validate :
  store:Yeokcham_store.repository ->
  authority:Yeokcham_v1_trust.authority ->
  Core.pool ->
  t list ->
  (unit, string) result
(** Historical signature/reference/result checks. Pending signed records remain
    private and do not become authoritative heads until the commit root. *)
