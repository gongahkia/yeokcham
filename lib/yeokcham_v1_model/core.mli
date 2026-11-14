(** Pure records and consumer contracts for the core-workflow pilot. No
    filesystem, signatures, random source, or accepted-head publication. *)

type error =
  | Invalid_identifier of string
  | Entropy_failure of string
  | Invalid_field of string
  | Duplicate_id of string
  | Wrong_scope
  | Missing_reference of string
  | Wrong_reference_kind of string
  | Identity_collision of string
  | Sequence_exhausted
  | Unsupported_policy of string

val error_to_string : error -> string
val max_references : int
val max_name_bytes : int

module type Id = sig
  type t

  val of_raw : string -> (t, error) result
  val to_raw : t -> string
  val of_hex : string -> (t, error) result
  val to_hex : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module type Random_id = sig
  include Id

  val generate :
    random_bytes:(int -> (string, string) result) -> unit -> (t, error) result
  (** The adapter must supply a CSPRNG. Short/failed entropy is rejected. *)
end

module Workspace_id : Random_id
module Branch_id : Random_id
module Change_id : Random_id
module Repository_id : Id
module Record_id : Id
module Object_id : Id
module Digest : Id

module History_id : sig
  type t

  val make : workspace:Workspace_id.t -> sequence:int64 -> (t, error) result
  val workspace : t -> Workspace_id.t
  val sequence : t -> int64
  val equal : t -> t -> bool
  val compare : t -> t -> int

  val allocate :
    workspace:Workspace_id.t ->
    next:int64 option ->
    (t * int64 option, error) result
  (** Pure reservation: [None] means exhausted, including after allocating
      [Int64.max_int]. The local store/journal adapter must call this under its
      writer lock and persist the returned counter WITH the history append in
      one root publication. This function is not durable allocation. *)
end

type shared_revision = private {
  change : Change_id.t;
  previous_revisions : Record_id.t list;
  base_snapshot : Object_id.t;
  result_snapshot : Object_id.t;
  edit_scope_root : Object_id.t;
  dependencies : Record_id.t list;
}

type accepted_version = private {
  branch : Branch_id.t;
  accepted_parents : Record_id.t list;
  chosen_revisions : Record_id.t list;
  resolutions : Record_id.t list;
  result_snapshot : Object_id.t;
  composition_profile : string;
  policy_heads : Digest.t list;
  review_evidence : Digest.t list;
}

type branch_action = Create | Rename | Advance | Reconcile

type branch_event = private {
  branch : Branch_id.t;
  previous_events : Record_id.t list;
  action : branch_action;
  targets : Record_id.t list;
  display_name : string option;
}

type payload =
  | Shared_revision of shared_revision
  | Accepted_version of accepted_version
  | Branch_event of branch_event

type kind = Shared_revision_kind | Accepted_version_kind | Branch_event_kind

val kind : payload -> kind
val kind_name : kind -> string
val parents : payload -> Record_id.t list

val make_shared_revision :
  change:Change_id.t ->
  previous_revisions:Record_id.t list ->
  base_snapshot:Object_id.t ->
  result_snapshot:Object_id.t ->
  edit_scope_root:Object_id.t ->
  dependencies:Record_id.t list ->
  (shared_revision, error) result

val make_accepted_version :
  branch:Branch_id.t ->
  accepted_parents:Record_id.t list ->
  chosen_revisions:Record_id.t list ->
  resolutions:Record_id.t list ->
  result_snapshot:Object_id.t ->
  composition_profile:string ->
  policy_heads:Digest.t list ->
  review_evidence:Digest.t list ->
  (accepted_version, error) result

val make_branch_event :
  branch:Branch_id.t ->
  previous_events:Record_id.t list ->
  action:branch_action ->
  targets:Record_id.t list ->
  display_name:string option ->
  (branch_event, error) result
(** Constructors sort set-valued fields, reject duplicates and bound each
    collection. A decoder must additionally reject noncanonical input order. *)

type context = private {
  repository : Repository_id.t;
  author_certificate : Digest.t;
  authority_heads : Digest.t list;
  display_time : int64 option;
}

val make_context :
  repository:Repository_id.t ->
  author_certificate:Digest.t ->
  authority_heads:Digest.t list ->
  display_time:int64 option ->
  (context, error) result

type body = private { context : context; payload : payload }

val make_body : context:context -> payload:payload -> body

type insertion = Added | Unchanged
type pool

