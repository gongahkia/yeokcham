(** Durable local cache reclamation from ADR-063. *)

module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Reclamation = Yeokcham_v2_reclamation

type repository
type publication = Manifest_published | Manifest_already_published

module Fault : sig
  type boundary = Before_candidate of int | After_candidate of int
  type t

  val before_candidate : int -> t
  val after_candidate : int -> t
end

type cleanup_report = {
  plan_id : string;
  quarantined_objects : int;
  quarantined_bytes : int64;
  already_quarantined_objects : int;
  pruned_objects : int;
  pruned_bytes : int64;
  already_pruned_objects : int;
}

type error =
  | Bootstrap_store_error of Bootstrap_store.error
  | Bootstrap_error of Yeokcham_v2_bootstrap.error
  | Object_store_error of Yeokcham_v2_object_store.error
  | Ledger_store_error of Yeokcham_v2_ledger_store.error
  | Restore_journal_store_error of Yeokcham_v2_restore_journal_store.error
  | Transaction_store_error of Yeokcham_v2_transaction_store.error
  | Scratch_store_error of Yeokcham_v2_scratch_store.error
  | Publication_guard_error of Yeokcham_v2_publication_guard.error
  | Reclamation_error of Reclamation.error
  | Io_error of { operation : string; path : string; message : string }
  | Invalid_manifest_path of string
  | Manifest_collision of string
  | Manifest_changed of string
  | Missing_manifest of string
  | Stale_manifest of {
      expected_root_digest : string;
      actual_root_digest : string;
    }
  | Stale_plan of { expected_plan_id : string; actual_plan_id : string }
  | Unknown_ledger_scope of string
  | Divergent_ledger_scope of string
  | Ledger_event_id_collision of Yeokcham_v2_model.Ref_event_id.t
  | Missing_ledger_event of Yeokcham_v2_model.Ref_event_id.t
  | Active_generation_target_not_manifest of
      Yeokcham_v2_model.Opaque_object_ref.t
  | Active_generation_ref_invalid of string
  | Ledger_root_missing_target of {
      scope : string;
      event : Yeokcham_v2_ledger.Event_id.t;
    }
  | Candidate_became_reachable of Yeokcham_v2_model.Opaque_object_ref.t
  | Candidate_changed of Yeokcham_v2_model.Opaque_object_ref.t
  | Direct_link_kind_mismatch of {
      source : Yeokcham_v2_model.Opaque_object_ref.t;
      target : Yeokcham_v2_model.Opaque_object_ref.t;
      expected : Yeokcham_v2_object.kind;
      actual : Yeokcham_v2_object.kind;
    }
  | Fault_injected of Fault.boundary

val error_to_string : error -> string

val open_repository :
  root:string ->
  bootstrap_repository:Bootstrap_store.repository ->
  (repository, error) result

val plan :
  repository -> cache_budget_bytes:int64 -> (Reclamation.plan, error) result
(** Performs a complete authenticated mark while holding the exclusive guard. *)

val manifest_path : repository -> plan_id:string -> (string, error) result

val publish_manifest :
  repository -> Reclamation.plan -> (publication, error) result
(** Recomputes the authenticated plan under the exclusive guard before writing
    its local canonical manifest create-only. *)

val load_manifest :
  repository -> plan_id:string -> (Reclamation.plan, error) result

val resume_quarantine :
  ?fault:Fault.t ->
  repository ->
  plan_id:string ->
  (cleanup_report, error) result
(** Revalidates the manifest root digest under the exclusive guard and moves
    only its unmarked authenticated candidates to quarantine. *)

val prune_quarantine :
  ?fault:Fault.t ->
  repository ->
  plan_id:string ->
  (cleanup_report, error) result
(** Permanently removes only authenticated candidates already in the named
    quarantine after a fresh complete root-digest check. *)
