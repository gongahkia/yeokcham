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
module Retention = Yeokcham_v2_retention
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

type compaction_nonces = {
  compact_ledger_nonces : Envelope.nonce list;
  generation_manifest_nonce : Envelope.nonce;
  generation_ledger_nonce : Envelope.nonce;
}
(** Nonces are caller-supplied because this adapter owns neither a random source
    nor nonce persistence. Every nonce in one compaction plan must be distinct;
    [compact_ledger_nonces] has exactly one member per selected retained
    checkpoint. *)

type compacted_event = {
  source_checkpoint : Retention.checkpoint;
  compacted_event_id : Ledger.Event_id.t;
  ledger_envelope : Envelope.t;
}

type compaction_plan = {
  source_ref : Ledger.Ref_name.t;
  source_head : Ledger.Event_id.t;
  source_generation_head : Ledger.Event_id.t option;
  source_protection_head : Ledger.Event_id.t option;
  compaction_retention : Retention.plan;
  compacted_events : compacted_event list;
  compaction_generation_manifest : Retention.generation;
  generation_object_ref : V2_model.Opaque_object_ref.t;
  generation_envelope : Envelope.t;
  activation_event_id : Ledger.Event_id.t;
  activation_envelope : Envelope.t;
}
(** A complete immutable write set. Its compacted ledger events must all be
    durable before [activation_envelope] is published; only the latter changes
    the active scratch scope. *)

type compaction_publication = {
  published_generation_event_id : Ledger.Event_id.t;
  published_generation_manifest : Retention.generation;
  published_retention : Retention.plan;
}

module Fault : sig
  type boundary = Before_candidate of int | After_candidate of int
  type t

  val before_candidate : int -> t
  val after_candidate : int -> t
end

type cleanup_metric = {
  cleanup_candidate : Retention.cleanup_candidate;
  stored_bytes : int64;
}

type cleanup_report = {
  cleanup_generation_event_id : Ledger.Event_id.t;
  quarantined_objects : int;
  quarantined_bytes : int64;
  pruned_objects : int;
  pruned_bytes : int64;
  already_quarantined_objects : int;
  already_pruned_objects : int;
  quarantined_candidates : cleanup_metric list;
  pruned_candidates : cleanup_metric list;
  already_quarantined_candidates : Retention.cleanup_candidate list;
  already_pruned_candidates : Retention.cleanup_candidate list;
}
(** Observed local maintenance only. It is not a canonical object, ledger
    record, or claim that cleanup completed. *)

type protection_plan = {
  protection_checkpoint_event_id : Ledger.Event_id.t;
  protection_snapshot_ref : V2_model.Opaque_object_ref.t;
  protection_predecessor : Ledger.Event_id.t option;
  protection_record : Retention.protection;
  protection_object_ref : V2_model.Opaque_object_ref.t;
  protection_envelope : Envelope.t;
  protection_event_id : Ledger.Event_id.t;
  protection_ledger_envelope : Envelope.t;
}
(** An immutable claim-frame and its causal ledger event. The claim remains
    inert until [protection_ledger_envelope] is published. *)

