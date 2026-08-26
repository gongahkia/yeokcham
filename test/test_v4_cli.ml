let require_success name status stderr =
  match status with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code -> Alcotest.failf "%s exited %d: %s" name code stderr
  | Unix.WSIGNALED signal ->
      Alcotest.failf "%s was terminated by signal %d: %s" name signal stderr
  | Unix.WSTOPPED signal ->
      Alcotest.failf "%s was stopped by signal %d: %s" name signal stderr

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

let executable () =
  let from_test_binary =
    Sys.executable_name |> Filename.dirname |> Filename.dirname
    |> fun build_root -> Filename.concat build_root "bin/yeokcham_v4.exe"
  in
  let candidates = [ from_test_binary; "_build/default/bin/yeokcham_v4.exe" ] in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.fail "cannot locate the yeokcham-v4 executable"

let run arguments =
  let command =
    executable () :: arguments |> List.map Filename.quote |> String.concat " "
  in
  let stdout, stdin, stderr =
    Unix.open_process_full command (Unix.environment ())
  in
  close_out_noerr stdin;
  let output = In_channel.input_all stdout in
  let errors = In_channel.input_all stderr in
  let status = Unix.close_process_full (stdout, stdin, stderr) in
  (output, errors, status)

let contains output needle =
  let needle_length = String.length needle in
  let rec find index =
    if index + needle_length > String.length output then false
    else if String.equal (String.sub output index needle_length) needle then
      true
    else find (index + 1)
  in
  needle_length > 0 && find 0

let expect_output_contains name needle output =
  Alcotest.(check bool) name true (contains output needle)

let write_file root name contents =
  Out_channel.with_open_bin (Filename.concat root name) (fun channel ->
      Out_channel.output_string channel contents)

let command_journey_reports_saved_work_and_drafts () =
  with_directory "yeokcham-v4-cli-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let output, errors, status =
        run
          [
            "init";
            "--root";
            root;
            "--device";
            "device-alice";
            "--draft";
            "draft-one";
            "--title";
            "first-work";
          ]
      in
      require_success "init" status errors;
      expect_output_contains "init reports a saved checkpoint" "saved " output;
      let output, errors, status = run [ "save"; "--root"; root ] in
      require_success "unchanged save" status errors;
      expect_output_contains "unchanged save is explicit" "save unchanged"
        output;
      write_file root "main.ml" "let version = 2\n";
      let output, errors, status = run [ "save"; "--root"; root ] in
      require_success "changed save" status errors;
      expect_output_contains "changed save is explicit" "save recorded" output;
      let output, errors, status =
        run
          [
            "draft";
            "new";
            "--root";
            root;
            "--id";
            "draft-two";
            "--title";
            "second-work";
          ]
      in
      require_success "new draft" status errors;
      expect_output_contains "new active draft is rendered" "draft draft-two"
        output;
      let output, errors, status = run [ "status"; "--root"; root ] in
      require_success "status" status errors;
      expect_output_contains "status renders no shared work" "shared 0" output;
      expect_output_contains "status renders no decisions" "needs-decision 0"
        output;
      expect_output_contains "status renders no deliveries" "delivered 0" output)

let () =
  Alcotest.run "V4 CLI"
    [
      ( "journey",
        [
          Alcotest.test_case "saved work and drafts" `Quick
            command_journey_reports_saved_work_and_drafts;
        ] );
    ]
