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

let occurrences needle haystack =
  let length = String.length needle in
  let rec count position total =
    match String.index_from_opt haystack position needle.[0] with
    | None -> total
    | Some index
      when index + length <= String.length haystack
           && String.equal needle (String.sub haystack index length) ->
        count (index + length) (total + 1)
    | Some index -> count (index + 1) total
  in
  if String.equal needle "" then
    invalid_arg "occurrences needs a nonempty needle"
  else count 0 0

let rec wait_for_exit pid remaining =
  if remaining = 0 then Alcotest.fail "watcher did not exit after root loss"
  else
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
        Unix.sleepf 0.2;
        wait_for_exit pid (remaining - 1)
    | _, status -> status

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

let watch_debounces_a_rapid_edit_storm () =
  with_directory "yeokcham-v4-watch-storm-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let _output, errors, status =
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
            "watch-storm";
          ]
      in
      require_success "init" status errors;
      let log = Filename.temp_file "yeokcham-v4-watch-storm-log-" "" in
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
          (try ignore (Unix.waitpid [] pid)
           with Unix.Unix_error (Unix.ECHILD, _, _) -> ());
          try Unix.unlink log with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
        (fun () ->
          Unix.sleepf 0.3;
          for version = 2 to 80 do
            write_file root "main.ml"
              (Printf.sprintf "let version = %d\n" version)
          done;
          Unix.sleepf 2.0;
          let output = In_channel.with_open_bin log In_channel.input_all in
          Alcotest.(check int)
            "one debounced save for the storm" 1
            (occurrences "save recorded\n" output)))

let watch_exits_after_permanent_root_loss () =
  with_directory "yeokcham-v4-watch-root-loss-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let _output, errors, status =
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
            "watch-root-loss";
          ]
      in
      require_success "init" status errors;
      let log = Filename.temp_file "yeokcham-v4-watch-root-loss-log-" "" in
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
          (try ignore (Unix.waitpid [] pid)
           with Unix.Unix_error (Unix.ECHILD, _, _) -> ());
          try Unix.unlink log with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
        (fun () ->
          Unix.sleepf 0.3;
          remove_tree root;
          match wait_for_exit pid 30 with
          | Unix.WEXITED 2 -> ()
          | Unix.WEXITED code ->
              Alcotest.failf "watch root-loss exit code was %d" code
          | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
              Alcotest.failf "watch root-loss stopped with signal %d" signal))

let () =
  Alcotest.run "V4 foreground watch"
    [
      ( "capture",
        [
          Alcotest.test_case "watch records a checkpoint after quiet edits"
            `Slow watch_records_a_checkpoint_after_quiet_edits;
          Alcotest.test_case "watch debounces a rapid edit storm" `Slow
            watch_debounces_a_rapid_edit_storm;
          Alcotest.test_case "watch exits after permanent root loss" `Slow
            watch_exits_after_permanent_root_loss;
        ] );
    ]
