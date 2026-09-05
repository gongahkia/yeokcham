module Health = Yeokcham_v1_health
module Repository = Yeokcham_v1_health_repository
module Model = Yeokcham_v1_model
module Service = Yeokcham_v1_local_service
module Store = Yeokcham_store
module V1_store = Yeokcham_v1_store

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
    ~title:"health work"
  |> require_ok Service.error_to_string

let tree_fingerprint root =
  let rec entries base relative =
    Sys.readdir base |> Array.to_list |> List.sort String.compare
    |> List.concat_map (fun name ->
        let path = Filename.concat base name in
        let next = Filename.concat relative name in
        match (Unix.lstat path).Unix.st_kind with
        | Unix.S_DIR -> (next ^ "/") :: entries path next
        | Unix.S_REG ->
            [ next ^ ":" ^ In_channel.with_open_bin path In_channel.input_all ]
        | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
            [ next ])
  in
  entries root ""

let clean_repository_verification_writes_nothing () =
  with_directory "v1-health-verify-clean-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      let before = tree_fingerprint root in
      let report = Repository.verify ~root in
      Alcotest.(check bool)
        "clean repository reports no damage" true
        (Health.report_is_clean report);
      Alcotest.(check (list string))
        "verification writes no repository bytes" before (tree_fingerprint root))

let missing_checkpoint_closure_is_typed_without_source_writes () =
  with_directory "v1-health-verify-missing-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let status = initialize root in
      let repository =
        V1_store.open_repository ~root |> require_ok V1_store.error_to_string
      in
      let store = V1_store.underlying_store repository in
      let snapshot =
        Model.Snapshot_id.to_string status.Service.checkpoint
        |> Store.Stored_object_id.of_hex |> Result.get_ok
      in
      Unix.unlink (Store.object_path store snapshot);
      let before = tree_fingerprint root in
      let report = Repository.verify ~root in
      let codes =
        Health.report_damages report
        |> List.map (fun damage ->
            Health.damage_code damage |> Health.damage_code_to_string)
      in
      Alcotest.(check bool)
        "missing closure has a typed diagnosis" true
        (List.mem "missing-object" codes);
      Alcotest.(check (list string))
        "failed verification writes no source bytes" before
        (tree_fingerprint root))

let mismatched_checkpoint_object_is_typed_without_source_writes () =
  with_directory "v1-health-verify-mismatch-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let status = initialize root in
      let repository =
        V1_store.open_repository ~root |> require_ok V1_store.error_to_string
      in
      let store = V1_store.underlying_store repository in
      let snapshot =
        Model.Snapshot_id.to_string status.Service.checkpoint
        |> Store.Stored_object_id.of_hex |> Result.get_ok
      in
      let path = Store.object_path store snapshot in
      Out_channel.with_open_bin path (fun output ->
          Out_channel.output_string output "not an envelope");
      let before = tree_fingerprint root in
      let report = Repository.verify ~root in
      let codes =
        Health.report_damages report
        |> List.map (fun damage ->
            Health.damage_code damage |> Health.damage_code_to_string)
      in
      Alcotest.(check bool)
        "mismatched closure has a typed diagnosis" true
        (List.mem "canonical-id-mismatch" codes);
      Alcotest.(check (list string))
        "mismatched verification writes no source bytes" before
        (tree_fingerprint root))

let damaged_closure_does_not_block_unrelated_local_work () =
  with_directory "v1-health-failure-locality-" (fun parent ->
      let damaged_root = Filename.concat parent "damaged" in
      let intact_root = Filename.concat parent "intact" in
      Unix.mkdir damaged_root 0o700;
      Unix.mkdir intact_root 0o700;
      List.iter
        (fun root -> write_file root "main.ml" "let version = 1\n")
        [ damaged_root; intact_root ];
      let damaged = initialize damaged_root in
      ignore (initialize intact_root);
      let repository =
        V1_store.open_repository ~root:damaged_root
        |> require_ok V1_store.error_to_string
      in
      let store = V1_store.underlying_store repository in
      let snapshot =
        Model.Snapshot_id.to_string damaged.Service.checkpoint
        |> Store.Stored_object_id.of_hex |> Result.get_ok
      in
      Unix.unlink (Store.object_path store snapshot);
      Alcotest.(check bool)
        "damage remains visible" false
        (Repository.verify ~root:damaged_root |> Health.report_is_clean);
      ignore
        (Service.status ~root:damaged_root |> require_ok Service.error_to_string);
      ignore
        (Service.inspection_state ~root:damaged_root
        |> require_ok Service.error_to_string);
      write_file damaged_root "main.ml" "let version = 2\n";
      (match Service.save ~root:damaged_root with
      | Ok (Service.Saved _) -> ()
      | Ok (Service.Unchanged _) ->
          Alcotest.fail "unrelated changed local work was not saved"
      | Error error -> Alcotest.fail (Service.error_to_string error));
      ignore
        (Service.inspection_state ~root:intact_root
        |> require_ok Service.error_to_string))

let () =
  Alcotest.run "V1 health repository"
    [
      ( "verification",
        [
          Alcotest.test_case "clean verification is no-write" `Quick
            clean_repository_verification_writes_nothing;
          Alcotest.test_case "missing closure is typed and no-write" `Quick
            missing_checkpoint_closure_is_typed_without_source_writes;
          Alcotest.test_case "mismatched closure is typed and no-write" `Quick
            mismatched_checkpoint_object_is_typed_without_source_writes;
          Alcotest.test_case
            "damage remains local to operations requiring its closure" `Quick
            damaged_closure_does_not_block_unrelated_local_work;
        ] );
    ]
