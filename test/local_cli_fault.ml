module Service = Yeokcham_v1_local_service

(* trusted test process: interruption is never enabled by production CLI input *)
let () =
  let root = Sys.argv.(1) and boundary = Sys.argv.(2) in
  let[@warning "-4"] observe stage =
    let stop =
      match (boundary, stage) with
      | ( "mutation",
          Service.Filesystem_mutation (Service.Safe_apply.After_mutation, _) )
      | "materialized", Service.Materialized_journal
      | "metadata", Service.After_metadata_publish ->
          true
      | _ -> false
    in
    if stop then Unix._exit 73
  in
  let result =
    if Array.length Sys.argv = 3 then
      Service.For_test.navigate_history ~observe ~root ~direction:Service.Undo
        ~dry_run:false
      |> Result.map (fun _ -> ())
    else
      let checkpoint =
        Yeokcham_v1_model.Snapshot_id.of_string Sys.argv.(3) |> Result.get_ok
      in
      Service.For_test.copy_out ~observe ~root ~checkpoint
        ~destination:Sys.argv.(4) ~dry_run:false ~expected_plan:None
      |> Result.map (fun _ -> ())
  in
  match result with
  | Ok () -> failwith "requested interruption boundary was not reached"
  | Error error -> failwith (Service.error_to_string error)
