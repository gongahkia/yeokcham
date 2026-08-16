module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

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
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> run path)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let target_history run =
  with_directory "yeokcham-restore-" (fun root ->
      write_file (Filename.concat root "file") "base";
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let scratch = Scratch.open_repository store in
      let base, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      ignore
        (Scratch.create_initial scratch ~snapshot:base ~created_at:10L
        |> require_ok Scratch.error_to_string);
      write_file (Filename.concat root "file") "target";
      Unix.chmod (Filename.concat root "file") 0o755;
      Unix.mkdir (Filename.concat root "nested") 0o700;
      write_file
        (Filename.concat (Filename.concat root "nested") "guide")
        "guide\n";
      Unix.symlink "file" (Filename.concat root "link");
      let target_snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let target =
        Scratch.checkpoint scratch ~snapshot:target_snapshot
          ~source:Scratch.Explicit ~observed_at:20L ~created_at:21L
        |> require_ok Scratch.error_to_string
      in
      let target =
        match target with
        | Scratch.Created checkpoint -> checkpoint
        | Scratch.Unchanged _ ->
            Alcotest.fail "target state was not checkpointed"
      in
      run root store scratch target)

let mutate_current root =
  write_file (Filename.concat root "file") "current";
  Unix.chmod (Filename.concat root "file") 0o644;
  Unix.unlink (Filename.concat root "link");
  Unix.symlink "elsewhere" (Filename.concat root "link");
  write_file (Filename.concat root "untracked") "preserve through safety"

let successful_restore_is_exact_and_saves_safety () =
  target_history (fun root store scratch target ->
      mutate_current root;
      let safety =
        Scratch.Restore.restore scratch ~root
          ~target:(Scratch.Checkpoint.id target)
          ~observed_at:30L ~created_at:31L
        |> require_ok Scratch.error_to_string
      in
      let safety =
        match safety with
        | Some checkpoint -> checkpoint
        | None ->
            Alcotest.fail "differing work did not receive a safety checkpoint"
      in
      Alcotest.(check string)
        "restored bytes" "target"
        (read_file (Filename.concat root "file"));
      Alcotest.(check bool)
        "restored executable mode" true
        ((Unix.stat (Filename.concat root "file")).Unix.st_perm land 0o111 <> 0);
      Alcotest.(check string)
        "restored symlink target" "file"
        (Unix.readlink (Filename.concat root "link"));
      Alcotest.(check bool)
        "untracked path is removed" false
        (Sys.file_exists (Filename.concat root "untracked"));
      let head = Scratch.head scratch |> require_ok Scratch.error_to_string in
      (match head with
      | Some checkpoint ->
          Alcotest.(check bool)
            "target becomes head after verification" true
            (Scratch.Checkpoint_id.equal
               (Scratch.Checkpoint.id checkpoint)
               (Scratch.Checkpoint.id target))
      | None -> Alcotest.fail "restore removed scratch head");
      with_directory "yeokcham-restore-safety-materialized-" (fun destination ->
          let checkpoint =
            Scratch.timeline scratch ~start:safety ~limit:1 ()
            |> require_ok Scratch.error_to_string
            |> List.hd
          in
          let snapshot =
            Snapshot.Snapshot.load store
              (Scratch.Checkpoint.snapshot checkpoint.Scratch.checkpoint)
            |> require_ok Snapshot.error_to_string
          in
          Snapshot.Materialize.write ~destination store snapshot
          |> require_ok Snapshot.Materialize.error_to_string;
          Alcotest.(check string)
            "safety bytes" "current"
            (read_file (Filename.concat destination "file"));
          Alcotest.(check string)
            "safety symlink" "elsewhere"
            (Unix.readlink (Filename.concat destination "link"));
          Alcotest.(check string)
            "safety untracked bytes" "preserve through safety"
            (read_file (Filename.concat destination "untracked"))))

