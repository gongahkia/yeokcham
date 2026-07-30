module Capsule = Paengi_capsule

type source_boundary = {
  source : Paengi_scratch.Checkpoint_id.t;
  target : Paengi_scratch.Checkpoint_id.t;
}

type revision_link = {
  capsule : Paengi_id.Capsule_id.t;
  revision : Paengi_id.Capsule_revision_id.t;
  object_id : Paengi_store.Stored_object_id.t;
}

type parent_link = {
  revision : Paengi_id.Capsule_revision_id.t;
  object_id : Paengi_store.Stored_object_id.t;
}

type provenance =
  | Created
  | Folded
  | Split_from of revision_link
  | Combined_from of revision_link list

type capsule
type revision
type current_ref

type error =
  | Store_error of Paengi_store.error
  | Envelope_error of Paengi_envelope.creation_error
  | Encoding_error of Paengi_encoding.construction_error
  | Decode_error of string
  | Unsupported_schema_version of int64
  | Unexpected_object_type of {
      expected : Paengi_envelope.object_type;
      actual : Paengi_envelope.object_type;
    }
  | Invalid_identity_length of { kind : string; length : int }
  | Invalid_generation of int64
  | Noncanonical_bytes of string
  | Logical_revision_id_mismatch of {
      supplied : Paengi_id.Capsule_revision_id.t;
      derived : Paengi_id.Capsule_revision_id.t;
    }
  | Invalid_current_ref_checksum
  | Scratch_error of Paengi_scratch.error
  | Snapshot_error of Paengi_snapshot.error
  | Draft_error of string
  | Current_ref_missing of Paengi_id.Capsule_id.t
  | Current_ref_corrupt of string
  | Concurrent_current_update of {
      capsule : Paengi_id.Capsule_id.t;
      expected_generation : int64 option;
      actual_generation : int64 option;
    }
  | Conflicting_capsule_id_reuse of Paengi_id.Capsule_id.t
  | Current_ref_capsule_mismatch
  | Current_ref_revision_mismatch
  | Parent_link_mismatch of string
  | Revision_history_cycle of Paengi_id.Capsule_revision_id.t
  | Revision_application_conflict of Capsule.application_conflict list
  | Revision_expected_result_mismatch
  | Current_working_directory_changed of {
      expected : Paengi_snapshot.Snapshot.id;
      actual : Paengi_snapshot.Snapshot.id;
    }
  | Scratch_head_changed of {
      expected : Paengi_scratch.Checkpoint_id.t;
      actual : Paengi_scratch.Checkpoint_id.t option;
    }
  | Injected_interruption of string

val error_to_string : error -> string

val create_capsule :
  id:Paengi_id.Capsule_id.t ->
  title:string ->
  description:string ->
  created_at:int64 ->
  (capsule, error) result

val capsule_id : capsule -> Paengi_id.Capsule_id.t
val capsule_title : capsule -> string
val capsule_description : capsule -> string
val capsule_created_at : capsule -> int64
val capsule_model : capsule -> Capsule.capsule
val capsule_payload : capsule -> (Paengi_encoding.t, error) result
val decode_capsule_payload : Paengi_encoding.t -> (capsule, error) result

val store_capsule :
  Paengi_store.repository ->
  capsule ->
  (Paengi_store.Stored_object_id.t, error) result

val load_capsule :
  Paengi_store.repository ->
  Paengi_store.Stored_object_id.t ->
  (capsule, error) result

val create_revision :
  capsule:capsule ->
  parent:parent_link option ->
  declared_base:Paengi_snapshot.Snapshot.id ->
  expected_result:Paengi_snapshot.Snapshot.id ->
  operations:Capsule.operation list ->
  dependencies:Capsule.dependency list ->
  evidence:Capsule.validation_evidence list ->
  boundaries:source_boundary list ->
  provenance:provenance ->
  created_at:int64 ->
  (revision, error) result

val revision_id : revision -> Paengi_id.Capsule_revision_id.t
val revision_capsule : revision -> Paengi_id.Capsule_id.t
val revision_parent : revision -> parent_link option
val revision_declared_base : revision -> Paengi_snapshot.Snapshot.id
val revision_expected_result : revision -> Paengi_snapshot.Snapshot.id
val revision_operations : revision -> Capsule.operation list
val revision_dependencies : revision -> Capsule.dependency list
val revision_evidence : revision -> Capsule.validation_evidence list
val revision_boundaries : revision -> source_boundary list
val revision_provenance : revision -> provenance
val revision_created_at : revision -> int64
val revision_model : revision -> Capsule.revision
val revision_payload : revision -> (Paengi_encoding.t, error) result
val decode_revision_payload : Paengi_encoding.t -> (revision, error) result

