type policy = Pin_all_exact_snapshot_checkpoints

type decision =
  | Evidence_not_passed
  | No_matching_checkpoint
  | Retain of Yeokcham_scratch.Checkpoint_id.t list

type outcome = {
  evidence : Yeokcham_id.Validation_id.t;
  decision : decision;
  newly_retained : int;
  already_retained : int;
}

type error

val error_to_string : error -> string

val decide :
  policy ->
  evidence:Yeokcham_validation.evidence ->
  candidates:(Yeokcham_scratch.Checkpoint_id.t * Yeokcham_snapshot.Snapshot.id) list ->
  decision

val apply :
  policy ->
  store:Yeokcham_store.repository ->
  scratch:Yeokcham_scratch.repository ->
  evidence_object:Yeokcham_store.Stored_object_id.t ->
  changed_at:int64 ->
  (outcome, error) result
