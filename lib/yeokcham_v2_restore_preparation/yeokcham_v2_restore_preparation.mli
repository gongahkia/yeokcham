(** Guarded V2 restore preparation before any filesystem materialisation.

    A caller explicitly names a signed target scratch event. A changed working
    tree is durably checkpointed and journaled before a later adapter can apply
    the exact pure restore plan. *)

module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Journal = Yeokcham_v2_restore_journal
module Journal_store = Yeokcham_v2_restore_journal_store
module Restore_plan = Yeokcham_v2_restore_plan
module Scratch_store = Yeokcham_v2_scratch_store
module V2_model = Yeokcham_v2_model

type prepared
type outcome = Noop of Scratch_store.checkpoint | Prepared of prepared

type error =
  | Scanner_error of Yeokcham_v2_scanner.error
  | Scratch_store_error of Scratch_store.error
  | Journal_error of Journal.error
  | Journal_store_error of Journal_store.error
  | Safety_checkpoint_mismatch
  | Operation_already_exists of Journal.t

val error_to_string : error -> string
val target_checkpoint : prepared -> Scratch_store.checkpoint
val safety_checkpoint : prepared -> Scratch_store.checkpoint
val plan : prepared -> Restore_plan.t

val journal : prepared -> Journal.t
(** The returned journal is the durable [Applying(0)] generation. *)

val prepare :
  root:string ->
  bootstrap_repository:Bootstrap_store.repository ->
  target_event_id:Scratch_store.Ledger.Event_id.t ->
  operation_id:V2_model.Transaction_id.t ->
  safety_snapshot_nonce:Envelope.nonce ->
  safety_ledger_nonce:Envelope.nonce ->
  (outcome, error) result
(** Resolves [target_event_id] without selecting a causal head. For an unequal
    exact scan, publishes the scan as a safety checkpoint and durably writes
    [Prepared] then [Applying(0)] before returning. It never writes [root]. *)
