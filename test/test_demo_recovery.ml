let require condition message = if not condition then Alcotest.fail message

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

let find_file label candidates =
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.fail (label ^ " is unavailable")

let script name =
  let cwd = Sys.getcwd () in
  find_file name
    [
      Filename.concat cwd ("tools/demo/" ^ name);
      Filename.concat cwd ("../tools/demo/" ^ name);
    ]

let yeokcham_binary () =
  let cwd = Sys.getcwd () in
  find_file "yeokcham executable"
    [
      Filename.concat cwd "_build/default/bin/yeokcham.exe";
      Filename.concat cwd "../bin/yeokcham.exe";
      Filename.concat cwd "../_build/default/bin/yeokcham.exe";
    ]

let environment key value =
  Unix.environment () |> Array.to_list
  |> List.filter (fun entry ->
      not (String.starts_with ~prefix:(key ^ "=") entry))
  |> fun entries -> Array.of_list ((key ^ "=" ^ value) :: entries)

let run ~environment program arguments =
  let output = Filename.temp_file "yeokcham-demo-recovery-output-" "" in
  Fun.protect
    ~finally:(fun () -> remove_tree output)
    (fun () ->
      let descriptor =
        Unix.openfile output [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
      in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let process =
            Unix.create_process_env program
              (Array.of_list (program :: arguments))
              environment Unix.stdin descriptor descriptor
          in
          Unix.waitpid [] process |> snd))

let exited status expected =
  match status with
  | Unix.WEXITED actual -> actual = expected
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () ->
      let length = in_channel_length input in
      really_input_string input length)

let safety_checkpoint_is_retained_after_exact_restore () =
  let parent = Filename.temp_file "yeokcham-demo-recovery-" "" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  let root = Filename.concat parent "fixture" in
  Fun.protect
    ~finally:(fun () -> remove_tree parent)
    (fun () ->
      let environment =
        environment "YEOKCHAM_BIN" (yeokcham_binary ())
        |> Array.to_list
        |> List.filter (fun entry ->
            not (String.starts_with ~prefix:"YEOKCHAM_LEGACY_DEMO_V1=" entry))
        |> fun entries -> Array.of_list ("YEOKCHAM_LEGACY_DEMO_V1=1" :: entries)
      in
      let created =
        run ~environment "sh"
          [ script "create-repository-v1.sh"; "--root"; root ]
      in
      require (exited created 0) "fixture creation failed";
      let restored =
        run ~environment "sh"
          [ script "demonstrate-recovery-v1.sh"; "--root"; root ]
      in
      Alcotest.(check bool) "recovery succeeds" true (exited restored 0);
      Alcotest.(check string)
        "restored bytes" "keep exact bytes\n"
        (read_file (Filename.concat root "docs/todo.txt"));
      require
        (Sys.file_exists (Filename.concat root "README.md"))
        "initial file is restored";
      require
        (not (Sys.file_exists (Filename.concat root "CHANGELOG.md")))
        "renamed file is absent";
      require
        (not (Sys.file_exists (Filename.concat root "notes.txt")))
        "post-initial file is absent";
      require
        (not (Sys.file_exists (Filename.concat root "divergent.txt")))
        "divergent file is absent";
      require
        ((Unix.stat (Filename.concat root "bin/run-demo")).Unix.st_perm
         land 0o111
        <> 0)
        "initial executable mode is restored";
      Alcotest.(check string)
        "restored symlink target" "docs/todo.txt"
        (Unix.readlink (Filename.concat root "current-note"));
      let recovery =
        read_file (Filename.concat root ".yeokcham/demo-v1-recovery")
        |> String.trim
      in
      require (String.length recovery = 80) "recovery output is malformed";
      let safety = String.sub recovery 16 64 in
      let safety_plan =
        run ~environment (yeokcham_binary ())
          [ "restore"; "--dry-run"; safety; "--root"; root ]
      in
      Alcotest.(check bool)
        "safety checkpoint remains restorable" true (exited safety_plan 0))

let unowned_roots_reject_before_recovery () =
  let parent = Filename.temp_file "yeokcham-demo-unowned-" "" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  let root = Filename.concat parent "unowned" in
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree parent)
    (fun () ->
      let result =
        run ~environment:(Unix.environment ()) "sh"
          [ script "demonstrate-recovery-v1.sh"; "--root"; root ]
      in
      Alcotest.(check bool) "unowned root rejects" true (exited result 2);
      require
        (Sys.readdir root |> Array.length = 0)
        "rejected root remains unchanged")

let () =
  Alcotest.run "automatic recovery demonstration"
    [
      ( "recovery",
        [
          Alcotest.test_case "exact restore retains safety checkpoint" `Quick
            safety_checkpoint_is_retained_after_exact_restore;
          Alcotest.test_case "unowned root rejects before recovery" `Quick
            unowned_roots_reject_before_recovery;
        ] );
    ]
