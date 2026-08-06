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

let paengi_binary () =
  let cwd = Sys.getcwd () in
  find_file "paengi executable"
    [
      Filename.concat cwd "_build/default/bin/paengi.exe";
      Filename.concat cwd "../bin/paengi.exe";
      Filename.concat cwd "../_build/default/bin/paengi.exe";
    ]

let environment key value =
  Unix.environment () |> Array.to_list
  |> List.filter (fun entry ->
      not (String.starts_with ~prefix:(key ^ "=") entry))
  |> fun entries -> Array.of_list ((key ^ "=" ^ value) :: entries)

let run ~environment program arguments =
  let output = Filename.temp_file "paengi-demo-compaction-output-" "" in
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

let report_count name report =
  let prefix = name ^ "=" in
  match
    String.split_on_char ' ' (String.trim report)
    |> List.find_opt (String.starts_with ~prefix)
  with
  | None -> None
  | Some field ->
      String.sub field (String.length prefix)
        (String.length field - String.length prefix)
      |> int_of_string_opt

let run_fixture ?(prune = false) verify =
  let parent = Filename.temp_file "paengi-demo-compaction-" "" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  let root = Filename.concat parent "fixture" in
  Fun.protect
    ~finally:(fun () -> remove_tree parent)
    (fun () ->
      let environment = environment "PAENGI_BIN" (paengi_binary ()) in
      let created =
        run ~environment "sh"
          [ script "create-repository-v1.sh"; "--root"; root ]
      in
      require (exited created 0) "fixture creation failed";
      let arguments =
        [ script "demonstrate-compaction-v1.sh"; "--root"; root ]
        |> fun arguments ->
        if prune then arguments @ [ "--prune" ] else arguments
      in
      let compacted = run ~environment "sh" arguments in
      require (exited compacted 0) "compaction demonstration failed";
      verify environment root)

let retained_logical_ids_restore_exactly () =
  run_fixture (fun environment root ->
      let initial =
        read_file (Filename.concat root ".paengi/demo-v1-initial-checkpoint")
        |> String.trim
      in
      let head =
        read_file (Filename.concat root ".paengi/demo-v1-compaction-head")
        |> String.trim
      in
      let restore checkpoint =
        let result =
          run ~environment (paengi_binary ())
            [ "restore"; checkpoint; "--root"; root ]
        in
        require (exited result 0) "retained logical checkpoint did not restore"
      in
      restore initial;
      Alcotest.(check string)
        "initial bytes survive compaction" "keep exact bytes\n"
        (read_file (Filename.concat root "docs/todo.txt"));
      require
        ((Unix.stat (Filename.concat root "bin/run-demo")).Unix.st_perm
         land 0o111
        <> 0)
        "initial executable mode survives compaction";
      Alcotest.(check string)
        "initial symlink survives compaction" "docs/todo.txt"
        (Unix.readlink (Filename.concat root "current-note"));
      restore head;
      Alcotest.(check string)
        "head bytes survive compaction" "compaction head bytes\n"
        (read_file (Filename.concat root "notes.txt"));
      let dry_run =
        read_file (Filename.concat root ".paengi/demo-v1-compaction-dry-run")
      in
      let resumed =
        read_file (Filename.concat root ".paengi/demo-v1-compaction-resume")
      in
      require
        (String.starts_with ~prefix:"policy recent-window-seconds=1" dry_run)
        "dry-run records the explicit policy";
      require
        (String.starts_with ~prefix:"generation=" resumed)
        "resume records its structured report";
      require
        (not
           (Sys.file_exists
              (Filename.concat root ".paengi/demo-v1-compaction-prune")))
        "default demonstration does not prune")

let explicit_prune_is_limited_to_the_disposable_fixture () =
  run_fixture ~prune:true (fun environment root ->
      let prune =
        read_file (Filename.concat root ".paengi/demo-v1-compaction-prune")
      in
      require
        (String.starts_with ~prefix:"generation=" prune)
        "prune records its structured report";
      require
        (Option.value (report_count "pruned-objects" prune) ~default:0 > 0)
        "prune report contains a nonzero irreversible action";
      let initial =
        read_file (Filename.concat root ".paengi/demo-v1-initial-checkpoint")
        |> String.trim
      in
      let result =
        run ~environment (paengi_binary ())
          [ "restore"; "--dry-run"; initial; "--root"; root ]
      in
      require (exited result 0) "pinned retained checkpoint survives prune")

let () =
  Alcotest.run "scratch compaction demonstration"
    [
      ( "compaction",
        [
          Alcotest.test_case "retained logical IDs restore exactly" `Quick
            retained_logical_ids_restore_exactly;
          Alcotest.test_case "explicit prune stays fixture-local" `Quick
            explicit_prune_is_limited_to_the_disposable_fixture;
        ] );
    ]
