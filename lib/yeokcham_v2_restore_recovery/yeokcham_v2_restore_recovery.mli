(** Authenticated restart and publication for a durable V2 restore journal.

    The service resolves the journal's safety and caller-selected target events
    through the local signed scratch scope before it materialises or publishes.
    It never selects a causal head as a restore target. *)

module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Journal = Yeokcham_v2_restore_journal
module Journal_store = Yeokcham_v2_restore_journal_store
module Materializer = Yeokcham_v2_restore_materializer
module Scanner = Yeokcham_v2_scanner
module Scratch_store = Yeokcham_v2_scratch_store
module V2_model = Yeokcham_v2_model

type outcome = { journal : Journal.t; checkpoint : Scratch_store.checkpoint }

type error =
  | Journal_store_error of Journal_store.error
  | Journal_error of Journal.error
  | Scratch_store_error of Scratch_store.error
  | Scanner_error of Scanner.error
  | Materializer_error of Materializer.error
  | Operation_missing of V2_model.Transaction_id.t
  | Safety_reference_mismatch
  | Target_reference_mismatch
  | Journal_plan_mismatch of { journal : int; plan : int }
  | Unexpected_scratch_state of Scratch_store.inspection
  | Final_worktree_mismatch
  | Published_checkpoint_mismatch

val error_to_string : error -> string
val journal : outcome -> Journal.t
val checkpoint : outcome -> Scratch_store.checkpoint

val resume :
  root:string ->
  bootstrap_repository:Bootstrap_store.repository ->
  operation_id:V2_model.Transaction_id.t ->
  post_snapshot_nonce:Envelope.nonce ->
  post_ledger_nonce:Envelope.nonce ->
  (outcome, error) result
(** [resume] advances a known journal only after re-verifying both named signed
    events, the journal's opaque snapshot bindings, and the exact filesystem
    prefix. For [Materialized], it re-scans the target before causally
    publishing the post-restore scratch snapshot, then appends [Published]. A
    divergent or externally advanced scratch view is never chosen or replaced.
*)
