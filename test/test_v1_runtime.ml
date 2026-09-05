let require_success name status stderr =
  match status with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code -> Alcotest.failf "%s exited %d: %s" name code stderr
  | Unix.WSIGNALED signal ->
      Alcotest.failf "%s was terminated by signal %d: %s" name signal stderr
  | Unix.WSTOPPED signal ->
      Alcotest.failf "%s was stopped by signal %d: %s" name signal stderr

let require_failure name status =
  match status with
  | Unix.WEXITED 0 -> Alcotest.failf "%s unexpectedly succeeded" name
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> ()

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
  let directory = Filename.temp_file prefix "" in
  Unix.unlink directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree directory)
    (fun () -> run directory)

let with_environment name value run =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv name (Option.value previous ~default:""))
    run

let executable () =
  let from_test_binary =
    Sys.executable_name |> Filename.dirname |> Filename.dirname
    |> fun build_root -> Filename.concat build_root "bin/yeokcham_v1.exe"
  in
  let candidates = [ from_test_binary; "_build/default/bin/yeokcham_v1.exe" ] in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.fail "cannot locate the yeokcham-v1 executable"

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

let contains text fragment =
  let text_length = String.length text in
  let fragment_length = String.length fragment in
  let rec loop index =
    if index + fragment_length > text_length then false
    else if String.equal (String.sub text index fragment_length) fragment then
      true
    else loop (index + 1)
  in
  loop 0

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

let read_file root name =
  In_channel.with_open_bin (Filename.concat root name) In_channel.input_all

let initialize root =
  write_file root "main.ml" "let revision = 1\n";
  let output, errors, status =
    run
      [
        "init";
        "--root";
        root;
        "--username";
        "alice";
        "--draft";
        "runtime-work";
        "--title";
        "runtime test";
      ]
  in
  require_success "init" status errors;
  saved_checkpoint output

let daemon command root = run [ "daemon"; command; "--root"; root ]
let daemon_sync root remote = run [ "daemon"; "sync"; "--root"; root; remote ]

let start root =
  let output, errors, status = daemon "start" root in
  require_success "daemon start" status errors;
  Alcotest.(check bool)
    "start reports success" true
    (contains output "runtime started")

let stop root =
  let output, errors, status = daemon "stop" root in
  require_success "daemon stop" status errors;
  Alcotest.(check bool)
    "stop reports success" true
    (contains output "ok stopping")

let daemon_status root =
  let output, errors, status = daemon "status" root in
  require_success "daemon status" status errors;
  output

let runtime_pid status =
  let prefix = "pid=" in
  let start =
    match String.index_opt status 'p' with
    | Some index
      when String.length status >= index + String.length prefix
           && String.equal
                (String.sub status index (String.length prefix))
                prefix ->
        index + String.length prefix
    | Some _ | None -> Alcotest.fail "daemon status did not contain a PID"
  in
  let finish =
    Option.value
      (String.index_from_opt status start '\n')
      ~default:(String.length status)
  in
  int_of_string (String.sub status start (finish - start))

let rec wait_for_checkpoint ~root previous attempts =
  if attempts = 0 then Alcotest.fail "daemon did not record a quiet edit"
  else (
    Unix.sleepf 0.2;
    let output, errors, status = run [ "status"; "--root"; root ] in
    require_success "status while daemon runs" status errors;
    let current = saved_checkpoint output in
    if String.equal previous current then
      wait_for_checkpoint ~root previous (attempts - 1)
    else current)

let with_runtime run_test =
  with_directory "yeokcham-v1-runtime-repository-" (fun root ->
      with_directory "yeokcham-v1-runtime-state-" (fun runtime ->
          let signer = Filename.concat runtime "signers" in
          Unix.mkdir signer 0o700;
          with_environment "XDG_RUNTIME_DIR" runtime (fun () ->
              with_environment "YEOKCHAM_V1_TEST_SIGNER_DIRECTORY" signer
                (fun () -> run_test ~root ~runtime))))

