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

let find label candidates =
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.fail (label ^ " unavailable")

let script name =
  let cwd = Sys.getcwd () in
  find name
    [
      Filename.concat cwd ("tools/demo/" ^ name);
      Filename.concat cwd ("../tools/demo/" ^ name);
    ]

let binary name =
  let cwd = Sys.getcwd () in
  find name
    [
      Filename.concat cwd ("../bin/" ^ name);
      Filename.concat cwd ("../tools/" ^ name);
      Filename.concat cwd ("_build/default/bin/" ^ name);
      Filename.concat cwd ("_build/default/tools/" ^ name);
    ]

let environment entries =
  Unix.environment () |> Array.to_list
  |> List.filter (fun entry ->
      not
        (List.exists
           (fun (key, _) -> String.starts_with ~prefix:(key ^ "=") entry)
           entries))
  |> fun inherited ->
  Array.of_list
    (List.map (fun (key, value) -> key ^ "=" ^ value) entries @ inherited)

let run ~environment program arguments =
  let output = Filename.temp_file "yeokcham-demo-conflict-output-" "" in
  Fun.protect
    ~finally:(fun () -> remove_tree output)
    (fun () ->
      let descriptor =
        Unix.openfile output [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
      in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          Unix.create_process_env program
            (Array.of_list (program :: arguments))
            environment Unix.stdin descriptor descriptor
          |> Unix.waitpid [] |> snd))

let exited = function
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let read path = In_channel.with_open_bin path In_channel.input_all

let contains text needle =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec loop index =
    if index + needle_length > text_length then false
    else if String.sub text index needle_length = needle then true
    else loop (index + 1)
  in
  loop 0

let conflict_id output =
  let prefix = "conflict=" in
  require (String.starts_with ~prefix output) "conflict list is invalid";
  String.sub output (String.length prefix)
    (String.length output - String.length prefix)
  |> String.split_on_char ' ' |> List.hd

let persistent_conflict_is_local_and_explicit () =
  let parent = Filename.temp_file "yeokcham-demo-conflict-" "" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  let root = Filename.concat parent "fixture" in
  Fun.protect
    ~finally:(fun () -> remove_tree parent)
    (fun () ->
      let environment =
        environment
          [
            ("YEOKCHAM_BIN", binary "yeokcham.exe");
            ("YEOKCHAM_WORKSPACE_BASE_BIN", binary "workspace_base_v1.exe");
          ]
      in
      require
        (run ~environment "sh"
           [ script "create-repository-v1.sh"; "--root"; root ]
        |> exited)
        "fixture creation failed";
      require
        (run ~environment "sh"
           [ script "demonstrate-conflict-v1.sh"; "--root"; root ]
        |> exited)
        "conflict demo failed";
      Alcotest.(check string)
        "independent bytes survive partial materialisation"
        "independent bytes remain available\n"
        (read (Filename.concat root "conflict-unrelated.txt"));
      Alcotest.(check string)
        "first exact write survives skip" "first conflicting bytes\n"
        (read (Filename.concat root "docs/todo.txt"));
      let partial =
        read (Filename.concat root ".yeokcham/demo-v1-conflict-partial")
      in
      require
        (contains partial "partial=true")
        "initial application is not partial";
      let listed =
        read (Filename.concat root ".yeokcham/demo-v1-conflict-list")
      in
      let conflict = conflict_id listed in
      Alcotest.(check int) "conflict ID length" 64 (String.length conflict);
      let before =
        read (Filename.concat root ".yeokcham/demo-v1-conflict-show-before-skip")
      in
      require
        (contains before ("conflict=" ^ conflict ^ " kind=competing-edits"))
        "conflict kind is not structured";
      require
        (contains before "paths=docs/todo.txt candidates=skip-operation")
        "conflict candidates are not structured";
      Alcotest.(check string)
        "conflict remains immutable after skip" before
        (read (Filename.concat root ".yeokcham/demo-v1-conflict-show-after-skip"));
      Alcotest.(check string)
        "unsupported action leaves workspace unchanged"
        (read
           (Filename.concat root
              ".yeokcham/demo-v1-conflict-workspace-before-unsupported"))
        (read
           (Filename.concat root
              ".yeokcham/demo-v1-conflict-workspace-after-unsupported"));
      Alcotest.(check string)
        "resolved conflict is inactive" ""
        (read (Filename.concat root ".yeokcham/demo-v1-conflict-list-after-skip"));
      let complete =
        read (Filename.concat root ".yeokcham/demo-v1-conflict-complete")
      in
      require
        (contains complete "partial=false")
        "skip did not complete application")

let unowned_root_rejects () =
  let parent = Filename.temp_file "yeokcham-demo-conflict-unowned-" "" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  let root = Filename.concat parent "unowned" in
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree parent)
    (fun () ->
      require
        (not
           (run ~environment:(Unix.environment ()) "sh"
              [ script "demonstrate-conflict-v1.sh"; "--root"; root ]
           |> exited))
        "unowned root was accepted";
      require (Sys.readdir root |> Array.length = 0) "unowned root was modified")

let () =
  Alcotest.run "persistent localised conflict demonstration"
    [
      ( "conflict",
        [
          Alcotest.test_case "local continuation and explicit skip" `Quick
            persistent_conflict_is_local_and_explicit;
          Alcotest.test_case "unowned root rejects" `Quick unowned_root_rejects;
        ] );
    ]
