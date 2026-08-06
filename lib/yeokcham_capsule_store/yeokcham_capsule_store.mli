module Capsule = Yeokcham_capsule

type source_boundary = {
  source : Yeokcham_scratch.Checkpoint_id.t;
  target : Yeokcham_scratch.Checkpoint_id.t;
}

type revision_link = {
  capsule : Yeokcham_id.Capsule_id.t;
  revision : Yeokcham_id.Capsule_revision_id.t;
  object_id : Yeokcham_store.Stored_object_id.t;
}

type parent_link = {
  revision : Yeokcham_id.Capsule_revision_id.t;
  object_id : Yeokcham_store.Stored_object_id.t;
}

val make_revision_link :
  capsule:Yeokcham_id.Capsule_id.t ->
  revision:Yeokcham_id.Capsule_revision_id.t ->
  object_id:Yeokcham_store.Stored_object_id.t ->
  revision_link

val revision_link_capsule : revision_link -> Yeokcham_id.Capsule_id.t
val revision_link_revision : revision_link -> Yeokcham_id.Capsule_revision_id.t
val revision_link_object : revision_link -> Yeokcham_store.Stored_object_id.t

type provenance =
  | Created
  | Folded
  | Split_from of revision_link
  | Combined_from of revision_link list

type capsule
type revision
type current_ref

type error =
  | Store_error of Yeokcham_store.error
  | Envelope_error of Yeokcham_envelope.creation_error
  | Encoding_error of Yeokcham_encoding.construction_error
  | Decode_error of string
  | Unsupported_schema_version of int64
  | Unexpected_object_type of {
      expected : Yeokcham_envelope.object_type;
      actual : Yeokcham_envelope.object_type;
    }
  | Invalid_identity_length of { kind : string; length : int }
  | Invalid_generation of int64
  | Noncanonical_bytes of string
  | Logical_revision_id_mismatch of {
      supplied : Yeokcham_id.Capsule_revision_id.t;
      derived : Yeokcham_id.Capsule_revision_id.t;
    }
  | Invalid_current_ref_checksum
  | Scratch_error of Yeokcham_scratch.error
  | Snapshot_error of Yeokcham_snapshot.error
  | Draft_error of string
  | Current_ref_missing of Yeokcham_id.Capsule_id.t
  | Current_ref_corrupt of string
  | Concurrent_current_update of {
      capsule : Yeokcham_id.Capsule_id.t;
      expected_generation : int64 option;
      actual_generation : int64 option;
    }
  | Conflicting_capsule_id_reuse of Yeokcham_id.Capsule_id.t
  | Current_ref_capsule_mismatch
  | Current_ref_revision_mismatch
  | Parent_link_mismatch of string
  | Revision_history_cycle of Yeokcham_id.Capsule_revision_id.t
  | Revision_application_conflict of Capsule.application_conflict list
  | Revision_expected_result_mismatch
  | Confirmation_required of string
  | Current_working_directory_changed of {
      expected : Yeokcham_snapshot.Snapshot.id;
      actual : Yeokcham_snapshot.Snapshot.id;
    }
  | Scratch_head_changed of {
      expected : Yeokcham_scratch.Checkpoint_id.t;
      actual : Yeokcham_scratch.Checkpoint_id.t option;
    }
  | Injected_interruption of string

val error_to_string : error -> string

val create_capsule :
  id:Yeokcham_id.Capsule_id.t ->
  title:string ->
  description:string ->
  created_at:int64 ->
  (capsule, error) result

val capsule_id : capsule -> Yeokcham_id.Capsule_id.t
val capsule_title : capsule -> string
val capsule_description : capsule -> string
val capsule_created_at : capsule -> int64
val capsule_model : capsule -> Capsule.capsule
val capsule_payload : capsule -> (Yeokcham_encoding.t, error) result
val decode_capsule_payload : Yeokcham_encoding.t -> (capsule, error) result

val store_capsule :
  Yeokcham_store.repository ->
  capsule ->
  (Yeokcham_store.Stored_object_id.t, error) result

val load_capsule :
  Yeokcham_store.repository ->
  Yeokcham_store.Stored_object_id.t ->
  (capsule, error) result

