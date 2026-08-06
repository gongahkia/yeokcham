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
  let output = Filename.temp_file "yeokcham-demo-git-export-output-" "" in
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

let exported_release_is_fsck_clean_and_byte_exact () =
  let parent = Filename.temp_file "yeokcham-demo-git-export-" "" in
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
            ("YEOKCHAM_RELEASE_EVIDENCE_BIN", binary "release_evidence_v1.exe");
          ]
      in
      require
        (run ~environment "sh"
           [ script "create-repository-v1.sh"; "--root"; root ]
        |> exited)
        "fixture creation failed";
      require
        (run ~environment "sh"
           [ script "demonstrate-git-export-v1.sh"; "--root"; root ]
        |> exited)
        "Git export demo failed";
      let repository = Filename.concat root "git-export" in
      Alcotest.(check string)
        "todo bytes" "workspace first capsule bytes\n"
        (read (Filename.concat repository "docs/todo.txt"));
      Alcotest.(check string)
        "notes bytes" "workspace second capsule bytes\n"
        (read (Filename.concat repository "notes.txt"));
      require
        (Sys.file_exists (Filename.concat repository "CHANGELOG.md"))
        "renamed file is absent";
      require
        (not (Sys.file_exists (Filename.concat repository "README.md")))
        "old renamed path remains";
      require
        (not (Sys.file_exists (Filename.concat repository "release-after.txt")))
        "later scratch bytes were exported";
      require
        ((Unix.stat (Filename.concat repository "bin/run-demo")).Unix.st_perm
         land 0o111
        = 0)
        "nonexecutable mode changed";
      Alcotest.(check string)
        "symlink target" "docs/todo.txt"
        (Unix.readlink (Filename.concat repository "current-note"));
      Alcotest.(check string)
        "no remote configured" ""
        (read (Filename.concat root ".yeokcham/demo-v1-git-export-remotes"));
      let exported =
        read (Filename.concat root ".yeokcham/demo-v1-git-export")
      in
      require (contains exported "metadata=default") "export policy is unclear";
      require
        (contains
           (read
              (Filename.concat root
                 ".yeokcham/demo-v1-git-export-invalid-repository"))
           "Git repository")
        "invalid repository error is not structured")

let unowned_root_rejects () =
  let parent = Filename.temp_file "yeokcham-demo-git-export-unowned-" "" in
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
              [ script "demonstrate-git-export-v1.sh"; "--root"; root ]
           |> exited))
        "unowned root was accepted";
      require (Sys.readdir root |> Array.length = 0) "unowned root was modified")

let () =
  Alcotest.run "Git export demonstration"
    [
      ( "export",
        [
          Alcotest.test_case "fsck and byte oracle" `Quick
            exported_release_is_fsck_clean_and_byte_exact;
          Alcotest.test_case "unowned root rejects" `Quick unowned_root_rejects;
        ] );
    ]
