(** Durable V2 immutable releases and exact validation linkage from ADR-062. *)

module Capsule = Yeokcham_v2_capsule
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Record = Yeokcham_v2_release_record
module V2_model = Yeokcham_v2_model
module Workspace_record = Yeokcham_v2_workspace_record

type repository

type evidence_publication =
  | Evidence_published of {
      evidence : Record.validation_evidence;
      evidence_ref : V2_model.Opaque_object_ref.t;
    }
  | Evidence_already_published of {
      evidence : Record.validation_evidence;
      evidence_ref : V2_model.Opaque_object_ref.t;
    }

type nonces = { release_nonce : Envelope.nonce; binding_nonce : Envelope.nonce }

module Fault : sig
  type boundary = After_release_object | Before_binding
  type t

  val at : boundary -> t
end

type resolved = {
  release : Record.release;
  release_ref : V2_model.Opaque_object_ref.t;
  release_binding_event_id : Ledger.Event_id.t;
}

type publication = Published of resolved | Already_published of resolved

type error =
  | Bootstrap_store_error of Yeokcham_v2_bootstrap_store.error
  | Envelope_error of Envelope.error
  | Ledger_error of Ledger.error
  | Ledger_store_error of Yeokcham_v2_ledger_store.error
  | Object_store_error of Yeokcham_v2_object_store.error
  | Record_error of Record.error
  | Workspace_store_error of Yeokcham_v2_workspace_store.error
  | Publication_guard_error of Yeokcham_v2_publication_guard.error
  | Invalid_release_ref_name of string
  | Nonce_reuse
  | Divergent_release_binding of Ledger.Event_id.t list
  | Release_missing of V2_model.Release_id.t
  | Release_binding_missing_target of Ledger.Event_id.t
  | Binding_target_not_release of V2_model.Opaque_object_ref.t
  | Release_link_mismatch of string
  | Release_id_already_bound of V2_model.Release_id.t
  | Evidence_link_mismatch of string
  | Evidence_not_passed of V2_model.Validation_id.t
  | Workspace_attempt_missing of V2_model.Workspace_attempt_id.t
  | Workspace_attempt_link_mismatch of string
  | Workspace_revision_link_mismatch of string
  | Unresolved_conflicts of V2_model.Workspace_attempt_id.t
  | Release_reproduction_mismatch of string
  | Parent_cycle of V2_model.Release_id.t list
  | Fault_injected of Fault.boundary

val error_to_string : error -> string

val open_repository :
  root:string ->
  bootstrap_repository:Yeokcham_v2_bootstrap_store.repository ->
  (repository, error) result

val release_ref_name :
  V2_model.Release_id.t -> (Ledger.Ref_name.t, error) result

val publish_evidence :
  repository ->
  snapshot:Capsule.snapshot_link ->
  check_name:string ->
  status:Record.validation_status ->
  observed_at:int64 ->
  nonce:Envelope.nonce ->
  (evidence_publication, error) result
(** Persists one inspectable immutable observation. It does not claim that a
    process runner or reviewer produced the supplied status. *)

val resolve :
  repository -> id:V2_model.Release_id.t -> (resolved option, error) result
(** Verifies a signed release binding, its immutable workspace attempt replay,
    every validation link, and the complete parent closure. *)

val create :
  ?fault:Fault.t ->
  repository ->
  parents:Record.release_link list ->
  workspace:Workspace_record.workspace_revision_link ->
  attempt:Record.workspace_attempt_link ->
  evidence:Record.validation_evidence_link list ->
  message:string option ->
  created_at:int64 ->
  nonces:nonces ->
  (publication, error) result
(** Derives release composition from one exact verified attempt and workspace
    revision. All named immutable objects are checked before the release object
    is made visible by its create-only signed binding. *)