val create_revision :
  capsule:capsule ->
  parent:parent_link option ->
  declared_base:Yeokcham_snapshot.Snapshot.id ->
  expected_result:Yeokcham_snapshot.Snapshot.id ->
  operations:Capsule.operation list ->
  dependencies:Capsule.dependency list ->
  evidence:Capsule.validation_evidence list ->
  boundaries:source_boundary list ->
  provenance:provenance ->
  created_at:int64 ->
  (revision, error) result

val revision_id : revision -> Yeokcham_id.Capsule_revision_id.t
val revision_capsule : revision -> Yeokcham_id.Capsule_id.t
val revision_parent : revision -> parent_link option
val revision_declared_base : revision -> Yeokcham_snapshot.Snapshot.id
val revision_expected_result : revision -> Yeokcham_snapshot.Snapshot.id
val revision_operations : revision -> Capsule.operation list
val revision_dependencies : revision -> Capsule.dependency list
val revision_evidence : revision -> Capsule.validation_evidence list
val revision_boundaries : revision -> source_boundary list
val revision_provenance : revision -> provenance
val revision_created_at : revision -> int64
val revision_model : revision -> Capsule.revision
val revision_payload : revision -> (Yeokcham_encoding.t, error) result
val decode_revision_payload : Yeokcham_encoding.t -> (revision, error) result

val store_revision :
  Yeokcham_store.repository ->
  revision ->
  (Yeokcham_store.Stored_object_id.t, error) result

val load_revision :
  Yeokcham_store.repository ->
  Yeokcham_store.Stored_object_id.t ->
  (revision, error) result

val derive_revision_id : revision -> Yeokcham_id.Capsule_revision_id.t

val make_current_ref :
  generation:int64 ->
  capsule:Yeokcham_id.Capsule_id.t ->
  capsule_object:Yeokcham_store.Stored_object_id.t ->
  revision:Yeokcham_id.Capsule_revision_id.t ->
  revision_object:Yeokcham_store.Stored_object_id.t ->
  (current_ref, error) result

val current_generation : current_ref -> int64
val current_capsule : current_ref -> Yeokcham_id.Capsule_id.t
val current_capsule_object : current_ref -> Yeokcham_store.Stored_object_id.t
val current_revision : current_ref -> Yeokcham_id.Capsule_revision_id.t
val current_revision_object : current_ref -> Yeokcham_store.Stored_object_id.t
val encode_current_ref : current_ref -> string
val decode_current_ref : string -> (current_ref, error) result
val current_ref_components : Yeokcham_id.Capsule_id.t -> string list

