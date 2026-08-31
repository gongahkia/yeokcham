module Macos_watcher = Yeokcham_macos_watcher
module Watcher = Yeokcham_watcher

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

let write_file path contents =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel contents)

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Macos_watcher.error_to_string error)

let rec await_request watcher attempts =
  if attempts = 0 then Alcotest.fail "FSEvents did not produce a scan request"
  else
    match Macos_watcher.poll watcher ~timeout:0.25 with
    | Error error -> Alcotest.fail (Macos_watcher.error_to_string error)
    | Ok None -> await_request watcher (attempts - 1)
    | Ok (Some request) -> request

let assert_one_of_paths_or_whole_root name expected_paths request =
  match request.Watcher.target with
  | Watcher.Whole_root -> ()
  | Watcher.Paths paths ->
      Alcotest.(check bool)
        name true
        (List.exists (fun expected -> List.mem expected paths) expected_paths)

let observes_create_modify_delete_and_rename () =
  with_directory "yeokcham-v4-macos-fsevents-" (fun root ->
      let source = Filename.concat root "before.txt" in
      let destination = Filename.concat root "after.txt" in
      let observe change expected_paths =
        let watcher = Macos_watcher.start ~root |> require_ok in
        Fun.protect
          ~finally:(fun () -> Macos_watcher.close watcher)
          (fun () ->
            Unix.sleepf 0.1;
            change ();
            await_request watcher 24
            |> assert_one_of_paths_or_whole_root "FSEvents changed path"
                 expected_paths)
      in
      observe (fun () -> write_file source "one\n") [ [ "before.txt" ] ];
      observe (fun () -> write_file source "two\n") [ [ "before.txt" ] ];
      observe
        (fun () -> Unix.rename source destination)
        [ [ "before.txt" ]; [ "after.txt" ] ];
      observe (fun () -> Unix.unlink destination) [ [ "after.txt" ] ])

let metadata_only_activity_never_narrows_to_a_source_path () =
  with_directory "yeokcham-v4-macos-fsevents-metadata-" (fun root ->
      let metadata = Filename.concat root ".yeokcham" in
      Unix.mkdir metadata 0o700;
      let watcher = Macos_watcher.start ~root |> require_ok in
      Fun.protect
        ~finally:(fun () -> Macos_watcher.close watcher)
        (fun () ->
          Unix.sleepf 0.1;
          write_file (Filename.concat metadata "local") "not source\n";
          match Macos_watcher.poll watcher ~timeout:0.8 with
          | Ok None -> ()
          | Ok (Some request) -> (
              match request.Watcher.target with
              | Watcher.Whole_root -> ()
              | Watcher.Paths _ ->
                  Alcotest.fail
                    "ambiguous metadata activity narrowed to a source path")
          | Error error -> Alcotest.fail (Macos_watcher.error_to_string error)))

let close_releases_the_source () =
  with_directory "yeokcham-v4-macos-fsevents-close-" (fun root ->
      let watcher = Macos_watcher.start ~root |> require_ok in
      Macos_watcher.close watcher;
      Macos_watcher.close watcher;
      match Macos_watcher.poll watcher ~timeout:0.0 with
      | Error error ->
          Alcotest.(check bool)
            "closed source is explicit" true
            (error = Macos_watcher.Closed)
      | Ok _ -> Alcotest.fail "closed source remained usable")

let normalization_excludes_metadata_without_losing_metadata_renames () =
  let root = "/private/tmp/yeokcham-fsevents-normalization" in
  let metadata = Filename.concat root ".yeokcham/local" in
  (match
     Macos_watcher.normalize ~root [ Macos_watcher.Path_changed metadata ]
   with
  | Ok None -> ()
  | Ok (Some _) | Error _ ->
      Alcotest.fail "ordinary metadata change scheduled a source scan");
  let request =
    Macos_watcher.normalize ~root
      [ Macos_watcher.Item_renamed (Filename.concat root ".git") ]
    |> require_ok
  in
  match request with
  | Some request
    when request.Watcher.reason = Watcher.Rename
         && request.Watcher.target = Watcher.Paths [ [ ".git" ] ] ->
      ()
  | None | Some _ ->
      Alcotest.fail
        "rename into metadata was discarded as an invented safe event"