type protection_publication = {
  published_protection_event_id : Ledger.Event_id.t;
  published_protection : Retention.protection;
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
  | Generation_event_missing_target of Ledger.Event_id.t
  | Generation_target_not_manifest of {
      event_id : Ledger.Event_id.t;
      object_ref : V2_model.Opaque_object_ref.t;
    }
  | Missing_evaluated_generation of Ledger.Event_id.t
  | Divergent_generation_heads of Ledger.Event_id.t list
  | Generation_source_ref_mismatch of {
      event_id : Ledger.Event_id.t;
      expected : Ledger.Ref_name.t;
      actual : Ledger.Ref_name.t;
    }
  | Generation_active_ref_mismatch of {
      event_id : Ledger.Event_id.t;
      expected : Ledger.Ref_name.t;
      actual : Ledger.Ref_name.t;
    }
  | Generation_active_anchor_not_reachable of {
      event_id : Ledger.Event_id.t;
      expected : Ledger.Event_id.t;
      actual : Ledger.Event_id.t list;
    }
  | Protection_event_missing_target of Ledger.Event_id.t
  | Protection_target_not_claim of {
      event_id : Ledger.Event_id.t;
      object_ref : V2_model.Opaque_object_ref.t;
    }
  | Missing_evaluated_protection of Ledger.Event_id.t
  | Divergent_protection_heads of Ledger.Event_id.t list
  | Nonce_reuse
  | Retention_error of Retention.error
  | Invalid_compaction_nonce_count of { expected : int; actual : int }
  | Compaction_nonce_reuse
  | Compaction_source_not_active of {
      expected : Ledger.Ref_name.t;
      actual : Ledger.Ref_name.t;
    }
  | Compaction_source_head_changed of {
      expected : Ledger.Event_id.t;
      actual : Ledger.Event_id.t;
    }
  | Compaction_generation_head_changed of {
      expected : Ledger.Event_id.t option;
      actual : Ledger.Event_id.t option;
    }
  | Compaction_protection_head_changed of {
      expected : Ledger.Event_id.t option;
      actual : Ledger.Event_id.t option;
    }
  | Protection_nonce_reuse
  | Protection_head_changed of {
      expected : Ledger.Event_id.t option;
      actual : Ledger.Event_id.t option;
    }
  | Active_generation_required
  | Cleanup_keep_set_overlap of Retention.cleanup_candidate
  | Cleanup_generation_changed of {
      expected : Ledger.Event_id.t;
      actual : Ledger.Event_id.t;
    }
  | Cleanup_fault_injected of Fault.boundary

val error_to_string : error -> string

val open_repository :
  root:string ->
  bootstrap_repository:Bootstrap_store.repository ->
  (repository, error) result
(** Reopens and validates [root] with the injected capability from the supplied
    bootstrap repository, so a repository handle cannot be transplanted to a
    different root without passing its own bootstrap validation. *)

val scratch_ref_name : repository -> Ledger.Ref_name.t
(** The device's immutable base scratch scope, not a mutable active ref. *)

val generation_ref_name : repository -> Ledger.Ref_name.t
val protection_ref_name : repository -> Ledger.Ref_name.t

val compact_ref_name :
  repository ->
  source_head:Ledger.Event_id.t ->
  (Ledger.Ref_name.t, error) result

val active_scratch_ref_name : repository -> (Ledger.Ref_name.t, error) result
(** Read-only. A missing generation scope selects the base scratch ref. A sole
    verified generation head selects only its verified compact scope; malformed
    or divergent generation history is an explicit error. *)

val inspect : repository -> (inspection, error) result
(** Read-only. It resolves the active scope before verifying its typed ledger
    frames and rejects invalid scratch targets. *)

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

val plan_compaction :
  repository ->
  policy:Retention.policy ->
  nonces:compaction_nonces ->
  (compaction_plan, error) result
(** Selects the active sole causal history, folds the sole protection history,
    measures exact encrypted source-object bytes, and constructs a compact
    replacement chain. It writes nothing. The returned plan includes no cleanup
    action: source objects remain durable until a later explicit quarantine
    operation. *)

val publish_compaction_plan :
  repository -> compaction_plan -> (compaction_publication, error) result
(** Publishes replacement ledger events and the generation frame before the
    generation activation event. It rechecks the source, generation, and
    protection heads immediately before activation. An interruption before
    activation leaves the prior scope active and the plan can be retried. *)

val resume_cleanup :
  ?fault:Fault.t -> repository -> (cleanup_report, error) result
(** Revalidates the sole active generation and every manifest candidate, then
    moves only the verified retired objects into its no-overwrite local
    quarantine. The physical destination is the retry state; no cleanup cursor
    is persisted. *)

val prune_quarantine :
  ?fault:Fault.t -> repository -> (cleanup_report, error) result
(** Revalidates the sole active generation and permanently removes only its
    already quarantined verified candidates. It never falls back to deleting a
    live object. *)

val plan_protection :
  repository ->
  event_id:Ledger.Event_id.t ->
  action:Retention.protection_action ->
  reason:Retention.protection_reason ->
  protection_nonce:Envelope.nonce ->
  ledger_nonce:Envelope.nonce ->
  (protection_plan, error) result
(** Creates a claim for the exact snapshot named by one currently active scratch
    event. It writes nothing and does not infer a checkpoint. *)

val publish_protection_plan :
  repository -> protection_plan -> (protection_publication, error) result
(** Publishes the immutable protection frame before its causal ledger event.
    Before the ledger write it rechecks that the named scratch event remains
    active and that the protection head has not changed. *)