module Durable : sig
  type resolved

  type current_creation =
    | No_current_changes of {
        checkpoint : Yeokcham_scratch.Checkpoint_id.t;
        snapshot : Yeokcham_snapshot.Snapshot.id;
      }
    | Created_from_current of {
        resolved : resolved;
        source : Yeokcham_scratch.Checkpoint_id.t;
        target : Yeokcham_scratch.Checkpoint_id.t;
      }

  type failure_point =
    | Before_create_current_ref
    | After_create_current_ref
    | Before_fold_current_ref
    | After_fold_current_ref

  val resolved_capsule : resolved -> capsule
  val resolved_capsule_object : resolved -> Yeokcham_store.Stored_object_id.t
  val resolved_revision : resolved -> revision
  val resolved_revision_object : resolved -> Yeokcham_store.Stored_object_id.t
  val resolved_current_ref : resolved -> current_ref

  val create_from_checkpoints :
    store:Yeokcham_store.repository ->
    scratch:Yeokcham_scratch.repository ->
    id:Yeokcham_id.Capsule_id.t ->
    title:string ->
    description:string ->
    dependencies:Capsule.dependency list ->
    evidence:Capsule.validation_evidence list ->
    from:Yeokcham_scratch.Checkpoint_id.t ->
    target:Yeokcham_scratch.Checkpoint_id.t ->
    created_at:int64 ->
    changed_at:int64 ->
    ?fail_at:failure_point ->
    unit ->
    (resolved, error) result

  val create_from_current :
    store:Yeokcham_store.repository ->
    scratch:Yeokcham_scratch.repository ->
    root:string ->
    id:Yeokcham_id.Capsule_id.t ->
    title:string ->
    description:string ->
    dependencies:Capsule.dependency list ->
    evidence:Capsule.validation_evidence list ->
    created_at:int64 ->
    changed_at:int64 ->
    ?before_verify:(unit -> unit) ->
    ?fail_at:failure_point ->
    unit ->
    (current_creation, error) result

  val enable_for_editing :
    store:Yeokcham_store.repository ->
    scratch:Yeokcham_scratch.repository ->
    root:string ->
    capsule:Yeokcham_id.Capsule_id.t ->
    observed_at:int64 ->
    created_at:int64 ->
    ?before_apply:(unit -> unit) ->
    unit ->
    (Yeokcham_scratch.Checkpoint_id.t, error) result

  val fold_from_checkpoints :
    store:Yeokcham_store.repository ->
    scratch:Yeokcham_scratch.repository ->
    capsule:Yeokcham_id.Capsule_id.t ->
    expected_revision:Yeokcham_id.Capsule_revision_id.t ->
    expected_generation:int64 ->
    evidence:Capsule.validation_evidence list ->
    from:Yeokcham_scratch.Checkpoint_id.t ->
    target:Yeokcham_scratch.Checkpoint_id.t ->
    created_at:int64 ->
    changed_at:int64 ->
    ?fail_at:failure_point ->
    unit ->
    (resolved, error) result

  val read_current :
    Yeokcham_store.repository ->
    Yeokcham_id.Capsule_id.t ->
    (resolved, error) result

  val verify_link :
    Yeokcham_store.repository -> revision_link -> (revision, error) result

  val show :
    Yeokcham_store.repository ->
    Yeokcham_id.Capsule_id.t ->
    (resolved, error) result

  val current_diff :
    Yeokcham_store.repository ->
    Yeokcham_id.Capsule_id.t ->
    (Capsule.operation list, error) result

  val history :
    Yeokcham_store.repository ->
    Yeokcham_id.Capsule_id.t ->
    (revision list, error) result

  val list : Yeokcham_store.repository -> (resolved list, error) result

  type split_plan
  type combine_plan

  val split_plan_source : split_plan -> revision_link
  val split_plan_selected_operation_indices : split_plan -> int list
  val split_plan_outputs : split_plan -> (capsule * revision) list

  val split_plan_composition_order :
    split_plan ->
    (Yeokcham_id.Capsule_id.t * Yeokcham_id.Capsule_revision_id.t) list

  val split_plan_boundary_pins : split_plan -> source_boundary list

  val plan_split :
    store:Yeokcham_store.repository ->
    source:Yeokcham_id.Capsule_id.t ->
    left_id:Yeokcham_id.Capsule_id.t ->
    left_title:string ->
    left_description:string ->
    right_id:Yeokcham_id.Capsule_id.t ->
    right_title:string ->
    right_description:string ->
    left_operation_indices:int list ->
    created_at:int64 ->
    (split_plan, error) result

  val split :
    store:Yeokcham_store.repository ->
    scratch:Yeokcham_scratch.repository ->
    source:Yeokcham_id.Capsule_id.t ->
    left_id:Yeokcham_id.Capsule_id.t ->
    left_title:string ->
    left_description:string ->
    right_id:Yeokcham_id.Capsule_id.t ->
    right_title:string ->
    right_description:string ->
    left_operation_indices:int list ->
    created_at:int64 ->
    changed_at:int64 ->
    confirmed:bool ->
    unit ->
    (resolved * resolved, error) result

  val combine_plan_sources : combine_plan -> revision_link list
  val combine_plan_output : combine_plan -> capsule * revision
  val combine_plan_composition_order : combine_plan -> revision_link list
  val combine_plan_boundary_pins : combine_plan -> source_boundary list

  val plan_combine :
    store:Yeokcham_store.repository ->
    id:Yeokcham_id.Capsule_id.t ->
    title:string ->
    description:string ->
    sources:revision_link list ->
    created_at:int64 ->
    (combine_plan, error) result

  val combine :
    store:Yeokcham_store.repository ->
    scratch:Yeokcham_scratch.repository ->
    id:Yeokcham_id.Capsule_id.t ->
    title:string ->
    description:string ->
    sources:revision_link list ->
    created_at:int64 ->
    changed_at:int64 ->
    confirmed:bool ->
    unit ->
    (resolved, error) result
end
