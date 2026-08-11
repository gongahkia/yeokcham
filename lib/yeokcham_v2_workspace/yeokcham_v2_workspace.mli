(** Pure V2 workspace selection, order derivation, and exact composition.

    The core receives verified immutable capsule revisions from an adapter. It
    neither publishes objects nor chooses a resolution for the caller. *)

module Capsule = Yeokcham_v2_capsule
module Model = Yeokcham_model
module V2_model = Yeokcham_v2_model

type selected_revision = {
  link : Capsule.revision_link;
  capsule_revision : Capsule.revision;
}

type precedence = {
  before : V2_model.Capsule_revision_id.t;
  after : V2_model.Capsule_revision_id.t;
}

type order

type error =
  | Duplicate_capsule of V2_model.Capsule_id.t
  | Duplicate_revision of V2_model.Capsule_revision_id.t
  | Selection_link_mismatch of V2_model.Capsule_revision_id.t
  | Precedence_duplicate of precedence
  | Precedence_unknown of V2_model.Capsule_revision_id.t
  | Precedence_cycle of V2_model.Capsule_revision_id.t list

val error_to_string : error -> string

val derive_order :
  selected:selected_revision list ->
  precedence:precedence list ->
  (order, error) result
(** Canonicalises the selected revisions independently of caller ordering and
    applies only caller-provided precedence edges. Ties use revision identity.
*)

val ordered_revisions : order -> selected_revision list
val precedence_edges : order -> precedence list

type conflict = {
  revision : Capsule.revision_link;
  operation_index : int;
  paths : Model.Path.t list;
  cause : Model.transition_error;
}

type operation_outcome =
  | Applied_exactly of {
      revision : Capsule.revision_link;
      operation_index : int;
    }
  | Skipped_explicitly of {
      revision : Capsule.revision_link;
      operation_index : int;
    }
  | Conflict of conflict
  | Blocked_by_conflict of {
      revision : Capsule.revision_link;
      operation_index : int;
      blocked_by : conflict;
    }

type resolution_action =
  | Skip_operation of {
      revision : Capsule.revision_link;
      operation_index : int;
    }

type application = {
  resulting_snapshot : Model.Snapshot.t;
  outcomes : operation_outcome list;
  conflicts : conflict list;
}

val operation_paths : Model.scratch_operation -> Model.Path.t list

val apply :
  base:Model.Snapshot.t ->
  order:order ->
  resolutions:resolution_action list ->
  application
(** Applies individual exact operations in canonical workspace order. A failed
    operation becomes a conflict value; later operations with disjoint paths
    continue. A resolution may only skip the exact named operation. *)
