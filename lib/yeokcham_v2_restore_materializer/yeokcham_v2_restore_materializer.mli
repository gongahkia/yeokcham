(** Exact, guarded filesystem materialisation for a prepared V2 restore plan.

    This adapter accepts only the durable [Applying(0)] boundary produced by
    {!Yeokcham_v2_restore_preparation}. It re-scans the working tree before any
    write, confines every operation below [root], advances the immutable restore
    journal after each durable filesystem action, and re-scans the final tree.
    It neither chooses a target nor publishes a post-restore scratch checkpoint.
*)

module Journal = Yeokcham_v2_restore_journal
module Journal_store = Yeokcham_v2_restore_journal_store
module Model = Yeokcham_model
module Restore_plan = Yeokcham_v2_restore_plan
module Scanner = Yeokcham_v2_scanner

module Fault : sig
  type t

  val never : t

  val interrupt_after_action : int -> t
  (** Deterministic test hook. It returns an interruption after the named
      filesystem action has been made durable but before its journal generation
      is appended. *)
end

type outcome = { journal : Journal.t }

type error =
  | Scanner_error of Scanner.error
  | Journal_error of Journal.error
  | Journal_store_error of Journal_store.error
  | Pure_plan_error of Restore_plan.replay_error
  | Invalid_plan of string
  | Journal_action_count_mismatch of { journal : int; plan : int }
  | Journal_not_applying_zero of Journal.phase
  | Stale_worktree of { expected : Model.Snapshot.t; actual : Model.Snapshot.t }
  | Verification_mismatch of {
      expected : Model.Snapshot.t;
      actual : Model.Snapshot.t;
    }
  | Unsafe_path of { path : string; reason : string }
  | Unexpected_node of { path : string; expected : string; actual : string }
  | Io_error of { operation : string; path : string; message : string }
  | Injected_interruption of { completed_actions : int }

val error_to_string : error -> string

val materialize :
  ?fault:Fault.t ->
  root:string ->
  journal_store:Journal_store.repository ->
  plan:Restore_plan.t ->
  journal:Journal.t ->
  unit ->
  (outcome, error) result
(** [materialize] only accepts a nonempty plan with a matching durable
    [Applying(0)] journal. Every action is made durable before the journal
    records its successor. An error retains the already-published safety
    checkpoint and journal generations for an explicit later recovery path. *)