let daemon_captures_and_exposes_private_state () =
  with_runtime (fun ~root ~runtime ->
      let initial = initialize root in
      start root;
      Fun.protect
        ~finally:(fun () ->
          let _, _, _ = daemon "stop" root in
          Unix.sleepf 0.1)
        (fun () ->
          let status = daemon_status root in
          Alcotest.(check bool)
            "daemon protocol" true
            (contains status "yeokcham-runtime-v1 ok");
          Alcotest.(check bool)
            "runtime state has a version" true
            (contains status "yeokcham-runtime-state-v1");
          Alcotest.(check bool)
            "daemon is idle" true
            (contains status "task=idle");
          let state_root = Filename.concat runtime "yeokcham-v1" in
          let entries = Sys.readdir state_root in
          Alcotest.(check int)
            "one repository runtime directory" 1 (Array.length entries);
          let directory = Filename.concat state_root entries.(0) in
          Alcotest.(check int)
            "runtime directory is private" 0
            ((Unix.stat directory).Unix.st_perm land 0o077);
          Alcotest.(check bool)
            "state is present while running" true
            (Sys.file_exists (Filename.concat directory "runtime-state-v1"));
          Alcotest.(check bool)
            "state remains bounded" true
            ((Unix.stat (Filename.concat directory "runtime-state-v1"))
               .Unix.st_size <= 4096);
          let _, duplicate_errors, duplicate_status = daemon "start" root in
          require_failure "duplicate daemon start" duplicate_status;
          Alcotest.(check bool)
            "duplicate start explains ownership" true
            (contains duplicate_errors "already running");
          write_file root "main.ml" "let revision = 2\n";
          let recorded = wait_for_checkpoint ~root initial 30 in
          Alcotest.(check bool)
            "quiet edit creates another checkpoint" false
            (String.equal initial recorded)))

let explicit_sync_failure_does_not_capture_or_materialize () =
  with_runtime (fun ~root ~runtime:_ ->
      with_environment "YEOKCHAM_V1_TEST_TRANSPORT" "1" (fun () ->
          with_environment "YEOKCHAM_V1_TEST_TRANSPORT_TOKEN"
            "runtime-test-token" (fun () ->
              let initial = initialize root in
              let _, errors, status =
                run
                  [
                    "remote";
                    "add";
                    "--root";
                    root;
                    "offline";
                    "https://127.0.0.1:1";
                  ]
              in
              require_success "remote add offline" status errors;
              start root;
              Fun.protect
                ~finally:(fun () ->
                  let _, _, _ = daemon "stop" root in
                  Unix.sleepf 0.1)
                (fun () ->
                  let output, errors, status = daemon_sync root "offline" in
                  require_failure "daemon sync unavailable remote" status;
                  Alcotest.(check bool)
                    "unavailable remote is reported" true
                    (contains (output ^ errors) "error");
                  Alcotest.(check string)
                    "working-tree bytes are unchanged" "let revision = 1\n"
                    (read_file root "main.ml");
                  let status_output, status_errors, status_code =
                    run [ "status"; "--root"; root ]
                  in
                  require_success "status after failed daemon sync" status_code
                    status_errors;
                  Alcotest.(check string)
                    "failed sync did not create a checkpoint" initial
                    (saved_checkpoint status_output)))))

let crashed_runtime_releases_ownership_for_restart () =
  with_runtime (fun ~root ~runtime:_ ->
      let initial = initialize root in
      start root;
      let first = daemon_status root |> runtime_pid in
      write_file root "main.ml" "let revision = 2\n";
      Unix.kill first Sys.sigkill;
      Unix.sleepf 0.1;
      start root;
      let second = daemon_status root |> runtime_pid in
      Alcotest.(check bool)
        "restart uses a new daemon" false (Int.equal first second);
      let recorded = wait_for_checkpoint ~root initial 30 in
      Alcotest.(check bool)
        "restart captures work interrupted before debounce" false
        (String.equal initial recorded);
      Alcotest.(check string)
        "restart never rewrites ordinary bytes" "let revision = 2\n"
        (read_file root "main.ml");
      stop root)

let runtime_requires_private_xdg_directory () =
  with_directory "yeokcham-v1-runtime-no-xdg-" (fun root ->
      with_environment "XDG_RUNTIME_DIR" "" (fun () ->
          let output, errors, status = daemon "start" root in
          require_failure "daemon start without XDG_RUNTIME_DIR" status;
          Alcotest.(check bool)
            "missing XDG runtime directory is explicit" true
            (contains (output ^ errors) "XDG_RUNTIME_DIR is required"));
      with_directory "yeokcham-v1-runtime-public-" (fun runtime ->
          Unix.chmod runtime 0o755;
          with_environment "XDG_RUNTIME_DIR" runtime (fun () ->
              let output, errors, status = daemon "start" root in
              require_failure "daemon start with public XDG_RUNTIME_DIR" status;
              Alcotest.(check bool)
                "public XDG runtime directory is explicit" true
                (contains (output ^ errors)
                   "XDG_RUNTIME_DIR must not be accessible to other users"))))

let () =
  Alcotest.run "V1 Linux background runtime"
    [
      ( "lifecycle",
        [
          Alcotest.test_case "captures quiet edits and exposes private state"
            `Slow daemon_captures_and_exposes_private_state;
          Alcotest.test_case "crash releases ownership for restart" `Slow
            crashed_runtime_releases_ownership_for_restart;
          Alcotest.test_case "requires an XDG private runtime directory" `Quick
            runtime_requires_private_xdg_directory;
        ] );
      ( "receipt-boundary",
        [
          Alcotest.test_case
            "failed explicit sync leaves the tree and checkpoint alone" `Slow
            explicit_sync_failure_does_not_capture_or_materialize;
        ] );
    ]
