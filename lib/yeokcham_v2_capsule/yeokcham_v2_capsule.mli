(** Pure V2 byte-exact capsule proposals and immutable initial records.

    A proposal is a structural delta between two exact snapshots. It makes no
    statement about user intent, grouping, or semantic equivalence. *)

module Model = Yeokcham_model
module V2_model = Yeokcham_v2_model

type snapshot_link = {
  snapshot_id : Yeokcham_id.Snapshot_id.t;
  snapshot_ref : V2_model.Opaque_object_ref.t;
}

type source_boundary = {
  source_snapshot : snapshot_link;
  target_snapshot : snapshot_link;
}

type revision_link

type provenance =
  | Created
  | Folded of revision_link
  | Split_from of revision_link list
  | Combined_from of revision_link list

type proposal
type selection
type capsule
type revision
type proposal_error = Derived_replay_mismatch

type selection_error =
  | Empty_selection
  | Unsorted_selection of { previous : int; current : int }
  | Selection_index_out_of_bounds of { index : int; operation_count : int }
  | Selected_operation_rejected of {
      proposal_index : int;
      cause : Model.transition_error;
    }

type error =
  | Invalid_title of Yeokcham_encoding.construction_error
  | Invalid_description of Yeokcham_encoding.construction_error
  | Declared_base_identity_mismatch
  | Expected_result_identity_mismatch
  | Boundary_base_mismatch
  | Boundary_target_mismatch
  | Selection_base_mismatch
  | Parent_capsule_mismatch
  | Empty_source_boundaries
  | Invalid_provenance of string
  | Revision_replay_rejected of Model.replay_error
  | Invalid_payload of string
  | Unsupported_schema_version of int64
  | Unsupported_mandatory_features of int64
  | Invalid_mandatory_features of int64
  | Noncanonical_record

val proposal_error_to_string : proposal_error -> string
val selection_error_to_string : selection_error -> string
val error_to_string : error -> string

val propose :
  from:Model.Snapshot.t ->
  to_:Model.Snapshot.t ->
  (proposal, proposal_error) result
(** Produces a deterministic exact structural delta. It never derives moves,
    semantic edits, or suggested intent. *)

val proposal_operations : proposal -> Model.scratch_operation list
val proposal_from_snapshot : proposal -> Model.Snapshot.t
val proposal_to_snapshot : proposal -> Model.Snapshot.t

val select : proposal -> indices:int list -> (selection, selection_error) result
(** Selection preserves caller-supplied ascending proposal order. A subset that
    cannot replay from the source snapshot is an explicit conflict. *)

val selected_indices : selection -> int list
val selected_operations : selection -> Model.scratch_operation list
val selected_result : selection -> Model.Snapshot.t

val make_capsule :
  id:V2_model.Capsule_id.t ->
  title:string ->
  description:string ->
  created_at:int64 ->
  (capsule, error) result

val capsule_id : capsule -> V2_model.Capsule_id.t
val capsule_title : capsule -> string
val capsule_description : capsule -> string
val capsule_created_at : capsule -> int64

val make_initial_revision :
  capsule:capsule ->
  capsule_ref:V2_model.Opaque_object_ref.t ->
  declared_base:snapshot_link ->
  declared_base_snapshot:Model.Snapshot.t ->
  expected_result:snapshot_link ->
  selected:selection ->
  source_boundary:source_boundary ->
  (revision, error) result
(** Makes a complete immutable initial revision. Its identity is derived from
    the capsule ID, logical snapshot IDs, selected operation bytes, and ordered
    source snapshot boundaries; encrypted object references are verified links,
    not logical revision identity. *)

val revision_id : revision -> V2_model.Capsule_revision_id.t
val revision_capsule_id : revision -> V2_model.Capsule_id.t
val revision_capsule_ref : revision -> V2_model.Opaque_object_ref.t
val revision_declared_base : revision -> snapshot_link
val revision_expected_result : revision -> snapshot_link
val revision_operations : revision -> Model.scratch_operation list
val revision_source_boundary : revision -> source_boundary
val revision_source_boundaries : revision -> source_boundary list
val revision_parent : revision -> revision_link option
val revision_provenance : revision -> provenance
val revision_created_at : revision -> int64 option

val make_revision_link :
  capsule_id:V2_model.Capsule_id.t ->
  revision_id:V2_model.Capsule_revision_id.t ->
  revision_ref:V2_model.Opaque_object_ref.t ->
  revision_link

val revision_link_capsule_id : revision_link -> V2_model.Capsule_id.t
val revision_link_revision_id : revision_link -> V2_model.Capsule_revision_id.t
val revision_link_ref : revision_link -> V2_model.Opaque_object_ref.t

val make_revision :
  capsule:capsule ->
  capsule_ref:V2_model.Opaque_object_ref.t ->
  parent:revision_link option ->
  declared_base:snapshot_link ->
  declared_base_snapshot:Model.Snapshot.t ->
  expected_result:snapshot_link ->
  operations:Model.scratch_operation list ->
  source_boundaries:source_boundary list ->
  provenance:provenance ->
  created_at:int64 ->
  (revision, error) result
(** Makes a version-2 complete revision. It retains immutable parent and
    provenance links but still replays directly from [declared_base]. *)

val apply_revision :
  base:Model.Snapshot.t ->
  revision ->
  (Model.Snapshot.t, Model.replay_error) result

val encode_capsule : capsule -> string
val decode_capsule : string -> (capsule, error) result
val encode_revision : revision -> string
val decode_revision : string -> (revision, error) result