let normalization_treats_an_outside_path_as_loss () =
  let request =
    Macos_watcher.normalize ~root:"/private/tmp/yeokcham-fsevents-normalization"
      [ Macos_watcher.Path_changed "/private/tmp/another-root/file" ]
    |> require_ok
  in
  match request with
  | Some request
    when request.Watcher.reason = Watcher.Watcher_lost
         && request.Watcher.target = Watcher.Whole_root ->
      ()
  | None | Some _ -> Alcotest.fail "outside path did not become watcher loss"

let root_loss_requests_restart_without_a_path_guess () =
  with_directory "yeokcham-v4-macos-fsevents-root-loss-" (fun root ->
      let watched = Filename.concat root "watched" in
      Unix.mkdir watched 0o700;
      let watcher = Macos_watcher.start ~root:watched |> require_ok in
      Fun.protect
        ~finally:(fun () -> Macos_watcher.close watcher)
        (fun () ->
          Unix.sleepf 0.1;
          Unix.rmdir watched;
          let rec await_loss attempts =
            if attempts = 0 then
              Alcotest.fail "FSEvents did not report root loss"
            else
              match Macos_watcher.poll watcher ~timeout:0.25 with
              | Error error ->
                  Alcotest.fail (Macos_watcher.error_to_string error)
              | Ok (Some request)
                when request.Watcher.reason = Watcher.Watcher_lost ->
                  request
              | Ok None | Ok (Some _) -> await_loss (attempts - 1)
          in
          let request = await_loss 24 in
          Alcotest.(check bool)
            "root loss remains explicit" true
            (request.Watcher.reason = Watcher.Watcher_lost);
          Alcotest.(check bool)
            "root loss scans the whole root" true
            (request.Watcher.target = Watcher.Whole_root);
          match Macos_watcher.poll watcher ~timeout:0.0 with
          | Error error ->
              Alcotest.(check bool)
                "restart is explicit" true
                (error = Macos_watcher.Needs_restart)
          | Ok _ -> Alcotest.fail "root loss did not require source restart"))

let rapid_rename_storm_remains_advisory () =
  with_directory "yeokcham-v4-macos-fsevents-storm-" (fun root ->
      let first = Filename.concat root "first" in
      let second = Filename.concat root "second" in
      write_file first "stable bytes\n";
      let watcher = Macos_watcher.start ~root |> require_ok in
      Fun.protect
        ~finally:(fun () -> Macos_watcher.close watcher)
        (fun () ->
          Unix.sleepf 0.1;
          for index = 1 to 200 do
            if index mod 2 = 0 then Unix.rename second first
            else Unix.rename first second
          done;
          let request = await_request watcher 24 in
          match request.Watcher.target with
          | Watcher.Whole_root -> ()
          | Watcher.Paths paths ->
              Alcotest.(check bool)
                "storm paths remain bounded" true
                (List.length paths <= Watcher.max_paths_per_request)))

let () =
  Alcotest.run "V4 macOS FSEvents watcher"
    [
      ( "native source",
        [
          Alcotest.test_case "observes ordinary source changes" `Slow
            observes_create_modify_delete_and_rename;
          Alcotest.test_case "metadata activity never narrows ambiguously" `Slow
            metadata_only_activity_never_narrows_to_a_source_path;
          Alcotest.test_case "close is idempotent" `Quick
            close_releases_the_source;
          Alcotest.test_case "metadata filtering remains conservative" `Quick
            normalization_excludes_metadata_without_losing_metadata_renames;
          Alcotest.test_case "outside paths force watcher loss" `Quick
            normalization_treats_an_outside_path_as_loss;
          Alcotest.test_case "root loss is restartable" `Slow
            root_loss_requests_restart_without_a_path_guess;
          Alcotest.test_case "rename storm stays bounded" `Slow
            rapid_rename_storm_remains_advisory;
        ] );
    ]
