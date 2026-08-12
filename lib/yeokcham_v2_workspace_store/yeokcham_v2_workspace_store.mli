(** Durable V2 workspaces with explicit conflict and skip-resolution records. *)

module Capsule = Yeokcham_v2_capsule
module Capsule_store = Yeokcham_v2_capsule_store
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_model
module Record = Yeokcham_v2_workspace_record
module V2_model = Yeokcham_v2_model
module Workspace = Yeokcham_v2_workspace

type repository

type create_nonces = {
  create_workspace_nonce : Envelope.nonce;
  create_revision_nonce : Envelope.nonce;
  create_binding_nonce : Envelope.nonce;
}

type attempt_nonces = {
  attempt_result_nonce : Envelope.nonce;
  conflict_nonces : Envelope.nonce list;
  attempt_nonce : Envelope.nonce;
  attempt_binding_nonce : Envelope.nonce;
}

type resolution_nonces = {
  resolve_resolution_nonce : Envelope.nonce;
  resolve_revision_nonce : Envelope.nonce;
  resolve_binding_nonce : Envelope.nonce;
}

module Fault : sig
  type boundary =
    | After_workspace_object
    | After_workspace_revision
    | After_attempt_result
    | After_conflict_objects
    | After_attempt_object
    | After_resolution_object
    | After_resolution_revision
    | Before_binding

  type t

  val at : boundary -> t
end

type resolved = {
  workspace : Record.workspace;
  workspace_ref : V2_model.Opaque_object_ref.t;
  revision : Record.workspace_revision;
  revision_ref : V2_model.Opaque_object_ref.t;
  workspace_binding_event_id : Ledger.Event_id.t;
  base_snapshot : Model.Snapshot.t;
  order : Workspace.order;
  application : Workspace.application;
}

type resolved_attempt = {
  attempt : Record.workspace_attempt;
  attempt_ref : V2_model.Opaque_object_ref.t;
  attempt_binding_event_id : Ledger.Event_id.t;
}

type publication = Published of resolved | Already_published of resolved

type attempt_publication =
  | Attempt_published of resolved_attempt
  | Attempt_already_published of resolved_attempt

type error =
  | Bootstrap_store_error of Yeokcham_v2_bootstrap_store.error
  | Capsule_store_error of Capsule_store.error
  | Envelope_error of Envelope.error
  | Ledger_error of Ledger.error
  | Ledger_store_error of Yeokcham_v2_ledger_store.error
  | Object_store_error of Yeokcham_v2_object_store.error
  | Record_error of Record.error
  | Workspace_error of Workspace.error
  | Invalid_workspace_ref_name of string
  | Invalid_attempt_ref_name of string
  | Nonce_reuse
  | Conflict_nonce_count_mismatch of { expected : int; actual : int }
  | Workspace_id_already_bound of V2_model.Workspace_id.t
  | Workspace_missing of V2_model.Workspace_id.t
  | Divergent_workspace_binding of Ledger.Event_id.t list
  | Workspace_binding_missing_target of Ledger.Event_id.t
  | Binding_target_not_workspace_revision of V2_model.Opaque_object_ref.t
  | Workspace_revision_link_mismatch of string
  | Workspace_metadata_mismatch
  | Snapshot_ref_not_snapshot of V2_model.Opaque_object_ref.t
  | Snapshot_identity_mismatch of V2_model.Opaque_object_ref.t
  | Revision_order_mismatch
  | Resolution_link_mismatch of string
  | Conflict_link_mismatch of string
  | Conflict_not_in_workspace of V2_model.Conflict_id.t
  | Attempt_id_already_bound of V2_model.Workspace_attempt_id.t
  | Attempt_binding_missing_target of Ledger.Event_id.t
  | Binding_target_not_workspace_attempt of V2_model.Opaque_object_ref.t
  | Attempt_link_mismatch of string
  | Concurrent_current_update of {
      expected_revision : V2_model.Workspace_revision_id.t;
      expected_binding : Ledger.Event_id.t;
      actual_revision : V2_model.Workspace_revision_id.t option;
      actual_binding : Ledger.Event_id.t option;
    }
  | Fault_injected of Fault.boundary

val error_to_string : error -> string

val open_repository :
  root:string ->
  bootstrap_repository:Yeokcham_v2_bootstrap_store.repository ->
  (repository, error) result

val workspace_ref_name :
  V2_model.Workspace_id.t -> (Ledger.Ref_name.t, error) result

val attempt_ref_name :
  workspace:V2_model.Workspace_id.t ->
  attempt:V2_model.Workspace_attempt_id.t ->
  (Ledger.Ref_name.t, error) result

val create :
  ?fault:Fault.t ->
  repository ->
  id:V2_model.Workspace_id.t ->
  title:string ->
  description:string ->
  base:Capsule.snapshot_link ->
  selected:Capsule.revision_link list ->
  precedence:Workspace.precedence list ->
  created_at:int64 ->
  nonces:create_nonces ->
  (publication, error) result
(** Persists a workspace and its initial immutable revision before creating the
    sole signed workspace-head binding. All selected revision links are
    independently verified; caller ordering is not authoritative. *)

val resolve :
  repository -> id:V2_model.Workspace_id.t -> (resolved option, error) result
(** Verifies the sole signed workspace head, every selected capsule revision,
    every bound resolution, and direct deterministic workspace replay. *)

val load_revision_link :
  repository ->
  Record.workspace_revision_link ->
  (Record.workspace_revision, error) result
(** Loads one exact immutable workspace revision link without resolving a
    mutable workspace head. The caller remains responsible for verifying any
    larger context that names the revision. *)

val attempt :
  ?fault:Fault.t ->
  repository ->
  id:V2_model.Workspace_id.t ->
  expected_revision:V2_model.Workspace_revision_id.t ->
  expected_binding:Ledger.Event_id.t ->
  created_at:int64 ->
  nonces:attempt_nonces ->
  (attempt_publication, error) result
(** Persists one immutable partial attempt, its exact result snapshot when
    needed, and every explicit conflict before publishing an expected-absent
    signed attempt binding. *)

val resolve_attempt :
  repository ->
  workspace:V2_model.Workspace_id.t ->
  attempt:V2_model.Workspace_attempt_id.t ->
  (resolved_attempt option, error) result

val resolve_skip :
  ?fault:Fault.t ->
  repository ->
  id:V2_model.Workspace_id.t ->
  expected_revision:V2_model.Workspace_revision_id.t ->
  expected_binding:Ledger.Event_id.t ->
  conflict:Record.conflict_link ->
  created_at:int64 ->
  nonces:resolution_nonces ->
  (publication, error) result
(** Adds a new immutable workspace revision that binds one verified conflict to
    a skip-only resolution. It neither edits the operation nor chooses another
    operation as a replacement. *)
