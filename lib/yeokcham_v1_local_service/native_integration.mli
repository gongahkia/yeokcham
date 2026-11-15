module Core = Yeokcham_v1_model.Core
module Plan = Yeokcham_v1_integration
module Operation = Yeokcham_v1_store.Local.Operation

type error =
  | Plan_error of Plan.error
  | Capture_error of Yeokcham_snapshot.error
  | Application_error of Safe_apply.error
  | Metadata of string

val error_to_string : error -> string

type outcome = {
  plan : Core.Plan_id.t;
  operation : Operation.t option;
  no_op : bool;
  resumed : bool;
  recovered : bool;
}

type recovery_outcome = {
  recovery_plan : Core.Digest.t;
  recovery_operation : Operation.t;
  recovery_observed : Core.Object_id.t;
  recovery_target : Core.Object_id.t;
  recovery_preview : bool;
  recovery_resumed : bool;
}

type boundary =
  | Prepared_root
  | Applying_root
  | Materialized_root
  | Committed_root
  | Completed_root
  | Before_root
  | After_root
  | Mutation of Safe_apply.boundary * string list
  | Recovery_prepared_root
  | Recovery_applying_root
  | Recovery_materialized_root
  | Recovery_committed_root
  | Recovery_completed_root
  | Recovery_mutation of Safe_apply.boundary * string list

val with_writer :
  root:string ->
  (Yeokcham_v1_store.repository -> ('a, error) result) ->
  ('a, error) result
(** Shared native worktree writer boundary. Reload state in the callback and
    release the lock before calling a signing provider or waiting for a person.
*)

val require_idle :
  root:string -> Yeokcham_v1_store.loaded -> (unit, error) result

val check_plan :
  root:string ->
  store:Yeokcham_store.repository ->
  safety:Yeokcham_snapshot.Snapshot.id ->
  observation:Yeokcham_snapshot.Observation.t ->
  Plan.t ->
  (unit, error) result

val prepare :
  root:string ->
  selected_revisions:Core.Record_id.t list ->
  reconcile_heads:Core.Record_id.t list option ->
  (Plan.t, error) result
(** Captures a complete observation, prepares and retains an immutable proposal.
    Does not advance private/accepted history or mutate ordinary files. *)

val prepare_resolved :
  resolution_ids:Core.Record_id.t list ->
  root:string ->
  selected_revisions:Core.Record_id.t list ->
  reconcile_heads:Core.Record_id.t list option ->
  (Plan.t, error) result
(** Captures a complete observation, prepares and retains an immutable proposal.
    Does not advance private/accepted history or mutate ordinary files. *)

val prepare_decided :
  workspace_decisions:Plan.workspace_decision list ->
  resolution_ids:Core.Record_id.t list ->
  root:string ->
  selected_revisions:Core.Record_id.t list ->
  reconcile_heads:Core.Record_id.t list option ->
  (Plan.t, error) result
(** Captures a complete observation, prepares and retains an immutable proposal.
    Does not advance private/accepted history or mutate ordinary files. *)

val apply :
  root:string ->
  plan:Core.Plan_id.t ->
  signing_capability:Yeokcham_v1_trust.signing_capability option ->
  (outcome, error) result
(** Caller obtains confirmation of this exact plan before invoking. New
    acceptance requires the enrolled signer; an existing operation resumes its
    staged records without generating another signature/identity. *)

val prepare_clone :
  root:string -> request:Core.Digest.t -> (Plan.t, error) result
(** Exact first materialization of an already verified clone target. The durable
    clone intent permits this preparation while ordinary capture stays blocked.
*)

val resume :
  root:string -> operation:Core.Operation_id.t -> (outcome, error) result

val recover :
  root:string ->
  operation:Core.Operation_id.t ->
  dry_run:bool ->
  mode:Operation.recovery_mode option ->
  replan:bool ->
  expected_plan:Core.Digest.t option ->
  (recovery_outcome, error) result
(** Explicit private safety restoration for an uncommitted integration. Current
    disk contents receive their own protected recovery observation, without a
    normal history capture of the partial application. No acceptance is made.
    Confirmation/preview occurs outside the writer lock. *)

val forget_recovery_roots :
  root:string -> operation:Core.Operation_id.t -> (Operation.t, error) result

module For_test : sig
  val recover :
    observe:(boundary -> unit) ->
    root:string ->
    operation:Core.Operation_id.t ->
    dry_run:bool ->
    mode:Operation.recovery_mode option ->
    replan:bool ->
    expected_plan:Core.Digest.t option ->
    (recovery_outcome, error) result

  val apply_with_entropy :
    random_bytes:(int -> (string, string) result) ->
    observe:(boundary -> unit) ->
    root:string ->
    plan:Core.Plan_id.t ->
    signing_capability:Yeokcham_v1_trust.signing_capability option ->
    (outcome, error) result

  val apply :
    observe:(boundary -> unit) ->
    root:string ->
    plan:Core.Plan_id.t ->
    signing_capability:Yeokcham_v1_trust.signing_capability option ->
    (outcome, error) result
end
