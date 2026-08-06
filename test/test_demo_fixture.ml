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
  let output = Filename.temp_file "yeokcham-demo-test-output-" "" in
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

let created_fixture_has_the_documented_oracle () =
  let parent = Filename.temp_file "yeokcham-demo-fixture-" "" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  let root = Filename.concat parent "fixture" in
  Fun.protect
    ~finally:(fun () -> remove_tree parent)
    (fun () ->
      let environment = environment "YEOKCHAM_BIN" (yeokcham_binary ()) in
      let created =
        run ~environment "sh"
          [ script "create-repository-v1.sh"; "--root"; root ]
      in
      Alcotest.(check bool) "fixture creation succeeds" true (exited created 0);
      require
        (Sys.file_exists (Filename.concat root ".yeokcham"))
        "initialisation creates a Yeokcham repository";
      require
        (not (Sys.file_exists (Filename.concat root "README.md")))
        "the unchanged file is renamed";
      Alcotest.(check string)
        "modified bytes" "keep exact bytes, revised\n"
        (read_file (Filename.concat root "docs/todo.txt"));
      Alcotest.(check string)
        "created bytes" "created after the initial checkpoint\n"
        (read_file (Filename.concat root "notes.txt"));
      Alcotest.(check int)
        "mode change is non-executable" 0
        ((Unix.stat (Filename.concat root "bin/run-demo")).Unix.st_perm
       land 0o111);
      Alcotest.(check string)
        "symlink target" "docs/todo.txt"
        (Unix.readlink (Filename.concat root "current-note"));
      let timeline =
        read_file (Filename.concat root ".yeokcham/demo-v1-timeline")
      in
      require
        (List.length (String.split_on_char '\n' timeline) >= 2)
        "timeline contains initial and changed checkpoints";
      let removed =
        run ~environment "sh"
          [ script "cleanup-repository-v1.sh"; "--root"; root ]
      in
      Alcotest.(check bool) "guarded cleanup succeeds" true (exited removed 0);
      require (not (Sys.file_exists root)) "cleanup removes the fixture root")

let existing_roots_are_rejected_without_initialisation () =
  let parent = Filename.temp_file "yeokcham-demo-existing-" "" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  let root = Filename.concat parent "existing" in
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree parent)
    (fun () ->
      let result =
        run ~environment:(Unix.environment ()) "sh"
          [ script "create-repository-v1.sh"; "--root"; root ]
      in
      Alcotest.(check bool) "existing target rejects" true (exited result 2);
      require
        (not (Sys.file_exists (Filename.concat root ".yeokcham")))
        "rejected root has no Yeokcham state")

let failed_creation_removes_the_owned_root () =
  let parent = Filename.temp_file "yeokcham-demo-failed-" "" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  let root = Filename.concat parent "fixture" in
  Fun.protect
    ~finally:(fun () -> remove_tree parent)
    (fun () ->
      let failed =
        run
          ~environment:(environment "YEOKCHAM_BIN" "/nonexistent/yeokcham")
          "sh"
          [ script "create-repository-v1.sh"; "--root"; root ]
      in
      Alcotest.(check bool) "invalid executable rejects" true (exited failed 2);
      require
        (not (Sys.file_exists root))
        "failed creation removes only its owned root")

let () =
  Alcotest.run "scripted demonstration repository"
    [
      ( "fixture",
        [
          Alcotest.test_case "creation, oracle, and guarded cleanup" `Quick
            created_fixture_has_the_documented_oracle;
          Alcotest.test_case "existing root is rejected" `Quick
            existing_roots_are_rejected_without_initialisation;
          Alcotest.test_case "failed creation cleans its owned root" `Quick
            failed_creation_removes_the_owned_root;
        ] );
    ]
