(** Parser-free, ephemeral assistance for an existing open V1 decision.

    A ready proposal selects only an exact entry already present in its named
    base, left, or right snapshot. It is not a model transition, an intent
    claim, or a resolution. *)

type entry =
  | File of { mode : Yeokcham_snapshot.file_mode; content : string }
  | Directory

type tree
type source = Base | Left | Right

type conflict =
  | Competing_creation
  | Delete_modify
  | File_directory
  | Mode_mismatch
  | Content_mismatch
  | Mode_and_content_mismatch

type path_outcome =
  | Select of { source : source; entry : entry option }
  | Conflict of conflict
  | Unassessed_without_common_base

type path = {
  path : Yeokcham_v1_model.Path.t;
  base : entry option;
  left : entry option;
  right : entry option;
  outcome : path_outcome;
}

type provenance = {
  decision : Yeokcham_v1_model.Decision_id.t;
  current_baseline : Yeokcham_v1_model.Snapshot_id.t;
  left_revision : Yeokcham_v1_model.Revision_id.t;
  left_base : Yeokcham_v1_model.Snapshot_id.t;
  left_result : Yeokcham_v1_model.Snapshot_id.t;
  right_revision : Yeokcham_v1_model.Revision_id.t;
  right_base : Yeokcham_v1_model.Snapshot_id.t;
  right_result : Yeokcham_v1_model.Snapshot_id.t;
}

type refusal =
  | Same_candidate
  | Incompatible_bases of {
      left_base : Yeokcham_v1_model.Snapshot_id.t;
      right_base : Yeokcham_v1_model.Snapshot_id.t;
    }
  | Stale_base of {
      proposal_base : Yeokcham_v1_model.Snapshot_id.t;
      current_baseline : Yeokcham_v1_model.Snapshot_id.t;
    }
  | Conflicting_paths of Yeokcham_v1_model.Path.t list

type readiness = Ready | Refused of refusal list
type confidence = Exact_source | No_confidence

type t = {
  provenance : provenance;
  readiness : readiness;
  confidence : confidence;
  paths : path list;
}

type tree_error = Duplicate_path of Yeokcham_v1_model.Path.t

val tree_of_entries :
  (Yeokcham_v1_model.Path.t * entry) list -> (tree, tree_error) result

val classify :
  decision:Yeokcham_v1_model.Decision_id.t ->
  current_baseline:Yeokcham_v1_model.Snapshot_id.t ->
  left:Yeokcham_v1_model.change_revision ->
  right:Yeokcham_v1_model.change_revision ->
  base:tree ->
  left_tree:tree ->
  right_tree:tree ->
  t
(** Deterministically classifies a pair. The revision order is canonicalised by
    revision ID, so reversing user input describes the same proposal. *)

val selected :
  t -> (Yeokcham_v1_model.Path.t * source * entry option) list option
(** [Some] only for a ready proposal. A missing selected entry denotes an exact
    deletion. *)

val source_to_string : source -> string
val conflict_to_string : conflict -> string
val refusal_to_string : refusal -> string
val tree_error_to_string : tree_error -> string
