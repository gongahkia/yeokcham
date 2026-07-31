module Capsule = Paengi_capsule

type selected_revision = {
  capsule : Paengi_id.Capsule_id.t;
  revision : Paengi_id.Capsule_revision_id.t;
  dependencies : Capsule.dependency list;
}

type edge_kind = Required_dependency | Declared_order | Explicit_precedence

type edge = {
  before : Paengi_id.Capsule_revision_id.t;
  after : Paengi_id.Capsule_revision_id.t;
  reasons : edge_kind list;
}

type order

type error =
  | Duplicate_capsule of Paengi_id.Capsule_id.t
  | Duplicate_revision of Paengi_id.Capsule_revision_id.t
  | Required_capsule_missing of {
      requiring : Paengi_id.Capsule_revision_id.t;
      required_capsule : Paengi_id.Capsule_id.t;
    }
  | Required_revision_missing of {
      requiring : Paengi_id.Capsule_revision_id.t;
      required_capsule : Paengi_id.Capsule_id.t;
      required_revision : Paengi_id.Capsule_revision_id.t;
    }
  | Required_release_unavailable of {
      requiring : Paengi_id.Capsule_revision_id.t;
      required_release : Paengi_id.Release_id.t;
    }
  | Conflicting_capsules of {
      declared_by : Paengi_id.Capsule_id.t;
      conflicts_with : Paengi_id.Capsule_id.t;
    }
  | Explicit_order_duplicate of Paengi_id.Capsule_revision_id.t
  | Explicit_order_unknown of Paengi_id.Capsule_revision_id.t
  | Explicit_order_missing of Paengi_id.Capsule_revision_id.t
  | Dependency_cycle of Paengi_id.Capsule_revision_id.t list

val error_to_string : error -> string
val edge_kind_to_string : edge_kind -> string

val derive_order :
  selected:selected_revision list ->
  explicit_order:Paengi_id.Capsule_revision_id.t list option ->
  (order, error) result

val revisions : order -> selected_revision list
val edges : order -> edge list
