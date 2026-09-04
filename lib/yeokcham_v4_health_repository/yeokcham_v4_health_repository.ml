module Gc = Yeokcham_v4_gc
module Health = Yeokcham_v4_health
module Plan_store = Yeokcham_v4_health_store
module Store = Yeokcham_store

let state_head_unreadable =
  Health.Durable_observation
    {
      durable_kind = Health.State_head;
      durable_id = "v4-project-state";
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

let observation_of_gc_error = function
  | Gc.Missing_reachable_object id ->
      Health.Object_observation
        {
          object_id = Store.Stored_object_id.to_hex id;
          status = Health.Missing;
          references = [];
        }
  | Gc.Proof_error _ -> restore_proof_unreadable
  | Gc.Journal_error _ -> restore_temporary_unreachable
  | Gc.Transaction_not_found _ | Gc.Transaction_collision _
  | Gc.Incomplete_transaction _ | Gc.Stale_transaction_object _
  | Gc.Transaction_object_missing _ | Gc.Quarantine_collision _ ->
      gc_temporary_unreachable
  | Gc.Store_error _ | Gc.V4_store_error _ | Gc.Snapshot_error _
  | Gc.Model_error _ | Gc.Invalid_snapshot_id _ | Gc.Duplicate_object _
  | Gc.Invalid_schema _ | Gc.Unsupported_schema_version _
  | Gc.Noncanonical_bytes | Gc.No_collectible_objects | Gc.Io_error _ ->
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
