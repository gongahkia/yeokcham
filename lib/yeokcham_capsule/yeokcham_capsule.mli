type path = Yeokcham_scratch.path
type entry = Yeokcham_scratch.entry

type dependency =
  | Requires_capsule of {
      capsule : Yeokcham_id.Capsule_id.t;
      revision : Yeokcham_id.Capsule_revision_id.t option;
    }
  | Requires_release of Yeokcham_id.Release_id.t
  | Conflicts_with_capsule of Yeokcham_id.Capsule_id.t
  | Ordered_after of Yeokcham_id.Capsule_id.t

type exact_file_transition = {
  transition_path : path;
  expected_entry : entry option;
  replacement_entry : entry option;
}

type text_anchor = {
  before_context : string;
  selected : string;
  after_context : string;
}

type text_edit = {
  edit_path : path;
  anchor : text_anchor;
  replacement : string;
  fallback_transition : exact_file_transition;
}

type operation =
  | Exact_file_transition of exact_file_transition
  | Text_edit of text_edit
  | Move of { source : path; destination : path; prior : entry }
  | Mode_change of {
      path : path;
      expected : Yeokcham_snapshot.file_mode;
      replacement : Yeokcham_snapshot.file_mode;
    }

type validation_status = Passed | Failed of int | Timed_out | Not_run

type validation_evidence = {
  command : string list;
  environment_fingerprint : string option;
  snapshot : Yeokcham_snapshot.Snapshot.id;
  status : validation_status;
  stdout_digest : Yeokcham_snapshot.Content.id option;
  stderr_digest : Yeokcham_snapshot.Content.id option;
  started_at : int64;
  duration_ms : int64;
}

type construction_error =
  | Invalid_capsule_id_length of int
  | Invalid_revision_id_length of int
  | Empty_title
  | Invalid_title_utf8 of int
  | Invalid_description_utf8 of int
  | Revision_cannot_parent_itself

val construction_error_to_string : construction_error -> string

type capsule
type revision

val create :
  id:Yeokcham_id.Capsule_id.t ->
  title:string ->
  description:string ->
  dependencies:dependency list ->
  (capsule, construction_error) result

val id : capsule -> Yeokcham_id.Capsule_id.t
val title : capsule -> string
val description : capsule -> string
val dependencies : capsule -> dependency list

val create_revision :
  id:Yeokcham_id.Capsule_revision_id.t ->
  capsule:capsule ->
  parent:Yeokcham_id.Capsule_revision_id.t option ->
  declared_base:Yeokcham_snapshot.Snapshot.id ->
  operations:operation list ->
  expected_result:Yeokcham_snapshot.Snapshot.id option ->
  evidence:validation_evidence list ->
  created_at:int64 ->
  (revision, construction_error) result

val revision_id : revision -> Yeokcham_id.Capsule_revision_id.t
val revision_capsule : revision -> Yeokcham_id.Capsule_id.t
val revision_parent : revision -> Yeokcham_id.Capsule_revision_id.t option
val revision_declared_base : revision -> Yeokcham_snapshot.Snapshot.id
val revision_operations : revision -> operation list
val revision_expected_result : revision -> Yeokcham_snapshot.Snapshot.id option
val revision_evidence : revision -> validation_evidence list
val revision_created_at : revision -> int64

type application_conflict =
  | Declared_base_mismatch of {
      expected : Yeokcham_snapshot.Snapshot.id;
      actual : Yeokcham_snapshot.Snapshot.id;
    }
  | Exact_transition_rejected of {
      operation_index : int;
      path : path;
      detail : string;
    }
  | Text_fallback_required of { operation_index : int; edit : text_edit }
  | Move_rejected of {
      operation_index : int;
      source : path;
      destination : path;
      detail : string;
    }
  | Mode_change_rejected of {
      operation_index : int;
      path : path;
      detail : string;
    }

type operation_outcome =
  | Applied_exactly of int
  | Application_conflict of application_conflict

type application_result = {
  state : Yeokcham_scratch.State.t;
  outcomes : operation_outcome list;
  conflicts : application_conflict list;
}

val application_conflict_to_string : application_conflict -> string

val apply :
  actual_base:Yeokcham_snapshot.Snapshot.id ->
  state:Yeokcham_scratch.State.t ->
  revision ->
  application_result

