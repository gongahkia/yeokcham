module Model = Yeokcham_v4_model
module Service = Yeokcham_v4_local_service

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
  Out_channel.with_open_bin (Filename.concat root name) (fun channel ->
      Out_channel.output_string channel contents)

let read_file root name =
  In_channel.with_open_bin (Filename.concat root name) In_channel.input_all

let id parser value = parser value |> Result.get_ok
let device value = id Model.Device_id.of_string value
let draft value = id Model.Draft_id.of_string value

let initialize root =
  Service.init ~root ~creator:(device "device-alice")
    ~initial_draft:(draft "draft-one") ~title:"first work"
  |> require_ok Service.error_to_string

let init_captures_the_initial_tree_and_save_observes_no_change () =
  with_directory "yeokcham-v4-service-init-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initialized = initialize root in
      Alcotest.(check bool)
        "initial checkpoint identity is nonempty" true
        (String.length
           (Model.Snapshot_id.to_string initialized.Service.checkpoint)
        > 0);
      match Service.save ~root |> require_ok Service.error_to_string with
      | Service.Unchanged status ->
          Alcotest.(check string)
            "unchanged save retains checkpoint"
            (Model.Snapshot_id.to_string initialized.Service.checkpoint)
            (Model.Snapshot_id.to_string status.Service.checkpoint)
      | Service.Saved _ -> Alcotest.fail "unchanged tree created a state write")

let changed_save_creates_a_new_checkpoint () =
  with_directory "yeokcham-v4-service-save-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      write_file root "main.ml" "let version = 2\n";
      match Service.save ~root |> require_ok Service.error_to_string with
      | Service.Saved status ->
          Alcotest.(check bool)
            "changed file has a new exact snapshot" false
            (Model.Snapshot_id.equal initial.Service.checkpoint
               status.Service.checkpoint)
      | Service.Unchanged _ -> Alcotest.fail "changed tree did not save")

let new_draft_closes_the_previous_draft_without_losing_saved_state () =
  with_directory "yeokcham-v4-service-draft-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      let next =
        Service.new_draft ~root ~id:(draft "draft-two") ~title:"second work"
        |> require_ok Service.error_to_string
      in
      Alcotest.(check string)
        "new draft becomes active" "draft-two"
        (Model.Draft_id.to_string next.Service.active_draft.Model.draft_id);
      Alcotest.(check string)
        "new draft inherits the saved checkpoint"
        (Model.Snapshot_id.to_string initial.Service.checkpoint)
        (Model.Snapshot_id.to_string next.Service.checkpoint))

let restore_materializes_a_prior_checkpoint_without_touching_the_project () =
  with_directory "yeokcham-v4-service-restore-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      write_file root "main.ml" "let version = 2\n";
      ignore (Service.save ~root |> require_ok Service.error_to_string);
      let destination = Filename.concat root "recovered" in
      Unix.mkdir destination 0o700;
      Service.restore ~root ~checkpoint:initial.Service.checkpoint ~destination
      |> require_ok Service.error_to_string;
      Alcotest.(check string)
        "restored directory has the prior bytes" "let version = 1\n"
        (read_file destination "main.ml");
      Alcotest.(check string)
        "active project remains untouched" "let version = 2\n"
        (read_file root "main.ml"))

let restore_rejects_a_nonempty_destination () =
  with_directory "yeokcham-v4-service-restore-failure-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      let destination = Filename.concat root "occupied" in
      Unix.mkdir destination 0o700;
      write_file destination "already-here" "keep this\n";
      match
        Service.restore ~root ~checkpoint:initial.Service.checkpoint
          ~destination
      with
      | Error error ->
          Alcotest.(check bool)
            "destination safety error is explicit" true
            (String.starts_with
               ~prefix:"materialisation destination is not empty:"
               (Service.error_to_string error))
      | Ok () -> Alcotest.fail "restore wrote into a nonempty destination")

let v4_capture_excludes_git_metadata () =
  with_directory "yeokcham-v4-service-git-metadata-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let git = Filename.concat root ".git" in
      Unix.mkdir git 0o700;
      write_file git "config" "private metadata\n";
      let initial = initialize root in
      let destination = Filename.concat root "recovered" in
      Unix.mkdir destination 0o700;
      Service.restore ~root ~checkpoint:initial.Service.checkpoint ~destination
      |> require_ok Service.error_to_string;
      Alcotest.(check bool)
        "restored snapshot excludes the Git directory" false
        (Sys.file_exists (Filename.concat destination ".git")))

let () =
  Alcotest.run "V4 local service"
    [
      ( "saved work",
        [
          Alcotest.test_case "init captures and unchanged save is a no-op"
            `Quick init_captures_the_initial_tree_and_save_observes_no_change;
          Alcotest.test_case "changed save creates a checkpoint" `Quick
            changed_save_creates_a_new_checkpoint;
          Alcotest.test_case "new draft retains saved state" `Quick
            new_draft_closes_the_previous_draft_without_losing_saved_state;
          Alcotest.test_case "restore materializes a prior checkpoint" `Quick
            restore_materializes_a_prior_checkpoint_without_touching_the_project;
          Alcotest.test_case "restore rejects a nonempty destination" `Quick
            restore_rejects_a_nonempty_destination;
          Alcotest.test_case "capture excludes Git metadata" `Quick
            v4_capture_excludes_git_metadata;
        ] );
    ]
