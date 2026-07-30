type path = Paengi_scratch.path
type entry = Paengi_scratch.entry

type dependency =
  | Requires_capsule of {
      capsule : Paengi_id.Capsule_id.t;
      revision : Paengi_id.Capsule_revision_id.t option;
    }
  | Requires_release of Paengi_id.Release_id.t
  | Conflicts_with_capsule of Paengi_id.Capsule_id.t
  | Ordered_after of Paengi_id.Capsule_id.t

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
      expected : Paengi_snapshot.file_mode;
      replacement : Paengi_snapshot.file_mode;
    }

type validation_status = Passed | Failed of int | Timed_out | Not_run

type validation_evidence = {
  command : string list;
  environment_fingerprint : string option;
  snapshot : Paengi_snapshot.Snapshot.id;
  status : validation_status;
  stdout_digest : Paengi_snapshot.Content.id option;
  stderr_digest : Paengi_snapshot.Content.id option;
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
  id:Paengi_id.Capsule_id.t ->
  title:string ->
  description:string ->
  dependencies:dependency list ->
  (capsule, construction_error) result

val id : capsule -> Paengi_id.Capsule_id.t
val title : capsule -> string
val description : capsule -> string
val dependencies : capsule -> dependency list

val create_revision :
  id:Paengi_id.Capsule_revision_id.t ->
  capsule:capsule ->
  parent:Paengi_id.Capsule_revision_id.t option ->
  declared_base:Paengi_snapshot.Snapshot.id ->
  operations:operation list ->
  expected_result:Paengi_snapshot.Snapshot.id option ->
  evidence:validation_evidence list ->
  created_at:int64 ->
  (revision, construction_error) result

val revision_id : revision -> Paengi_id.Capsule_revision_id.t
val revision_capsule : revision -> Paengi_id.Capsule_id.t
val revision_parent : revision -> Paengi_id.Capsule_revision_id.t option
val revision_declared_base : revision -> Paengi_snapshot.Snapshot.id
val revision_operations : revision -> operation list
val revision_expected_result : revision -> Paengi_snapshot.Snapshot.id option
val revision_evidence : revision -> validation_evidence list
val revision_created_at : revision -> int64

type application_conflict =
  | Declared_base_mismatch of {
      expected : Paengi_snapshot.Snapshot.id;
      actual : Paengi_snapshot.Snapshot.id;
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
  state : Paengi_scratch.State.t;
  outcomes : operation_outcome list;
  conflicts : application_conflict list;
}

val application_conflict_to_string : application_conflict -> string

val apply :
  actual_base:Paengi_snapshot.Snapshot.id ->
  state:Paengi_scratch.State.t ->
  revision ->
  application_result

val apply_text_fallback :
  Paengi_scratch.State.t -> text_edit -> (Paengi_scratch.State.t, string) result

module Draft : sig
  type error
  type t

  val error_to_string : error -> string

  val operations_between :
    from:Paengi_scratch.State.t ->
    to_:Paengi_scratch.State.t ->
    (operation list, error) result

  val from_checkpoints :
    store:Paengi_store.repository ->
    scratch:Paengi_scratch.repository ->
    capsule:capsule ->
    revision_id:Paengi_id.Capsule_revision_id.t ->
    from:Paengi_scratch.Checkpoint_id.t ->
    target:Paengi_scratch.Checkpoint_id.t ->
    evidence:validation_evidence list ->
    created_at:int64 ->
    (t, error) result

  val source_checkpoint : t -> Paengi_scratch.Checkpoint_id.t
  val target_checkpoint : t -> Paengi_scratch.Checkpoint_id.t
  val source_snapshot : t -> Paengi_snapshot.Snapshot.id
  val target_snapshot : t -> Paengi_snapshot.Snapshot.id
  val revision : t -> revision

  val pin_boundaries :
    Paengi_scratch.repository -> t -> changed_at:int64 -> (unit, error) result
end

module Parent_resolver : sig
  type node = {
    revision : Paengi_id.Capsule_revision_id.t;
    capsule : Paengi_id.Capsule_id.t;
    parent : Paengi_id.Capsule_revision_id.t option;
  }

  type error =
    | Duplicate_revision of Paengi_id.Capsule_revision_id.t
    | Unknown_revision of Paengi_id.Capsule_revision_id.t
    | Parent_capsule_mismatch of {
        parent : Paengi_id.Capsule_revision_id.t;
        expected_capsule : Paengi_id.Capsule_id.t;
        actual_capsule : Paengi_id.Capsule_id.t;
      }
    | Cycle of Paengi_id.Capsule_revision_id.t

  val error_to_string : error -> string

  val history :
    nodes:node list ->
    capsule:Paengi_id.Capsule_id.t ->
    current:Paengi_id.Capsule_revision_id.t ->
    (node list, error) result
end

module Catalog : sig
  type t

  type error =
    | Capsule_id_collision of Paengi_id.Capsule_id.t
    | Unknown_capsule of Paengi_id.Capsule_id.t
    | Revision_id_collision of Paengi_id.Capsule_revision_id.t
    | Unknown_parent_revision of Paengi_id.Capsule_revision_id.t
    | Parent_capsule_mismatch of {
        parent : Paengi_id.Capsule_revision_id.t;
        expected_capsule : Paengi_id.Capsule_id.t;
        actual_capsule : Paengi_id.Capsule_id.t;
      }
    | Unknown_revision of Paengi_id.Capsule_revision_id.t
    | Revision_capsule_mismatch of {
        revision : Paengi_id.Capsule_revision_id.t;
        expected_capsule : Paengi_id.Capsule_id.t;
        actual_capsule : Paengi_id.Capsule_id.t;
      }

  type revision_diff = {
    from_revision : Paengi_id.Capsule_revision_id.t;
    to_revision : Paengi_id.Capsule_revision_id.t;
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
    capsule:Paengi_id.Capsule_id.t ->
    revision:Paengi_id.Capsule_revision_id.t ->
    (t, error) result

  val find_capsule : t -> Paengi_id.Capsule_id.t -> capsule option
  val find_revision : t -> Paengi_id.Capsule_revision_id.t -> revision option
  val current_revision : t -> Paengi_id.Capsule_id.t -> revision option
  val history : t -> Paengi_id.Capsule_id.t -> (revision list, error) result

  val diff :
    t ->
    from:Paengi_id.Capsule_revision_id.t ->
    to_:Paengi_id.Capsule_revision_id.t ->
    (revision_diff, error) result
end