val empty_pool : repository:Repository_id.t -> pool
val pool_repository : pool -> Repository_id.t
val records : pool -> (Record_id.t * body) list
val find : pool -> Record_id.t -> body option

val retain : pool -> id:Record_id.t -> body -> (pool * insertion, error) result
(** Validates scope, identity collisions and known reference
    kinds/relationships. This is a pure record pool, not signature verification,
    snapshot closure, composition proof, current authority admission, or
    accepted-head publication. Use the trust boundary before retaining bytes
    from outside the process. Unsupported policy/review/resolution references
    block new retention. *)

type branch_state = {
  branch_id : Branch_id.t;
  event_heads : Record_id.t list;
  accepted_heads : Record_id.t list;
  display_names : string list;
}

val branch_states : pool -> branch_state list
(** Causal maximal event/accepted heads, ordered only for stable presentation.
    Rename events inherit target sets from their event ancestry. Concurrent
    names and accepted alternatives remain sets; neither arrival order nor
    display time selects a winner. The pool must have passed trust admission.
    This projection does not authorize switching or prove snapshot contents. *)

type history_node = private {
  history_id : History_id.t;
  parent : History_id.t option;
  snapshot : Object_id.t;
  working_basis : Record_id.t option;
  published_revisions : Record_id.t list;
}

val make_history_node :
  id:History_id.t ->
  parent:History_id.t option ->
  snapshot:Object_id.t ->
  working_basis:Record_id.t option ->
  published_revisions:Record_id.t list ->
  (history_node, error) result

type history

val empty_history : history
val history_nodes : history -> history_node list

val retain_history :
  history -> history_node -> (history * insertion, error) result
(** Repeated identical nodes are no-ops; conflicting payloads for the same
    workspace/sequence are integrity errors. Parents must exist. A first node in
    a newly generated workspace can explicitly name its source workspace's node
    as its fork ancestry. Counters remain the store adapter's responsibility. *)

type workspace_observation = private {
  workspace : Workspace_id.t;
  cursor : History_id.t;
  working_basis : Record_id.t;
  basis_snapshot : Object_id.t;
  observed_snapshot : Object_id.t;
  correspondence : (Record_id.t * History_id.t) list;
}

val make_workspace_observation :
  workspace:Workspace_id.t ->
  cursor:History_id.t ->
  working_basis:Record_id.t ->
  basis_snapshot:Object_id.t ->
  observed_snapshot:Object_id.t ->
  correspondence:(Record_id.t * History_id.t) list ->
  (workspace_observation, error) result

type composition_request = private {
  repository : Repository_id.t;
  branch : Branch_id.t;
  accepted_heads : Record_id.t list;
  selected_revisions : Record_id.t list;
  resolution_ids : Record_id.t list;
  authority_heads : Digest.t list;
  policy_heads : Digest.t list;
  review_evidence : Digest.t list;
  workspace : workspace_observation;
  composition_profile : string;
}

val make_composition_request :
  repository:Repository_id.t ->
  branch:Branch_id.t ->
  accepted_heads:Record_id.t list ->
  selected_revisions:Record_id.t list ->
  resolution_ids:Record_id.t list ->
  authority_heads:Digest.t list ->
  policy_heads:Digest.t list ->
  review_evidence:Digest.t list ->
  workspace:workspace_observation ->
  composition_profile:string ->
  (composition_request, error) result

val validate_request_references :
  pool -> composition_request -> (unit, error) result
(** Checks references only. Never returns a ready integration plan or approval.
*)

type conflict = {
  path : string list;
  versions : Record_id.t list;
  private_workspace : bool;
}

type blocker =
  | Missing_objects of Object_id.t list
  | Conflicts of conflict list
  | Invalid_authority of string
  | Required_review_unsupported
  | Policy_unavailable of Digest.t list
  | Stale_inputs
  | Ambiguous_correspondence

type composition_result = {
  accepted_snapshot : Object_id.t;
  workspace_snapshot : Object_id.t;
}
(** Separate outputs are essential: accepting shared D must not publish later
    private E. Computing and proving either result belongs to P3. *)

type 'plan preparation =
  | Prepared of 'plan
  | Blocked of blocker list
      (** Interface for future composition/journal/CLI consumers. P1 has no
          prepare, filesystem apply or policy approval stub. An unsigned local
          plan's own envelope/identity will be implemented with the actual
          planner. *)

val check_review_requirement : required:bool -> (unit, blocker) result
