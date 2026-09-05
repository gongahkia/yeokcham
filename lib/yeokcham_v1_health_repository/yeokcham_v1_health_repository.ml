module Gc = Yeokcham_v1_gc
module Health = Yeokcham_v1_health
module Plan_store = Yeokcham_v1_health_store
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

let object_observation object_id status =
  Health.Object_observation
    {
      object_id = Store.Stored_object_id.to_hex object_id;
      status;
      references = [];
    }

let state_head_unreadable =
  Health.Durable_observation
    {
      durable_kind = Health.State_head;
      durable_id = "v1-project-state";
      readable = false;
      restore_mismatch = false;
    }

let restore_proof_unreadable =
  Health.Durable_observation
    {
      durable_kind = Health.Restore_proof;
      durable_id = "restore-proofs";
      readable = false;
      restore_mismatch = true;
    }

let restore_temporary_unreachable =
  Health.Temporary_observation
    {
      temporary_kind = Health.Restore_temporary;
      temporary_id = "restore-journal";
      reachable = false;
    }

let gc_temporary_unreachable =
  Health.Temporary_observation
    {
      temporary_kind = Health.Gc_temporary;
      temporary_id = "gc-transaction";
      reachable = false;
    }

let observation_of_store_error = function
  | Store.Object_identity_mismatch { expected; actual } ->
      object_observation expected
        (Health.Id_mismatch (Store.Stored_object_id.to_hex actual))
  | Store.Object_integrity_error { id; _ } ->
      object_observation id Health.Malformed
  | Store.Root_not_directory _ | Store.Repository_not_initialized _
  | Store.Repository_incomplete _ | Store.Incompatible_repository_format _
  | Store.Not_regular_file _ | Store.Object_too_large _
  | Store.File_size_changed _ | Store.Io_error _
  | Store.Collision_or_corruption _ | Store.Unsupported_publication _
  | Store.Temporary_name_exhausted _ | Store.Invalid_ref_name _
  | Store.Corrupt_ref _ | Store.Concurrent_ref_update _ | Store.Ref_lock_held _
  | Store.Ref_generation_exhausted _ | Store.Invalid_ref_path _
  | Store.Concurrent_ref_file_update _ ->
      state_head_unreadable

let[@warning "-4"] observation_of_gc_error = function
  | Gc.Missing_reachable_object id ->
      Health.Object_observation
        {
          object_id = Store.Stored_object_id.to_hex id;
          status = Health.Missing;
          references = [];
        }
  | Gc.Proof_error _ -> restore_proof_unreadable
  | Gc.Journal_error _ -> restore_temporary_unreachable
  | Gc.Snapshot_error (Snapshot.Store_error error) ->
      observation_of_store_error error
  | Gc.Transaction_not_found _ | Gc.Transaction_collision _
  | Gc.Incomplete_transaction _ | Gc.Stale_transaction_object _
  | Gc.Transaction_object_missing _ | Gc.Quarantine_collision _ ->
      gc_temporary_unreachable
  | Gc.Store_error error -> observation_of_store_error error
  | Gc.V1_store_error _ | Gc.Snapshot_error _ | Gc.Model_error _
  | Gc.Invalid_snapshot_id _ | Gc.Duplicate_object _ | Gc.Invalid_schema _
  | Gc.Unsupported_schema_version _ | Gc.Noncanonical_bytes
  | Gc.No_collectible_objects | Gc.Io_error _ ->
      state_head_unreadable

let repair_plan_unreadable =
  Health.Durable_observation
    {
      durable_kind = Health.Repair_plan_record;
      durable_id = "repair-plans";
      readable = false;
      restore_mismatch = false;
    }

let verify ~root =
  let observations =
    match Gc.inspect ~root with
    | Ok _ -> []
    | Error error -> [ observation_of_gc_error error ]
  in
  let observations =
    match Plan_store.scan ~root with
    | Ok _ -> observations
    | Error _ -> repair_plan_unreadable :: observations
  in
  Health.verify observations |> Result.get_ok
