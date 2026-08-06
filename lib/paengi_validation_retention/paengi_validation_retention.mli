type policy = Pin_all_exact_snapshot_checkpoints

type decision =
  | Evidence_not_passed
  | No_matching_checkpoint
  | Retain of Paengi_scratch.Checkpoint_id.t list

type outcome = {
  evidence : Paengi_id.Validation_id.t;
  decision : decision;
  newly_retained : int;
  already_retained : int;
}

type error

val error_to_string : error -> string

val decide :
  policy ->
  evidence:Paengi_validation.evidence ->
  candidates:(Paengi_scratch.Checkpoint_id.t * Paengi_snapshot.Snapshot.id) list ->
  decision

val apply :
  policy ->
  store:Paengi_store.repository ->
  scratch:Paengi_scratch.repository ->
  evidence_object:Paengi_store.Stored_object_id.t ->
  changed_at:int64 ->
  (outcome, error) result
