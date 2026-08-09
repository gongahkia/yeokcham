(** Durable V2 initial capsule curation over authenticated scratch snapshots. *)

module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Capsule = Yeokcham_v2_capsule
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_model
module V2_model = Yeokcham_v2_model

type repository

type nonces = {
  capsule_nonce : Envelope.nonce;
  selected_result_nonce : Envelope.nonce;
  revision_nonce : Envelope.nonce;
  source_protection_nonce : Envelope.nonce;
  source_protection_ledger_nonce : Envelope.nonce;
  target_protection_nonce : Envelope.nonce;
  target_protection_ledger_nonce : Envelope.nonce;
  binding_ledger_nonce : Envelope.nonce;
}

type revision_nonces = {
  fold_selected_result_nonce : Envelope.nonce;
  fold_revision_nonce : Envelope.nonce;
  fold_source_protection_nonce : Envelope.nonce;
  fold_source_protection_ledger_nonce : Envelope.nonce;
  fold_target_protection_nonce : Envelope.nonce;
  fold_target_protection_ledger_nonce : Envelope.nonce;
  fold_binding_ledger_nonce : Envelope.nonce;
}

module Fault : sig
  type boundary =
    | After_capsule_object
    | After_selected_result_object
    | After_revision_object
    | After_source_protection
    | After_target_protection
    | Before_binding

  type t

  val at : boundary -> t
end

type resolved = {
  capsule : Capsule.capsule;
  capsule_ref : V2_model.Opaque_object_ref.t;
  revision : Capsule.revision;
  revision_ref : V2_model.Opaque_object_ref.t;
  binding_event_id : Ledger.Event_id.t;
  declared_base : Model.Snapshot.t;
  expected_result : Model.Snapshot.t;
}

type publication = Published of resolved | Already_published of resolved

type error =
  | Bootstrap_store_error of Bootstrap_store.error
  | Capsule_error of Capsule.error
  | Capsule_proposal_error of Capsule.proposal_error
  | Capsule_selection_error of Capsule.selection_error
  | Envelope_error of Envelope.error
  | Ledger_error of Ledger.error
  | Ledger_store_error of Yeokcham_v2_ledger_store.error
  | Object_store_error of Yeokcham_v2_object_store.error
  | Scratch_store_error of Yeokcham_v2_scratch_store.error
  | Invalid_capsule_ref_name of string
  | Nonce_reuse
  | Capsule_id_already_bound of V2_model.Capsule_id.t
  | Divergent_capsule_binding of Ledger.Event_id.t list
  | Capsule_binding_missing_target of Ledger.Event_id.t
  | Capsule_binding_target_mismatch of {
      capsule : V2_model.Capsule_id.t;
      expected : V2_model.Opaque_object_ref.t;
      actual : V2_model.Opaque_object_ref.t;
    }
  | Binding_target_not_revision of V2_model.Opaque_object_ref.t
  | Revision_capsule_mismatch of {
      expected : V2_model.Capsule_id.t;
      actual : V2_model.Capsule_id.t;
    }
  | Revision_capsule_ref_mismatch of {
      expected : V2_model.Opaque_object_ref.t;
      actual : V2_model.Opaque_object_ref.t;
    }
  | Capsule_ref_not_capsule of V2_model.Opaque_object_ref.t
  | Capsule_metadata_mismatch
  | Snapshot_ref_not_snapshot of V2_model.Opaque_object_ref.t
  | Snapshot_identity_mismatch of V2_model.Opaque_object_ref.t
  | Revision_replay_rejected of Model.replay_error
  | Revision_result_mismatch
  | Concurrent_current_update of {
      expected_revision : V2_model.Capsule_revision_id.t;
      expected_binding : Ledger.Event_id.t;
      actual_revision : V2_model.Capsule_revision_id.t option;
      actual_binding : Ledger.Event_id.t option;
    }
  | Parent_link_mismatch of string
  | Revision_history_cycle of V2_model.Opaque_object_ref.t
  | Fault_injected of Fault.boundary

val error_to_string : error -> string

val open_repository :
  root:string ->
  bootstrap_repository:Bootstrap_store.repository ->
  (repository, error) result

val capsule_ref_name :
  V2_model.Capsule_id.t -> (Ledger.Ref_name.t, error) result

val create :
  ?fault:Fault.t ->
  repository ->
  id:V2_model.Capsule_id.t ->
  title:string ->
  description:string ->
  created_at:int64 ->
  source_event:Ledger.Event_id.t ->
  target_event:Ledger.Event_id.t ->
  selected_indices:int list ->
  nonces:nonces ->
  (publication, error) result
(** Curation derives a structural proposal from one verified causal scratch
    range. It publishes neither a capsule binding nor a mutable selection until
    the selected exact result and both source snapshot protections are durable.
*)

val resolve :
  repository -> id:V2_model.Capsule_id.t -> (resolved option, error) result
(** Reads a sole verified capsule binding and replays the immutable initial
    revision. A malformed or divergent binding is an explicit error. *)

val fold :
  ?fault:Fault.t ->
  repository ->
  id:V2_model.Capsule_id.t ->
  expected_revision:V2_model.Capsule_revision_id.t ->
  expected_binding:Ledger.Event_id.t ->
  source_event:Ledger.Event_id.t ->
  target_event:Ledger.Event_id.t ->
  selected_indices:int list ->
  created_at:int64 ->
  nonces:revision_nonces ->
  (publication, error) result
(** Adds one complete immutable child revision. The source checkpoint must
    equal the expected current revision result; a stale current ref is an
    explicit concurrent-update error. *)
