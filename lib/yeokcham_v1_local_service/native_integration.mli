module Core = Yeokcham_v1_model.Core
module Plan = Yeokcham_v1_integration
module Operation = Yeokcham_v1_store.Local.Operation

type error =
  | Plan_error of Plan.error
  | Application_error of Safe_apply.error
  | Metadata of string

val error_to_string : error -> string

type outcome = {
  plan : Core.Plan_id.t;
  operation : Operation.t option;
  no_op : bool;
  resumed : bool;
}

type boundary =
  | Prepared_root
  | Applying_root
  | Materialized_root
  | Committed_root
  | Completed_root
  | Before_root
  | After_root
  | Mutation of Safe_apply.boundary * string list

val prepare :
  root:string ->
  selected_revisions:Core.Record_id.t list ->
  reconcile_heads:Core.Record_id.t list option ->
  (Plan.t, error) result
(** Captures a complete observation, prepares and retains an immutable proposal.
    Does not advance private/accepted history or mutate ordinary files. *)

val apply :
  root:string ->
  plan:Core.Plan_id.t ->
  signing_capability:Yeokcham_v1_trust.signing_capability option ->
  (outcome, error) result
(** Caller obtains confirmation of this exact plan before invoking. New
    acceptance requires the enrolled signer; an existing operation resumes its
    staged records without generating another signature/identity. *)

val resume :
  root:string -> operation:Core.Operation_id.t -> (outcome, error) result

module For_test : sig
  val apply_with_entropy :
    random_bytes:(int -> (string, string) result) ->
    observe:(boundary -> unit) ->
    root:string ->
    plan:Core.Plan_id.t ->
    signing_capability:Yeokcham_v1_trust.signing_capability option ->
    (outcome, error) result

  val apply :
    observe:(boundary -> unit) ->
    root:string ->
    plan:Core.Plan_id.t ->
    signing_capability:Yeokcham_v1_trust.signing_capability option ->
    (outcome, error) result
end
