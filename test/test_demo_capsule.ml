let require condition message = if not condition then Alcotest.fail message

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun n -> remove_tree (Filename.concat path n));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let find label candidates =
  match List.find_opt Sys.file_exists candidates with
  | Some p -> p
  | None -> Alcotest.fail (label ^ " unavailable")

let script name =
  let cwd = Sys.getcwd () in
  find name
    [
      Filename.concat cwd ("tools/demo/" ^ name);
      Filename.concat cwd ("../tools/demo/" ^ name);
    ]

let binary () =
  let cwd = Sys.getcwd () in
  find "paengi"
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
  let output = Filename.temp_file "paengi-demo-capsule-output-" "" in
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

let capsule_creation_and_fold_are_visible () =
  let parent = Filename.temp_file "paengi-demo-capsule-" "" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  let root = Filename.concat parent "fixture" in
  Fun.protect
    ~finally:(fun () -> remove_tree parent)
    (fun () ->
      let environment = environment "PAENGI_BIN" (binary ()) in
      require
        (run ~environment "sh"
           [ script "create-repository-v1.sh"; "--root"; root ]
        |> exited)
        "fixture creation failed";
      require
        (run ~environment "sh"
           [ script "demonstrate-capsule-v1.sh"; "--root"; root ]
        |> exited)
        "capsule demo failed";
      let history =
        read (Filename.concat root ".paengi/demo-v1-capsule-history")
        |> String.split_on_char '\n'
        |> List.filter (fun line -> line <> "")
      in
      Alcotest.(check int) "two immutable revisions" 2 (List.length history);
      Alcotest.(check bool)
        "revision identities differ" true
        (not (String.equal (List.hd history) (List.nth history 1)));
      Alcotest.(check string)
        "folded bytes" "folded capsule bytes\n"
        (read (Filename.concat root "debug-note.txt"));
      let show =
        read (Filename.concat root ".paengi/demo-v1-capsule-show-second")
      in
      require
        (String.starts_with
           ~prefix:
             "capsule \
              1111111111111111111111111111111111111111111111111111111111111111"
           show)
        "show does not identify the stable capsule";
      let split =
        read (Filename.concat root ".paengi/demo-v1-capsule-split-plan")
      in
      require (contains split "plan split") "split plan is absent";
      require
        (contains split "explicit confirmation is required")
        "split is not visibly unconfirmed")

let unowned_root_rejects () =
  let parent = Filename.temp_file "paengi-demo-capsule-unowned-" "" in
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
              [ script "demonstrate-capsule-v1.sh"; "--root"; root ]
           |> exited))
        "unowned root was accepted";
      require (Sys.readdir root |> Array.length = 0) "unowned root was modified")

let () =
  Alcotest.run "scratch-to-capsule demonstration"
    [
      ( "capsule",
        [
          Alcotest.test_case "stable ID, immutable revisions, and plan boundary"
            `Quick capsule_creation_and_fold_are_visible;
          Alcotest.test_case "unowned root rejects" `Quick unowned_root_rejects;
        ] );
    ]
