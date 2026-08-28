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
  let signer_directory = Filename.temp_file (prefix ^ "signer-") "" in
  Unix.unlink signer_directory;
  Unix.mkdir signer_directory 0o700;
  Unix.putenv "YEOKCHAM_V4_TEST_SIGNER_DIRECTORY" signer_directory;
  Fun.protect
    ~finally:(fun () ->
      remove_tree root;
      remove_tree signer_directory)
    (fun () -> run root)

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

let saved_checkpoint output =
  let prefix = "saved " in
  let prefix_length = String.length prefix in
  let rec find index =
    if index + prefix_length > String.length output then
      Alcotest.fail "CLI output did not contain a saved checkpoint"
    else if String.equal (String.sub output index prefix_length) prefix then
      let value_start = index + prefix_length in
      match String.index_from_opt output value_start '\n' with
      | Some value_end -> String.sub output value_start (value_end - value_start)
      | None ->
          Alcotest.fail "saved checkpoint output was not newline-terminated"
    else find (index + 1)
  in
  find 0

let write_file root name contents =
  Out_channel.with_open_bin (Filename.concat root name) (fun channel ->
      Out_channel.output_string channel contents)

let rec wait_for_new_checkpoint ~root previous remaining =
  if remaining = 0 then Alcotest.fail "watcher did not record a new checkpoint"
  else (
    Unix.sleepf 0.2;
    let output, errors, status = run [ "status"; "--root"; root ] in
    require_success "status while watching" status errors;
    let current = saved_checkpoint output in
    if String.equal current previous then
      wait_for_new_checkpoint ~root previous (remaining - 1)
    else current)

let watch_records_a_checkpoint_after_quiet_edits () =
  with_directory "yeokcham-v4-watch-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let output, errors, status =
        run
          [
            "init";
            "--root";
            root;
            "--username";
            "alice";
            "--draft";
            "draft-one";
            "--title";
            "watch-work";
          ]
      in
      require_success "init" status errors;
      let initial = saved_checkpoint output in
      let log = Filename.temp_file "yeokcham-v4-watch-log-" "" in
      let log_fd =
        Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
      in
      let exe = executable () in
      let pid =
        Unix.create_process exe
          [| exe; "watch"; "--root"; root |]
          Unix.stdin log_fd log_fd
      in
      Fun.protect
        ~finally:(fun () ->
          Unix.close log_fd;
          (try Unix.kill pid Sys.sigterm
           with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
          ignore (Unix.waitpid [] pid);
          try Unix.unlink log with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
        (fun () ->
          Unix.sleepf 0.3;
          write_file root "main.ml" "let version = 2\n";
          let recorded = wait_for_new_checkpoint ~root initial 25 in
          Alcotest.(check bool)
            "watch save differs from init" false
            (String.equal recorded initial)))

let () =
  Alcotest.run "V4 Linux watch"
    [
      ( "capture",
        [
          Alcotest.test_case "watch records a checkpoint after quiet edits"
            `Slow watch_records_a_checkpoint_after_quiet_edits;
        ] );
    ]
