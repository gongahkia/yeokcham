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
  let output = Filename.temp_file "paengi-demo-release-output-" "" in
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

let release_identity output =
  let prefix = "release=" in
  require (String.starts_with ~prefix output) "release output is invalid";
  String.sub output (String.length prefix)
    (String.length output - String.length prefix)
  |> String.split_on_char ' ' |> List.hd

let immutable_release_retains_its_evidence_and_snapshot () =
  let parent = Filename.temp_file "paengi-demo-release-" "" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  let root = Filename.concat parent "fixture" in
  Fun.protect
    ~finally:(fun () -> remove_tree parent)
    (fun () ->
      let environment =
        environment
          [
            ("PAENGI_BIN", binary "paengi.exe");
            ("PAENGI_WORKSPACE_BASE_BIN", binary "workspace_base_v1.exe");
            ("PAENGI_RELEASE_EVIDENCE_BIN", binary "release_evidence_v1.exe");
          ]
      in
      require
        (run ~environment "sh"
           [ script "create-repository-v1.sh"; "--root"; root ]
        |> exited)
        "fixture creation failed";
      require
        (run ~environment "sh"
           [ script "demonstrate-release-v1.sh"; "--root"; root ]
        |> exited)
        "release demo failed";
      let creation =
        read (Filename.concat root ".paengi/demo-v1-release-create")
      in
      let release = release_identity creation in
      Alcotest.(check int) "release ID length" 64 (String.length release);
      require (contains creation "evidence=1") "release has no evidence";
      let materialise =
        read (Filename.concat root ".paengi/demo-v1-release-materialise")
      in
      require
        (contains materialise "partial=false")
        "release workspace is partial";
      Alcotest.(check string)
        "release show is immutable across scratch edits"
        (read
           (Filename.concat root ".paengi/demo-v1-release-show-before-change"))
        (read
           (Filename.concat root ".paengi/demo-v1-release-show-after-change"));
      Alcotest.(check string)
        "release verification is immutable across scratch edits"
        (read
           (Filename.concat root ".paengi/demo-v1-release-verify-before-change"))
        (read
           (Filename.concat root ".paengi/demo-v1-release-verify-after-change"));
      let evidence =
        read (Filename.concat root ".paengi/demo-v1-release-evidence")
      in
      let standalone =
        read (Filename.concat root ".paengi/demo-v1-release-validation")
      in
      require
        (contains evidence ("release=" ^ release ^ " evidence="))
        "release evidence link is missing";
      require
        (contains standalone "status=passed")
        "standalone validation failed";
      let before =
        read
          (Filename.concat root
             ".paengi/demo-v1-release-list-before-unsupported")
      in
      Alcotest.(check string)
        "missing parent leaves visible releases unchanged" before
        (read
           (Filename.concat root
              ".paengi/demo-v1-release-list-after-unsupported"));
      require
        (contains
           (read
              (Filename.concat root ".paengi/demo-v1-release-unsupported-parent"))
           "release parent graph is invalid")
        "missing parent error is not structured")

let unowned_root_rejects () =
  let parent = Filename.temp_file "paengi-demo-release-unowned-" "" in
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
              [ script "demonstrate-release-v1.sh"; "--root"; root ]
           |> exited))
        "unowned root was accepted";
      require (Sys.readdir root |> Array.length = 0) "unowned root was modified")

let () =
  Alcotest.run "immutable release demonstration"
    [
      ( "release",
        [
          Alcotest.test_case "identity, evidence, and verification" `Quick
            immutable_release_retains_its_evidence_and_snapshot;
          Alcotest.test_case "unowned root rejects" `Quick unowned_root_rejects;
        ] );
    ]
