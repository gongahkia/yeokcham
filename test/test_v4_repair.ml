module Health = Yeokcham_v4_health
module Health_repository = Yeokcham_v4_health_repository
module Model = Yeokcham_v4_model
module Repair = Yeokcham_v4_repair
module Service = Yeokcham_v4_local_service
module Store = Yeokcham_store
module V4_store = Yeokcham_v4_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_directory prefix run =
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let write_file root name contents =
  Out_channel.with_open_bin (Filename.concat root name) (fun output ->
      Out_channel.output_string output contents)

let initialize root =
  Service.init ~root
    ~creator:(Model.Device_id.of_string "device-alice" |> Result.get_ok)
    ~username:(Model.Username.of_string "alice" |> Result.get_ok)
    ~initial_draft:(Model.Draft_id.of_string "draft-one" |> Result.get_ok)
    ~title:"repair work"
  |> require_ok Service.error_to_string

let initialized_pair run =
  with_directory "v4-repair-target-" (fun root ->
      with_directory "v4-repair-backup-" (fun backup ->
          write_file root "main.ml" "let version = 1\n";
          write_file backup "main.ml" "let version = 1\n";
          let target_status = initialize root in
          ignore (initialize backup);
          run root backup target_status))

let checkpoint_object root status =
  let repository =
    V4_store.open_repository ~root |> require_ok V4_store.error_to_string
  in
  let store = V4_store.underlying_store repository in
  let snapshot =
    Model.Snapshot_id.to_string status.Service.checkpoint
    |> Store.Stored_object_id.of_hex |> Result.get_ok
  in
  (store, snapshot)

let delete_checkpoint root status =
  let store, snapshot = checkpoint_object root status in
  Unix.unlink (Store.object_path store snapshot);
  Store.Stored_object_id.to_hex snapshot

let candidate plan =
  match Health.plan_candidates plan with
  | [ candidate ] -> candidate
  | _ -> Alcotest.fail "expected one exact repair candidate"

let assert_missing root =
  let report = Health_repository.verify ~root in
  Alcotest.(check bool)
    "target remains damaged" false
    (Health.report_is_clean report)

let backup_repair_is_explicit_exact_and_source_safe () =
  initialized_pair (fun root backup status ->
      let missing = delete_checkpoint root status in
      let target_before =
        In_channel.with_open_bin
          (Filename.concat root "main.ml")
          In_channel.input_all
      in
      let backup_before =
        In_channel.with_open_bin
          (Filename.concat backup "main.ml")
          In_channel.input_all
      in
      let plan =
        Repair.plan_from_backup ~root ~backup ~created_at:10L ~expires_at:20L
        |> require_ok Repair.error_to_string
      in
      let candidate = candidate plan in
      Alcotest.(check string)
        "candidate names exactly the missing object" missing
        (Health.candidate_object_id candidate);
      let selection =
        Health.make_selection plan ~candidate_id:(Health.candidate_id candidate)
      in
      let outcome =
        Repair.apply_from_backup ~root ~plan_id:(Health.plan_id plan) ~selection
          ~now:11L
        |> require_ok Repair.error_to_string
      in
      (match outcome with
      | Repair.Applied _ -> ()
      | Repair.Refused refusal ->
          Alcotest.fail (Health.refusal_to_string refusal));
      Alcotest.(check string)
        "repair never materialises target source" target_before
        (In_channel.with_open_bin
           (Filename.concat root "main.ml")
           In_channel.input_all);
      Alcotest.(check string)
        "repair never alters backup source" backup_before
        (In_channel.with_open_bin
           (Filename.concat backup "main.ml")
           In_channel.input_all);
      Alcotest.(check bool)
        "repaired closure is clean" true
        (Health_repository.verify ~root |> Health.report_is_clean))

let[@warning "-4"] disappearing_backup_refuses_without_publication () =
  initialized_pair (fun root backup status ->
      let missing = delete_checkpoint root status in
      let plan =
        Repair.plan_from_backup ~root ~backup ~created_at:10L ~expires_at:20L
        |> require_ok Repair.error_to_string
      in
      let candidate = candidate plan in
      let backup_store, backup_snapshot = checkpoint_object backup status in
      Unix.unlink (Store.object_path backup_store backup_snapshot);
      let selection =
        Health.make_selection plan ~candidate_id:(Health.candidate_id candidate)
      in
      let outcome =
        Repair.apply_from_backup ~root ~plan_id:(Health.plan_id plan) ~selection
          ~now:11L
        |> require_ok Repair.error_to_string
      in
      (match outcome with
      | Repair.Refused Health.Candidate_changed -> ()
      | Repair.Refused refusal ->
          Alcotest.fail (Health.refusal_to_string refusal)
      | Repair.Applied _ -> Alcotest.fail "vanished backup object was published");
      let target_store, target_snapshot = checkpoint_object root status in
      Alcotest.(check bool)
        "missing object remains absent" false
        (Sys.file_exists (Store.object_path target_store target_snapshot));
      Alcotest.(check string)
        "expected missing object" missing
        (Store.Stored_object_id.to_hex target_snapshot);
      assert_missing root)

let[@warning "-4"] changed_state_head_refuses_stale_approval () =
  initialized_pair (fun root backup status ->
      ignore (delete_checkpoint root status);
      let plan =
        Repair.plan_from_backup ~root ~backup ~created_at:10L ~expires_at:20L
        |> require_ok Repair.error_to_string
      in
      let candidate = candidate plan in
      let repository =
        V4_store.open_repository ~root |> require_ok V4_store.error_to_string
      in
      let loaded =
        V4_store.load repository |> require_ok V4_store.error_to_string
      in
      let project =
        Model.register_username loaded.V4_store.project
          ~device:(Model.Device_id.of_string "device-bob" |> Result.get_ok)
          ~username:(Model.Username.of_string "bob" |> Result.get_ok)
        |> require_ok Model.error_to_string
      in
      ignore
        (V4_store.save repository ~expected:loaded.V4_store.head ~project
        |> require_ok V4_store.error_to_string);
      let selection =
        Health.make_selection plan ~candidate_id:(Health.candidate_id candidate)
      in
      let outcome =
        Repair.apply_from_backup ~root ~plan_id:(Health.plan_id plan) ~selection
          ~now:11L
        |> require_ok Repair.error_to_string
      in
      (match outcome with
      | Repair.Refused Health.State_head_changed -> ()
      | Repair.Refused refusal ->
          Alcotest.fail (Health.refusal_to_string refusal)
      | Repair.Applied _ -> Alcotest.fail "stale plan published an object");
      assert_missing root)

let () =
  Alcotest.run "V4 repair"
    [
      ( "backup",
        [
          Alcotest.test_case "exact repair preserves ordinary sources" `Quick
            backup_repair_is_explicit_exact_and_source_safe;
          Alcotest.test_case "disappearing source refuses" `Quick
            disappearing_backup_refuses_without_publication;
          Alcotest.test_case "changed state head refuses" `Quick
            changed_state_head_refuses_stale_approval;
        ] );
    ]
