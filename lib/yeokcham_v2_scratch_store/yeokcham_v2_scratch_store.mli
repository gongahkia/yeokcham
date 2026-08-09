(** Device-scoped causal V2 scratch checkpoint publication from ADR-055.

    The caller supplies an exact snapshot and two distinct envelope nonces. This
    adapter publishes the immutable snapshot before its signed causal ledger
    event; it owns no working-tree scan, mutable head, or conflict selection. *)

module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_model
module Object_store = Yeokcham_v2_object_store
module V2_model = Yeokcham_v2_model

type repository

type checkpoint = {
  event_id : Ledger.Event_id.t;
  snapshot_ref : V2_model.Opaque_object_ref.t;
  snapshot : Model.Snapshot.t;
}

type inspection =
  | No_checkpoint
  | Checkpoint of checkpoint
  | Divergent_checkpoints of Ledger.Event_id.t list

type publication = Published of checkpoint | Unchanged of checkpoint

type plan =
  | Unchanged_plan of checkpoint
  | Publish_plan of {
      checkpoint : checkpoint;
      snapshot_envelope : Envelope.t;
      ledger_envelope : Envelope.t;
    }

type error =
  | Bootstrap_store_error of Bootstrap_store.error
  | Bootstrap_error of Bootstrap.error
  | Object_store_error of Object_store.error
  | Ledger_store_error of Yeokcham_v2_ledger_store.error
  | Envelope_error of Envelope.error
  | Ledger_error of Ledger.error
  | Scratch_event_missing_target of Ledger.Event_id.t
  | Unknown_scratch_event of Ledger.Event_id.t
  | Event_outside_scratch_scope of Ledger.Event_id.t
  | Scratch_target_not_snapshot of {
      event_id : Ledger.Event_id.t;
      object_ref : V2_model.Opaque_object_ref.t;
    }
  | Missing_evaluated_checkpoint of Ledger.Event_id.t
  | Divergent_scratch_heads of Ledger.Event_id.t list
  | Nonce_reuse

val error_to_string : error -> string

val open_repository :
  root:string ->
  bootstrap_repository:Bootstrap_store.repository ->
  (repository, error) result
(** Reopens and validates [root] with the injected capability from the supplied
    bootstrap repository, so a repository handle cannot be transplanted to a
    different root without passing its own bootstrap validation. *)

val scratch_ref_name : repository -> Ledger.Ref_name.t

val inspect : repository -> (inspection, error) result
(** Read-only. It verifies each typed ledger frame before considering this
    device's scratch scope and rejects invalid scratch targets. *)

val checkpoint_for_event :
  repository -> event_id:Ledger.Event_id.t -> (checkpoint, error) result
(** Reads one explicitly named signed event from this device's scratch scope and
    resolves its typed exact snapshot. It does not choose a causal head. *)

val publish :
  repository ->
  snapshot:Model.Snapshot.t ->
  snapshot_nonce:Envelope.nonce ->
  ledger_nonce:Envelope.nonce ->
  (publication, error) result
(** Creates no object for an exact unchanged sole checkpoint. For a new
    checkpoint, creates the immutable snapshot object before the signed ledger
    event. Divergence is returned by [inspect] and is never selected here. *)

val plan :
  repository ->
  snapshot:Model.Snapshot.t ->
  snapshot_nonce:Envelope.nonce ->
  ledger_nonce:Envelope.nonce ->
  (plan, error) result
(** Computes byte-exact encrypted candidates after read-only inspection. The
    returned plan contains no mutable-head decision; it can be retried after an
    interruption with [publish_plan]. *)

val publish_plan : repository -> plan -> (publication, error) result
(** Publishes a snapshot candidate before its ledger candidate. A caller may
    persist the snapshot half, crash, then reuse the exact plan to finish the
    ledger half; until then [inspect] returns the prior causal checkpoint. *)