val apply_text_fallback :
  Yeokcham_scratch.State.t ->
  text_edit ->
  (Yeokcham_scratch.State.t, string) result

module Draft : sig
  type error
  type t

  val error_to_string : error -> string

  val operations_between :
    from:Yeokcham_scratch.State.t ->
    to_:Yeokcham_scratch.State.t ->
    (operation list, error) result

  val from_checkpoints :
    store:Yeokcham_store.repository ->
    scratch:Yeokcham_scratch.repository ->
    capsule:capsule ->
    revision_id:Yeokcham_id.Capsule_revision_id.t ->
    from:Yeokcham_scratch.Checkpoint_id.t ->
    target:Yeokcham_scratch.Checkpoint_id.t ->
    evidence:validation_evidence list ->
    created_at:int64 ->
    (t, error) result

  val source_checkpoint : t -> Yeokcham_scratch.Checkpoint_id.t
  val target_checkpoint : t -> Yeokcham_scratch.Checkpoint_id.t
  val source_snapshot : t -> Yeokcham_snapshot.Snapshot.id
  val target_snapshot : t -> Yeokcham_snapshot.Snapshot.id
  val revision : t -> revision

  val pin_boundaries :
    Yeokcham_scratch.repository -> t -> changed_at:int64 -> (unit, error) result
end

module Parent_resolver : sig
  type node = {
    revision : Yeokcham_id.Capsule_revision_id.t;
    capsule : Yeokcham_id.Capsule_id.t;
    parent : Yeokcham_id.Capsule_revision_id.t option;
  }

  type error =
    | Duplicate_revision of Yeokcham_id.Capsule_revision_id.t
    | Unknown_revision of Yeokcham_id.Capsule_revision_id.t
    | Parent_capsule_mismatch of {
        parent : Yeokcham_id.Capsule_revision_id.t;
        expected_capsule : Yeokcham_id.Capsule_id.t;
        actual_capsule : Yeokcham_id.Capsule_id.t;
      }
    | Cycle of Yeokcham_id.Capsule_revision_id.t

  val error_to_string : error -> string

  val history :
    nodes:node list ->
    capsule:Yeokcham_id.Capsule_id.t ->
    current:Yeokcham_id.Capsule_revision_id.t ->
    (node list, error) result
end

module Catalog : sig
  type t

  type error =
    | Capsule_id_collision of Yeokcham_id.Capsule_id.t
    | Unknown_capsule of Yeokcham_id.Capsule_id.t
    | Revision_id_collision of Yeokcham_id.Capsule_revision_id.t
    | Unknown_parent_revision of Yeokcham_id.Capsule_revision_id.t
    | Parent_capsule_mismatch of {
        parent : Yeokcham_id.Capsule_revision_id.t;
        expected_capsule : Yeokcham_id.Capsule_id.t;
        actual_capsule : Yeokcham_id.Capsule_id.t;
      }
    | Unknown_revision of Yeokcham_id.Capsule_revision_id.t
    | Revision_capsule_mismatch of {
        revision : Yeokcham_id.Capsule_revision_id.t;
        expected_capsule : Yeokcham_id.Capsule_id.t;
        actual_capsule : Yeokcham_id.Capsule_id.t;
      }

  type revision_diff = {
    from_revision : Yeokcham_id.Capsule_revision_id.t;
    to_revision : Yeokcham_id.Capsule_revision_id.t;
    declared_base_changed : bool;
    expected_result_changed : bool;
    from_operations : operation list;
    to_operations : operation list;
  }

  val error_to_string : error -> string
  val empty : t
  val add_capsule : t -> capsule -> (t, error) result
  val add_revision : t -> revision -> (t, error) result

  val select_current :
    t ->
    capsule:Yeokcham_id.Capsule_id.t ->
    revision:Yeokcham_id.Capsule_revision_id.t ->
    (t, error) result

  val find_capsule : t -> Yeokcham_id.Capsule_id.t -> capsule option
  val find_revision : t -> Yeokcham_id.Capsule_revision_id.t -> revision option
  val current_revision : t -> Yeokcham_id.Capsule_id.t -> revision option
  val history : t -> Yeokcham_id.Capsule_id.t -> (revision list, error) result

  val diff :
    t ->
    from:Yeokcham_id.Capsule_revision_id.t ->
    to_:Yeokcham_id.Capsule_revision_id.t ->
    (revision_diff, error) result
end