let external_change_aborts_without_target_head () =
  target_history (fun root _store scratch target ->
      mutate_current root;
      let plan =
        Scratch.Restore.prepare scratch ~root
          ~target:(Scratch.Checkpoint.id target)
          ~observed_at:40L ~created_at:41L
        |> require_ok Scratch.error_to_string
      in
      let safety =
        match Scratch.Restore.safety_checkpoint plan with
        | Some checkpoint -> checkpoint
        | None -> Alcotest.fail "prepare did not create safety checkpoint"
      in
      write_file (Filename.concat root "file") "external";
      (match Scratch.Restore.apply scratch ~root plan with
      | Error error ->
          Alcotest.(check bool)
            "external change is explicit" true
            (String.starts_with ~prefix:"restore plan is stale: "
               (Scratch.error_to_string error))
      | Ok () -> Alcotest.fail "restore applied after external mutation");
      let head = Scratch.head scratch |> require_ok Scratch.error_to_string in
      match head with
      | Some checkpoint ->
          Alcotest.(check bool)
            "failed restore does not move target head" true
            (Scratch.Checkpoint_id.equal
               (Scratch.Checkpoint.id checkpoint)
               safety)
      | None -> Alcotest.fail "failed restore removed scratch head")

let dry_run_is_nonmutating () =
  target_history (fun root _store scratch target ->
      mutate_current root;
      let before = Scratch.head scratch |> require_ok Scratch.error_to_string in
      let plan =
        Scratch.Restore.dry_run scratch ~root
          ~target:(Scratch.Checkpoint.id target)
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check bool)
        "dry-run reports work" true
        (Scratch.Restore.actions plan <> []);
      let after = Scratch.head scratch |> require_ok Scratch.error_to_string in
      match (before, after) with
      | Some before, Some after ->
          Alcotest.(check bool)
            "dry-run does not move head" true
            (Scratch.Checkpoint_id.equal
               (Scratch.Checkpoint.id before)
               (Scratch.Checkpoint.id after))
      | None, None | Some _, None | None, Some _ ->
          Alcotest.fail "dry-run changed scratch-head existence")

let regular_file_to_symlink_restore_is_exact () =
  target_history (fun root _store scratch target ->
      let link = Filename.concat root "link" in
      Unix.unlink link;
      write_file link "ordinary file";
      ignore
        (Scratch.Restore.restore scratch ~root
           ~target:(Scratch.Checkpoint.id target)
           ~observed_at:50L ~created_at:51L
        |> require_ok Scratch.error_to_string);
      Alcotest.(check string)
        "regular file is replaced by target symlink" "file" (Unix.readlink link))

let restore_reports_exact_action_progress () =
  target_history (fun root _store scratch target ->
      mutate_current root;
      let expected =
        Scratch.Restore.dry_run scratch ~root
          ~target:(Scratch.Checkpoint.id target)
        |> require_ok Scratch.error_to_string
        |> Scratch.Restore.actions |> List.length
      in
      let observed = ref [] in
      ignore
        (Scratch.Restore.restore scratch ~root
           ~target:(Scratch.Checkpoint.id target)
           ~observed_at:60L ~created_at:61L
           ~on_progress:(fun ~completed ~total ->
             observed := (completed, total) :: !observed)
        |> require_ok Scratch.error_to_string);
      Alcotest.(check (list (pair int int))) "restore action sequence"
        (List.init (expected + 1) (fun completed -> (completed, expected)))
        (List.rev !observed))

let () =
  Alcotest.run "guarded restore"
    [
      ( "unit",
        [
          Alcotest.test_case "exact restore retains safety work" `Quick
            successful_restore_is_exact_and_saves_safety;
          Alcotest.test_case "external mutation aborts before application"
            `Quick external_change_aborts_without_target_head;
          Alcotest.test_case "dry-run does not move scratch head" `Quick
            dry_run_is_nonmutating;
          Alcotest.test_case "regular file to symlink restore is exact" `Quick
            regular_file_to_symlink_restore_is_exact;
          Alcotest.test_case "restore reports exact applied action progress"
            `Quick restore_reports_exact_action_progress;
        ] );
    ]
