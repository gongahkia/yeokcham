module Health = Yeokcham_v4_health
module Repository = Yeokcham_v4_health_repository
module Model = Yeokcham_v4_model
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
  with_directory "v4-health-verify-clean-" (fun root ->
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
  with_directory "v4-health-verify-missing-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let status = initialize root in
      let repository =
        V4_store.open_repository ~root |> require_ok V4_store.error_to_string
      in
      let store = V4_store.underlying_store repository in
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
  with_directory "v4-health-verify-mismatch-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let status = initialize root in
      let repository =
        V4_store.open_repository ~root |> require_ok V4_store.error_to_string
      in
      let store = V4_store.underlying_store repository in
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

let () =
  Alcotest.run "V4 health repository"
    [
      ( "verification",
        [
          Alcotest.test_case "clean verification is no-write" `Quick
            clean_repository_verification_writes_nothing;
          Alcotest.test_case "missing closure is typed and no-write" `Quick
            missing_checkpoint_closure_is_typed_without_source_writes;
          Alcotest.test_case "mismatched closure is typed and no-write" `Quick
            mismatched_checkpoint_object_is_typed_without_source_writes;
        ] );
    ]
