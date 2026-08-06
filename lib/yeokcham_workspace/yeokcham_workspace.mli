module Capsule = Yeokcham_capsule

type selected_revision = {
  capsule : Yeokcham_id.Capsule_id.t;
  revision : Yeokcham_id.Capsule_revision_id.t;
  dependencies : Capsule.dependency list;
}

type edge_kind = Required_dependency | Declared_order | Explicit_precedence

type edge = {
  before : Yeokcham_id.Capsule_revision_id.t;
  after : Yeokcham_id.Capsule_revision_id.t;
  reasons : edge_kind list;
}

type order

type error =
  | Duplicate_capsule of Yeokcham_id.Capsule_id.t
  | Duplicate_revision of Yeokcham_id.Capsule_revision_id.t
  | Required_capsule_missing of {
      requiring : Yeokcham_id.Capsule_revision_id.t;
      required_capsule : Yeokcham_id.Capsule_id.t;
    }
  | Required_revision_missing of {
      requiring : Yeokcham_id.Capsule_revision_id.t;
      required_capsule : Yeokcham_id.Capsule_id.t;
      required_revision : Yeokcham_id.Capsule_revision_id.t;
    }
  | Required_release_unavailable of {
      requiring : Yeokcham_id.Capsule_revision_id.t;
      required_release : Yeokcham_id.Release_id.t;
    }
  | Conflicting_capsules of {
      declared_by : Yeokcham_id.Capsule_id.t;
      conflicts_with : Yeokcham_id.Capsule_id.t;
    }
  | Explicit_order_duplicate of Yeokcham_id.Capsule_revision_id.t
  | Explicit_order_unknown of Yeokcham_id.Capsule_revision_id.t
  | Explicit_order_missing of Yeokcham_id.Capsule_revision_id.t
  | Dependency_cycle of Yeokcham_id.Capsule_revision_id.t list

val error_to_string : error -> string
val edge_kind_to_string : edge_kind -> string

val derive_order :
  selected:selected_revision list ->
  explicit_order:Yeokcham_id.Capsule_revision_id.t list option ->
  (order, error) result

val revisions : order -> selected_revision list
val edges : order -> edge list

type application_revision = {
  selected : selected_revision;
  operations : Capsule.operation list;
}

type conflict_kind =
  | Missing_or_ambiguous_precondition
  | Competing_edits
  | Delete_modify
  | Move_modify
  | Binary_conflict
  | Dependency_failure
  | Unsupported_or_uncertain_operation

type application_conflict = {
  conflict_capsule : Yeokcham_id.Capsule_id.t;
  conflict_revision : Yeokcham_id.Capsule_revision_id.t;
  operation_index : int;
  kind : conflict_kind;
  paths : Yeokcham_scratch.path list;
  current : Yeokcham_scratch.entry option;
}

type operation_outcome =
  | Applied_exactly of {
      capsule : Yeokcham_id.Capsule_id.t;
      revision : Yeokcham_id.Capsule_revision_id.t;
      operation_index : int;
    }
  | Already_satisfied of {
      capsule : Yeokcham_id.Capsule_id.t;
      revision : Yeokcham_id.Capsule_revision_id.t;
      operation_index : int;
    }
  | Persistent_conflict of application_conflict
  | Blocked_dependency of {
      capsule : Yeokcham_id.Capsule_id.t;
      revision : Yeokcham_id.Capsule_revision_id.t;
      operation_index : int;
      blocked_by : application_conflict;
    }
  | Rejected_operation of application_conflict
  | Resolved_explicitly of {
      capsule : Yeokcham_id.Capsule_id.t;
      revision : Yeokcham_id.Capsule_revision_id.t;
      operation_index : int;
    }

type resolution_action =
  | Skip_operation of {
      capsule : Yeokcham_id.Capsule_id.t;
      revision : Yeokcham_id.Capsule_revision_id.t;
      operation_index : int;
    }

type application = {
  state : Yeokcham_scratch.State.t;
  outcomes : operation_outcome list;
  conflicts : application_conflict list;
}

val conflict_kind_to_string : conflict_kind -> string

val apply :
  state:Yeokcham_scratch.State.t ->
  ordered:application_revision list ->
  resolutions:resolution_action list ->
  application