val store_revision :
  Paengi_store.repository ->
  revision ->
  (Paengi_store.Stored_object_id.t, error) result

val load_revision :
  Paengi_store.repository ->
  Paengi_store.Stored_object_id.t ->
  (revision, error) result

val derive_revision_id : revision -> Paengi_id.Capsule_revision_id.t

val make_current_ref :
  generation:int64 ->
  capsule:Paengi_id.Capsule_id.t ->
  capsule_object:Paengi_store.Stored_object_id.t ->
  revision:Paengi_id.Capsule_revision_id.t ->
  revision_object:Paengi_store.Stored_object_id.t ->
  (current_ref, error) result

val current_generation : current_ref -> int64
val current_capsule : current_ref -> Paengi_id.Capsule_id.t
val current_capsule_object : current_ref -> Paengi_store.Stored_object_id.t
val current_revision : current_ref -> Paengi_id.Capsule_revision_id.t
val current_revision_object : current_ref -> Paengi_store.Stored_object_id.t
val encode_current_ref : current_ref -> string
val decode_current_ref : string -> (current_ref, error) result
val current_ref_components : Paengi_id.Capsule_id.t -> string list

module Durable : sig
  type resolved

  type current_creation =
    | No_current_changes of {
        checkpoint : Paengi_scratch.Checkpoint_id.t;
        snapshot : Paengi_snapshot.Snapshot.id;
      }
    | Created_from_current of {
        resolved : resolved;
        source : Paengi_scratch.Checkpoint_id.t;
        target : Paengi_scratch.Checkpoint_id.t;
      }

  type failure_point =
    | Before_create_current_ref
    | After_create_current_ref
    | Before_fold_current_ref
    | After_fold_current_ref

  val resolved_capsule : resolved -> capsule
  val resolved_capsule_object : resolved -> Paengi_store.Stored_object_id.t
  val resolved_revision : resolved -> revision
  val resolved_revision_object : resolved -> Paengi_store.Stored_object_id.t
  val resolved_current_ref : resolved -> current_ref

  val create_from_checkpoints :
    store:Paengi_store.repository ->
    scratch:Paengi_scratch.repository ->
    id:Paengi_id.Capsule_id.t ->
    title:string ->
    description:string ->
    dependencies:Capsule.dependency list ->
    evidence:Capsule.validation_evidence list ->
    from:Paengi_scratch.Checkpoint_id.t ->
    target:Paengi_scratch.Checkpoint_id.t ->
    created_at:int64 ->
    changed_at:int64 ->
    ?fail_at:failure_point ->
    unit ->
    (resolved, error) result

  val create_from_current :
    store:Paengi_store.repository ->
    scratch:Paengi_scratch.repository ->
    root:string ->
    id:Paengi_id.Capsule_id.t ->
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

  val fold_from_checkpoints :
    store:Paengi_store.repository ->
    scratch:Paengi_scratch.repository ->
    capsule:Paengi_id.Capsule_id.t ->
    expected_revision:Paengi_id.Capsule_revision_id.t ->
    expected_generation:int64 ->
    evidence:Capsule.validation_evidence list ->
    from:Paengi_scratch.Checkpoint_id.t ->
    target:Paengi_scratch.Checkpoint_id.t ->
    created_at:int64 ->
    changed_at:int64 ->
    ?fail_at:failure_point ->
    unit ->
    (resolved, error) result

  val read_current :
    Paengi_store.repository ->
    Paengi_id.Capsule_id.t ->
    (resolved, error) result

  val show :
    Paengi_store.repository ->
    Paengi_id.Capsule_id.t ->
    (resolved, error) result

  val current_diff :
    Paengi_store.repository ->
    Paengi_id.Capsule_id.t ->
    (Capsule.operation list, error) result

  val history :
    Paengi_store.repository ->
    Paengi_id.Capsule_id.t ->
    (revision list, error) result

  val list : Paengi_store.repository -> (resolved list, error) result

  val split :
    store:Paengi_store.repository ->
    scratch:Paengi_scratch.repository ->
    source:Paengi_id.Capsule_id.t ->
    left_id:Paengi_id.Capsule_id.t ->
    left_title:string ->
    left_description:string ->
    right_id:Paengi_id.Capsule_id.t ->
    right_title:string ->
    right_description:string ->
    left_operation_indices:int list ->
    created_at:int64 ->
    changed_at:int64 ->
    unit ->
    (resolved * resolved, error) result

  val combine :
    store:Paengi_store.repository ->
    scratch:Paengi_scratch.repository ->
    id:Paengi_id.Capsule_id.t ->
    title:string ->
    description:string ->
    sources:revision_link list ->
    created_at:int64 ->
    changed_at:int64 ->
    unit ->
    (resolved, error) result
end
