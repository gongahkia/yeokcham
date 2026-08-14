module Git = Yeokcham_git
module Capsule_store = Yeokcham_capsule_store
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Id = Yeokcham_id
module Release = Yeokcham_release
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Validation = Yeokcham_validation
module Workspace_store = Yeokcham_workspace_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let contains ~needle value =
  let needle_length = String.length needle in
  let value_length = String.length value in
  let rec loop index =
    if index + needle_length > value_length then false
    else if String.sub value index needle_length = needle then true
    else loop (index + 1)
  in
  loop 0

let refreshed_golden name actual =
  Golden.refresh_lower_hex_file (Filename.concat "golden" name) actual
  |> require_ok Fun.id

let golden_bytes name =
  match Sys.getenv_opt "YEOKCHAM_GOLDEN_ROOT" with
  | Some root ->
      Golden.read_lower_hex_file
        (Filename.concat (Filename.concat root "test/golden") name)
      |> require_ok Fun.id
  | None ->
      Golden.refresh_lower_hex_file (Filename.concat "golden" name) ""
      |> require_ok Fun.id

let stream ?(limit = max_int) value =
  {
    Validation.digest = String.make 32 '\000';
    retained = String.sub value 0 (min limit (String.length value));
    truncated = String.length value > limit;
  }

let process_result ?(status = Validation.Passed) ?(exit_code = Some 0)
    ?(signal = None) ?(message = None) ?(stdout = stream "")
    ?(stderr = stream "") () =
  {
    Validation.runner_status = status;
    runner_exit_code = exit_code;
    runner_signal = signal;
    runner_execution_error = message;
    runner_duration_ms = 0L;
    runner_stdout = stdout;
    runner_stderr = stderr;
    runner_environment_fingerprint = None;
  }

let queued_results = ref []
let recorded_commands = ref []

module Fake_runner : Validation.Process_runner = struct
  let run command ~working_directory:_ =
    recorded_commands := command :: !recorded_commands;
    match !queued_results with
    | next :: rest ->
        queued_results := rest;
        next
    | [] -> failwith "missing fake Git process result"
end

let fake_configuration =
  Git.configuration_with ~git:"/usr/bin/true" Git.default_configuration

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
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> run path)

let direct_process executable arguments =
  let argv = Array.of_list (executable :: arguments) in
  let child =
    Unix.create_process executable argv Unix.stdin Unix.stdout Unix.stderr
  in
  match Unix.waitpid [] child with
  | _, Unix.WEXITED 0 -> ()
  | _, Unix.WEXITED code ->
      Alcotest.fail (Printf.sprintf "Git fixture command exited %d" code)
  | _, Unix.WSIGNALED signal | _, Unix.WSTOPPED signal ->
      Alcotest.fail (Printf.sprintf "Git fixture command received %d" signal)

let direct_process_with_environment executable environment arguments =
  let argv = Array.of_list (executable :: arguments) in
  let child =
    Unix.create_process_env executable argv environment Unix.stdin Unix.stdout
      Unix.stderr
  in
  match Unix.waitpid [] child with
  | _, Unix.WEXITED 0 -> ()
  | _, Unix.WEXITED code ->
      Alcotest.fail (Printf.sprintf "Git fixture command exited %d" code)
  | _, Unix.WSIGNALED signal | _, Unix.WSTOPPED signal ->
      Alcotest.fail (Printf.sprintf "Git fixture command received %d" signal)

let direct_capture executable arguments =
  let argv = Array.of_list (executable :: arguments) in
  let channel = Unix.open_process_args_in executable argv in
  let output = In_channel.input_all channel in
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 -> String.trim output
  | Unix.WEXITED code ->
      Alcotest.fail (Printf.sprintf "Git fixture command exited %d" code)
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
      Alcotest.fail (Printf.sprintf "Git fixture command received %d" signal)

let direct_capture_with_environment executable environment arguments =
  let reader, writer = Unix.pipe () in
  let child =
    Unix.create_process_env executable
      (Array.of_list (executable :: arguments))
      environment Unix.stdin writer Unix.stderr
  in
  Unix.close writer;
  let channel = Unix.in_channel_of_descr reader in
  let output = In_channel.input_all channel in
  In_channel.close channel;
  match Unix.waitpid [] child with
  | _, Unix.WEXITED 0 -> String.trim output
  | _, Unix.WEXITED code ->
      Alcotest.fail (Printf.sprintf "Git fixture command exited %d" code)
  | _, Unix.WSIGNALED signal | _, Unix.WSTOPPED signal ->
      Alcotest.fail (Printf.sprintf "Git fixture command received %d" signal)

let commit_environment ~author_name ~author_email ~author_date ~committer_name
    ~committer_email ~committer_date =
  let overridden =
    [
      "GIT_AUTHOR_NAME=";
      "GIT_AUTHOR_EMAIL=";
      "GIT_AUTHOR_DATE=";
      "GIT_COMMITTER_NAME=";
      "GIT_COMMITTER_EMAIL=";
      "GIT_COMMITTER_DATE=";
    ]
  in
  Unix.environment () |> Array.to_list
  |> List.filter (fun value ->
      not
        (List.exists
           (fun prefix -> String.starts_with ~prefix value)
           overridden))
  |> List.rev_append
       [
         "GIT_AUTHOR_NAME=" ^ author_name;
         "GIT_AUTHOR_EMAIL=" ^ author_email;
         "GIT_AUTHOR_DATE=" ^ author_date;
         "GIT_COMMITTER_NAME=" ^ committer_name;
         "GIT_COMMITTER_EMAIL=" ^ committer_email;
         "GIT_COMMITTER_DATE=" ^ committer_date;
       ]
  |> Array.of_list

let golden_commit_environment =
  commit_environment ~author_name:"Yeokcham Golden"
    ~author_email:"golden@example.invalid" ~author_date:"1700000000 +0000"
    ~committer_name:"Yeokcham Golden" ~committer_email:"golden@example.invalid"
    ~committer_date:"1700000000 +0000"

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let assert_snapshot_matches_directory ?(ignore_git_directory = false) store
    snapshot root =
  let display_path components =
    match components with [] -> "." | _ -> String.concat "/" components
  in
  let lstat components path expected =
    try Unix.lstat path
    with Unix.Unix_error (error, _, _) ->
      Alcotest.fail
        (Printf.sprintf "%s missing at %s: %s" expected
           (display_path components) (Unix.error_message error))
  in
  let rec check_tree components tree_id =
    let tree =
      Snapshot.Tree.load store tree_id |> require_ok Snapshot.error_to_string
    in
    let path = List.fold_left Filename.concat root components in
    let expected_entries = Snapshot.Tree.entries tree in
    let expected_names = List.map fst expected_entries in
    let actual_names =
      Sys.readdir path |> Array.to_list
      |> List.filter (fun name ->
          not
            (ignore_git_directory && components = [] && String.equal name ".git"))
      |> List.sort String.compare
    in
    Alcotest.(check (list string))
      ("entries at " ^ display_path components)
      expected_names actual_names;
    List.iter
      (fun (name, entry) ->
        let components = components @ [ name ] in
        let path = Filename.concat path name in
        match entry with
        | Snapshot.Tree.Directory child ->
            let status = lstat components path "expected directory" in
            Alcotest.(check bool)
              ("directory kind at " ^ display_path components)
              true
              (status.Unix.st_kind = Unix.S_DIR);
            check_tree components child
        | Snapshot.Tree.File { mode; content } -> (
            let expected =
              Snapshot.Content.load store content
              |> require_ok Snapshot.error_to_string
            in
            let status =
              lstat components path
                (match mode with
                | Snapshot.Symlink -> "expected symlink"
                | Snapshot.Regular | Snapshot.Executable -> "expected file")
            in
            match mode with
            | Snapshot.Symlink ->
                Alcotest.(check bool)
                  ("symlink kind at " ^ display_path components)
                  true
                  (status.Unix.st_kind = Unix.S_LNK);
                Alcotest.(check string)
                  ("symlink target at " ^ display_path components)
                  expected (Unix.readlink path)
            | Snapshot.Regular | Snapshot.Executable ->
                Alcotest.(check bool)
                  ("file kind at " ^ display_path components)
                  true
                  (status.Unix.st_kind = Unix.S_REG);
                Alcotest.(check string)
                  ("file bytes at " ^ display_path components)
                  expected (read_file path);
                Alcotest.(check bool)
                  ("executable mode at " ^ display_path components)
                  (mode = Snapshot.Executable)
                  (status.Unix.st_perm land 0o111 <> 0)))
      expected_entries
  in
  check_tree [] (Snapshot.Snapshot.root snapshot)

let mapping_envelope_bytes store mapping =
  let components = [ "git-mappings"; Id.Git_mapping_id.to_hex mapping ] in
  let binding =
    Store.Ref_file.read store ~components |> require_ok Store.error_to_string
  in
  match binding with
  | None -> Alcotest.fail "Git mapping binding was not written"
  | Some binding -> (
      match Encoding.decode binding with
      | Error _ -> Alcotest.fail "Git mapping binding does not decode"
      | Ok value -> (
          match value with
          | Encoding.Array [ _; _; Encoding.Bytes physical; _ ] -> (
              match Store.Stored_object_id.of_raw_bytes physical with
              | Some physical ->
                  Store.get store physical
                  |> require_ok Store.error_to_string
                  |> Envelope.encode
              | None -> Alcotest.fail "Git mapping binding object ID is invalid"
              )
          | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
          | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _ | Encoding.Null
            ->
              Alcotest.fail "Git mapping binding does not decode"))

let binding_bytes store components =
  Store.Ref_file.read store ~components |> require_ok Store.error_to_string
  |> function
  | Some bytes -> bytes
  | None -> Alcotest.fail "expected immutable binding was not written"

let imported_transition_envelope_bytes store transition =
  let components =
    [ "imported-transitions"; Id.Imported_transition_id.to_hex transition ]
  in
  let binding = binding_bytes store components in
  match Encoding.decode binding with
  | Error _ -> Alcotest.fail "imported transition binding does not decode"
  | Ok (Encoding.Array [ _; _; Encoding.Bytes physical; _ ]) -> (
      match Store.Stored_object_id.of_raw_bytes physical with
      | Some physical ->
          Store.get store physical
          |> require_ok Store.error_to_string
          |> Envelope.encode
      | None -> Alcotest.fail "imported transition binding object ID is invalid"
      )
  | Ok
      ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
      | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ) ->
      Alcotest.fail "imported transition binding does not decode"

let imported_tag_envelope_bytes store tag =
  let components = [ "imported-tags"; Id.Imported_tag_id.to_hex tag ] in
  let binding = binding_bytes store components in
  match Encoding.decode binding with
  | Error _ -> Alcotest.fail "imported tag binding does not decode"
  | Ok (Encoding.Array [ _; _; Encoding.Bytes physical; _ ]) -> (
      match Store.Stored_object_id.of_raw_bytes physical with
      | Some physical ->
          Store.get store physical
          |> require_ok Store.error_to_string
          |> Envelope.encode
      | None -> Alcotest.fail "imported tag binding object ID is invalid")
  | Ok
      ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
      | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ) ->
      Alcotest.fail "imported tag binding does not decode"

let git_path () =
  let candidates =
    [ "/opt/homebrew/bin/git"; "/usr/local/bin/git"; "/usr/bin/git" ]
  in
  match
    List.find_opt
      (fun candidate ->
        try
          Unix.access candidate [ Unix.X_OK ];
          true
        with Unix.Unix_error _ -> false)
      candidates
  with
  | Some path -> path
  | None -> Alcotest.fail "Git executable is unavailable for local fixture"

let preflight_uses_bounded_direct_argv () =
  with_directory "yeokcham-git-fake-" (fun repository ->
      recorded_commands := [];
      queued_results :=
        [
          process_result ~stdout:(stream "false\n") ();
          process_result ~stdout:(stream "sha256\n") ();
        ];
      let inspection =
        Git.inspect ~runner:(module Fake_runner) fake_configuration ~repository
        |> require_ok Git.error_to_string
      in
      Alcotest.(check bool) "bare result" false (Git.inspection_bare inspection);
      Alcotest.(check string)
        "object format" "sha256"
        (Git.inspection_object_format inspection |> Git.object_format_to_string);
      let commands = List.rev !recorded_commands in
      Alcotest.(check int) "two direct Git commands" 2 (List.length commands);
      List.iter2
        (fun command expected ->
          Alcotest.(check string)
            "absolute executable" "/usr/bin/true" command.Validation.executable;
          Alcotest.(check (list string))
            "direct argv" expected command.Validation.arguments;
          Alcotest.(check bool)
            "empty environment" true
            (match command.Validation.environment_policy with
            | Validation.Empty -> true
            | Validation.Inherit -> false);
          Alcotest.(check (list (pair string string)))
            "no environment" [] command.Validation.environment)
        commands
        [
          [ "-C"; repository; "rev-parse"; "--is-bare-repository" ];
          [ "-C"; repository; "rev-parse"; "--show-object-format" ];
        ])

let rejects_untrusted_path_before_execution () =
  recorded_commands := [];
  queued_results := [];
  Git.inspect
    ~runner:(module Fake_runner)
    fake_configuration ~repository:"relative"
  |> Result.fold
       ~ok:(fun _ -> Alcotest.fail "relative path was accepted")
       ~error:(fun error ->
         Alcotest.(check bool)
           "structured invalid path" true
           (contains ~needle:"invalid Git repository path"
              (Git.error_to_string error)));
  Alcotest.(check int)
    "invalid path starts no process" 0
    (List.length !recorded_commands)

let malformed_or_truncated_output_rejects () =
  with_directory "yeokcham-git-output-" (fun repository ->
      recorded_commands := [];
      queued_results := [ process_result ~stdout:(stream "false\ntrue\n") () ];
      Git.inspect ~runner:(module Fake_runner) fake_configuration ~repository
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "multiple output lines were accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured malformed output" true
               (contains ~needle:"returned malformed output"
                  (Git.error_to_string error)));
      recorded_commands := [];
      queued_results :=
        [ process_result ~stdout:(stream ~limit:3 "false\n") () ];
      Git.inspect ~runner:(module Fake_runner) fake_configuration ~repository
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "truncated output was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured output limit" true
               (contains ~needle:"stdout exceeded" (Git.error_to_string error))))

let actual_git_repository_is_inspected () =
  with_directory "yeokcham-git-fixture-" (fun repository ->
      direct_process (git_path ()) [ "init"; "-q"; repository ];
      let inspection =
        Git.inspect Git.default_configuration ~repository
        |> require_ok Git.error_to_string
      in
      Alcotest.(check bool)
        "working repository is not bare" false
        (Git.inspection_bare inspection);
      Alcotest.(check bool)
        "Git object format is supported" true
        (let format =
           Git.inspection_object_format inspection
           |> Git.object_format_to_string
         in
         String.equal format "sha1" || String.equal format "sha256"))

let import_fixture run =
  with_directory "yeokcham-git-import-" (fun root ->
      let repository = Filename.concat root "repository" in
      let store_root = Filename.concat root "store" in
      Unix.mkdir repository 0o700;
      Unix.mkdir store_root 0o700;
      let git = git_path () in
      direct_process git [ "init"; "-q"; repository ];
      write_file (Filename.concat repository "regular") "regular\000bytes";
      write_file (Filename.concat repository "run") "#!/bin/sh\nprintf run\n";
      Unix.chmod (Filename.concat repository "run") 0o755;
      Unix.mkdir (Filename.concat repository "nested") 0o700;
      write_file (Filename.concat repository "nested/data") "nested\n";
      Unix.symlink "regular" (Filename.concat repository "link");
      direct_process git [ "-C"; repository; "add"; "--all" ];
      let tree = direct_capture git [ "-C"; repository; "write-tree" ] in
      let store =
        Store.init ~root:store_root |> require_ok Store.error_to_string
      in
      let format =
        Git.inspect Git.default_configuration ~repository
        |> require_ok Git.error_to_string
        |> Git.inspection_object_format
      in
      let tree =
        Git.object_id_of_hex format tree |> require_ok Git.error_to_string
      in
      run repository store tree)

let commit_fixture run =
  with_directory "yeokcham-git-commit-" (fun root ->
      let repository = Filename.concat root "repository" in
      let store_root = Filename.concat root "store" in
      Unix.mkdir repository 0o700;
      Unix.mkdir store_root 0o700;
      let git = git_path () in
      direct_process git [ "init"; "-q"; repository ];
      direct_process git
        [ "-C"; repository; "config"; "user.name"; "Yeokcham Test" ];
      direct_process git
        [ "-C"; repository; "config"; "user.email"; "test@example.invalid" ];
      write_file (Filename.concat repository "base") "base\n";
      write_file (Filename.concat repository "run") "#!/bin/sh\nprintf base\n";
      Unix.chmod (Filename.concat repository "run") 0o755;
      Unix.mkdir (Filename.concat repository "nested") 0o700;
      write_file (Filename.concat repository "nested/data") "nested\n";
      Unix.symlink "base" (Filename.concat repository "link");
      direct_process git [ "-C"; repository; "add"; "--all" ];
      direct_process git [ "-C"; repository; "commit"; "-q"; "-m"; "base" ];
      let base = direct_capture git [ "-C"; repository; "rev-parse"; "HEAD" ] in
      let branch =
        direct_capture git [ "-C"; repository; "branch"; "--show-current" ]
      in
      direct_process git
        [ "-C"; repository; "checkout"; "-q"; "-b"; "side"; base ];
      write_file (Filename.concat repository "side") "side\n";
      direct_process git [ "-C"; repository; "add"; "--all" ];
      direct_process git [ "-C"; repository; "commit"; "-q"; "-m"; "side" ];
      let side = direct_capture git [ "-C"; repository; "rev-parse"; "HEAD" ] in
      direct_process git [ "-C"; repository; "checkout"; "-q"; branch ];
      write_file (Filename.concat repository "main") "main\n";
      direct_process git [ "-C"; repository; "add"; "--all" ];
      direct_process git [ "-C"; repository; "commit"; "-q"; "-m"; "main" ];
      let main = direct_capture git [ "-C"; repository; "rev-parse"; "HEAD" ] in
      direct_process git
        [ "-C"; repository; "merge"; "--no-ff"; "-q"; "-m"; "merge"; "side" ];
      let merge =
        direct_capture git [ "-C"; repository; "rev-parse"; "HEAD" ]
      in
      let parents =
        direct_capture git
          [ "-C"; repository; "show"; "-s"; "--format=%P"; merge ]
        |> String.split_on_char ' '
      in
      Alcotest.(check (list string))
        "merge parent order fixture" [ main; side ] parents;
      let store =
        Store.init ~root:store_root |> require_ok Store.error_to_string
      in
      let format =
        Git.inspect Git.default_configuration ~repository
        |> require_ok Git.error_to_string
        |> Git.inspection_object_format
      in
      let commit =
        Git.object_id_of_hex format merge |> require_ok Git.error_to_string
      in
      run repository store format commit parents)

let tag_fixture run =
  with_directory "yeokcham-git-tag-" (fun root ->
      let repository = Filename.concat root "repository" in
      let store_root = Filename.concat root "store" in
      Unix.mkdir repository 0o700;
      Unix.mkdir store_root 0o700;
      let git = git_path () in
      direct_process git [ "init"; "-q"; repository ];
      direct_process git
        [ "-C"; repository; "config"; "user.name"; "Yeokcham Test" ];
      direct_process git
        [ "-C"; repository; "config"; "user.email"; "test@example.invalid" ];
      write_file (Filename.concat repository "tagged") "tagged\000bytes";
      direct_process git [ "-C"; repository; "add"; "--all" ];
      direct_process git [ "-C"; repository; "commit"; "-q"; "-m"; "tagged" ];
      let commit =
        direct_capture git [ "-C"; repository; "rev-parse"; "HEAD" ]
      in
      direct_process git [ "-C"; repository; "tag"; "lightweight"; commit ];
      direct_process git
        [
          "-C";
          repository;
          "tag";
          "-a";
          "annotated";
          "-m";
          "exact annotation\nwith second line";
          commit;
        ];
      let annotated_object =
        direct_capture git
          [ "-C"; repository; "rev-parse"; "refs/tags/annotated" ]
      in
      let annotation_bytes =
        direct_capture git
          [ "-C"; repository; "cat-file"; "tag"; annotated_object ]
        ^ "\n"
      in
      let store =
        Store.init ~root:store_root |> require_ok Store.error_to_string
      in
      let format =
        Git.inspect Git.default_configuration ~repository
        |> require_ok Git.error_to_string
        |> Git.inspection_object_format
      in
      let commit =
        Git.object_id_of_hex format commit |> require_ok Git.error_to_string
      in
      run repository store commit annotation_bytes)

let imports_merge_commit_and_ordered_parents () =
  commit_fixture (fun repository store _format commit expected_parents ->
      let imported =
        Git.import_commit Git.default_configuration ~store ~repository ~commit
        |> require_ok Git.error_to_string
      in
      let repeated =
        Git.import_commit Git.default_configuration ~store ~repository ~commit
        |> require_ok Git.error_to_string
      in
      Alcotest.(check bool)
        "equal retry has one transition ID" true
        (Id.Imported_transition_id.equal
           (Git.imported_transition_id imported.Git.imported_transition)
           (Git.imported_transition_id repeated.Git.imported_transition));
      Alcotest.(check bool)
        "equal retry has one mapping ID" true
        (Id.Git_mapping_id.equal
           (Git.mapping_id imported.Git.commit_mapping)
           (Git.mapping_id repeated.Git.commit_mapping));
      let reopened =
        Store.open_repository ~root:(Store.root store)
        |> require_ok Store.error_to_string
      in
      let transition =
        Git.load_imported_transition reopened
          (Git.imported_transition_id imported.Git.imported_transition)
        |> require_ok Git.error_to_string
      in
      Alcotest.(check string)
        "commit identity"
        (Git.object_id_to_hex commit)
        (Git.imported_transition_commit transition |> Git.object_id_to_hex);
      Alcotest.(check (list string))
        "parent order" expected_parents
        (Git.imported_transition_parents transition
        |> List.map Git.object_id_to_hex);
      let mapping =
        Git.load_mapping reopened (Git.mapping_id imported.Git.commit_mapping)
        |> require_ok Git.error_to_string
      in
      (match Git.mapping_subject mapping with
      | Git.Imported_transition { transition = identity; _ } ->
          Alcotest.(check bool)
            "mapping names transition" true
            (Id.Imported_transition_id.equal identity
               (Git.imported_transition_id transition))
      | Git.Imported_snapshot _ | Git.Imported_tag _ | Git.Imported_revision _
      | Git.Exported_release _ | Git.Exported_revision _ ->
          Alcotest.fail "commit import did not map to an opaque transition");
      let snapshot =
        Snapshot.Snapshot.load reopened
          (Git.imported_transition_snapshot transition)
        |> require_ok Snapshot.error_to_string
      in
      with_directory "yeokcham-git-commit-materialized-" (fun destination ->
          Snapshot.Materialize.write ~destination reopened snapshot
          |> require_ok Snapshot.Materialize.error_to_string;
          assert_snapshot_matches_directory reopened snapshot destination;
          Alcotest.(check string)
            "base bytes" "base\n"
            (read_file (Filename.concat destination "base"));
          Alcotest.(check string)
            "main bytes" "main\n"
            (read_file (Filename.concat destination "main"));
          Alcotest.(check string)
            "side bytes" "side\n"
            (read_file (Filename.concat destination "side"))))

let imports_complete_existing_repository () =
  commit_fixture (fun repository store format commit expected_parents ->
      let git = git_path () in
      let commit_hex = Git.object_id_to_hex commit in
      direct_process git [ "-C"; repository; "tag"; "lightweight"; commit_hex ];
      direct_process git
        [
          "-C";
          repository;
          "tag";
          "-a";
          "annotated";
          "-m";
          "complete import annotation";
          commit_hex;
        ];
      let tree =
        direct_capture git
          [ "-C"; repository; "show"; "-s"; "--format=%T"; commit_hex ]
        |> Git.object_id_of_hex format
        |> require_ok Git.error_to_string
      in
      let imported_tree =
        Git.import_tree Git.default_configuration ~store ~repository ~tree
        |> require_ok Git.error_to_string
      in
      let imported_commit =
        Git.import_commit Git.default_configuration ~store ~repository ~commit
        |> require_ok Git.error_to_string
      in
      let repeated_commit =
        Git.import_commit Git.default_configuration ~store ~repository ~commit
        |> require_ok Git.error_to_string
      in
      let lightweight =
        Git.import_tag Git.default_configuration ~store ~repository
          ~tag:"lightweight"
        |> require_ok Git.error_to_string
      in
      let annotated =
        Git.import_tag Git.default_configuration ~store ~repository
          ~tag:"annotated"
        |> require_ok Git.error_to_string
      in
      let transition = imported_commit.Git.imported_transition in
      Alcotest.(check bool)
        "commit and tree import share snapshot" true
        (Snapshot.Snapshot.equal_id imported_tree.Git.snapshot
           (Git.imported_transition_snapshot transition));
      Alcotest.(check (list string))
        "complete import preserves ordered parents" expected_parents
        (Git.imported_transition_parents transition
        |> List.map Git.object_id_to_hex);
      Alcotest.(check bool)
        "complete import retains author provenance" true
        (Option.is_some (Git.imported_transition_author transition));
      Alcotest.(check bool)
        "complete import retains committer provenance" true
        (Option.is_some (Git.imported_transition_committer transition));
      Alcotest.(check bool)
        "complete import retry is stable" true
        (Id.Imported_transition_id.equal
           (Git.imported_transition_id transition)
           (Git.imported_transition_id repeated_commit.Git.imported_transition));
      let expect_mapping label mapping predicate =
        Git.load_mapping store (Git.mapping_id mapping)
        |> require_ok Git.error_to_string
        |> Git.mapping_subject |> predicate
        |> Alcotest.(check bool) label true
      in
      expect_mapping "tree mapping names snapshot" imported_tree.Git.mapping
        (function
        | Git.Imported_snapshot snapshot ->
            Snapshot.Snapshot.equal_id snapshot imported_tree.Git.snapshot
        | Git.Imported_transition _ | Git.Imported_tag _
        | Git.Imported_revision _ | Git.Exported_release _
        | Git.Exported_revision _ ->
            false);
      expect_mapping "commit mapping names opaque transition"
        imported_commit.Git.commit_mapping (function
        | Git.Imported_transition { transition = identity; _ } ->
            Id.Imported_transition_id.equal identity
              (Git.imported_transition_id transition)
        | Git.Imported_snapshot _ | Git.Imported_tag _ | Git.Imported_revision _
        | Git.Exported_release _ | Git.Exported_revision _ ->
            false);
      expect_mapping "lightweight tag mapping names opaque tag"
        lightweight.Git.tag_mapping (function
        | Git.Imported_tag { tag; _ } ->
            Id.Imported_tag_id.equal tag
              (Git.imported_tag_id lightweight.Git.imported_tag)
        | Git.Imported_snapshot _ | Git.Imported_transition _
        | Git.Imported_revision _ | Git.Exported_release _
        | Git.Exported_revision _ ->
            false);
      expect_mapping "annotated tag mapping names opaque tag"
        annotated.Git.tag_mapping (function
        | Git.Imported_tag { tag; _ } ->
            Id.Imported_tag_id.equal tag
              (Git.imported_tag_id annotated.Git.imported_tag)
        | Git.Imported_snapshot _ | Git.Imported_transition _
        | Git.Imported_revision _ | Git.Exported_release _
        | Git.Exported_revision _ ->
            false);
      let reopened =
        Store.open_repository ~root:(Store.root store)
        |> require_ok Store.error_to_string
      in
      let reopened_transition =
        Git.load_imported_transition reopened
          (Git.imported_transition_id transition)
        |> require_ok Git.error_to_string
      in
      Alcotest.(check string)
        "reopened transition names source commit" commit_hex
        (Git.imported_transition_commit reopened_transition
        |> Git.object_id_to_hex);
      let reopened_annotated =
        Git.load_imported_tag reopened
          (Git.imported_tag_id annotated.Git.imported_tag)
        |> require_ok Git.error_to_string
      in
      Alcotest.(check string)
        "reopened annotated tag names source commit" commit_hex
        (Git.imported_tag_target reopened_annotated |> Git.object_id_to_hex);
      let annotation =
        match Git.imported_tag_annotation reopened_annotated with
        | Some annotation -> annotation
        | None -> Alcotest.fail "annotated tag lost opaque bytes"
      in
      Alcotest.(check bool)
        "annotated tag retains raw provenance" true
        (contains ~needle:"complete import annotation"
           (Snapshot.Content.load reopened annotation
           |> require_ok Snapshot.error_to_string));
      write_file (Filename.concat repository "base") "changed\n";
      Unix.chmod (Filename.concat repository "run") 0o644;
      Unix.unlink (Filename.concat repository "link");
      Unix.symlink "nested/data" (Filename.concat repository "link");
      let snapshot =
        Snapshot.Snapshot.load reopened
          (Git.imported_transition_snapshot reopened_transition)
        |> require_ok Snapshot.error_to_string
      in
      with_directory "yeokcham-git-complete-import-materialized-"
        (fun destination ->
          Snapshot.Materialize.write ~destination reopened snapshot
          |> require_ok Snapshot.Materialize.error_to_string;
          assert_snapshot_matches_directory reopened snapshot destination;
          Alcotest.(check string)
            "complete import regular bytes" "base\n"
            (read_file (Filename.concat destination "base"));
          Alcotest.(check string)
            "complete import nested bytes" "nested\n"
            (read_file (Filename.concat destination "nested/data"));
          Alcotest.(check bool)
            "complete import executable mode" true
            ((Unix.stat (Filename.concat destination "run")).Unix.st_perm
             land 0o111
            <> 0);
          Alcotest.(check string)
            "complete import symlink target" "base"
            (Unix.readlink (Filename.concat destination "link"));
          Alcotest.(check string)
            "complete import main branch bytes" "main\n"
            (read_file (Filename.concat destination "main"));
          Alcotest.(check string)
            "complete import side branch bytes" "side\n"
            (read_file (Filename.concat destination "side"))))

let imports_commit_metadata_as_exact_bytes () =
  with_directory "yeokcham-git-commit-metadata-" (fun root ->
      let repository = Filename.concat root "repository" in
      let store_root = Filename.concat root "store" in
      Unix.mkdir repository 0o700;
      Unix.mkdir store_root 0o700;
      let git = git_path () in
      direct_process git [ "init"; "--object-format=sha1"; "-q"; repository ];
      write_file (Filename.concat repository "metadata") "same snapshot\n";
      direct_process git [ "-C"; repository; "add"; "--all" ];
      let tree = direct_capture git [ "-C"; repository; "write-tree" ] in
      let author = "Alice Metadata <alice@example.invalid> 1700000000 +0530" in
      let committer = "Bob Metadata <bob@example.invalid> 1700000123 -0700" in
      let message = "subject\n\nmultiline body\nsecond line\n" in
      let commit =
        direct_capture_with_environment git
          (commit_environment ~author_name:"Alice Metadata"
             ~author_email:"alice@example.invalid"
             ~author_date:"1700000000 +0530" ~committer_name:"Bob Metadata"
             ~committer_email:"bob@example.invalid"
             ~committer_date:"1700000123 -0700")
          [
            "-C";
            repository;
            "commit-tree";
            tree;
            "-m";
            "subject\n\nmultiline body\nsecond line";
          ]
      in
      let raw_commit =
        "tree " ^ tree ^ "\n"
        ^ "author Raw Bytes <raw@example.invalid> 1700000456 +1245\n"
        ^ "committer Raw Bytes <raw@example.invalid> 1700000789 -0330\n"
        ^ "encoding ISO-8859-1\n\n\255raw-message\n"
      in
      let raw_path = Filename.concat root "raw-commit" in
      write_file raw_path raw_commit;
      let invalid_utf8_commit =
        direct_capture git
          [ "-C"; repository; "hash-object"; "-t"; "commit"; "-w"; raw_path ]
      in
      let empty_raw =
        "tree " ^ tree ^ "\n"
        ^ "author Empty <empty@example.invalid> 1700000000 +0000\n"
        ^ "committer Empty <empty@example.invalid> 1700000000 +0000\n\n"
      in
      let empty_path = Filename.concat root "empty-commit" in
      write_file empty_path empty_raw;
      let empty_commit =
        direct_capture git
          [ "-C"; repository; "hash-object"; "-t"; "commit"; "-w"; empty_path ]
      in
      let store =
        Store.init ~root:store_root |> require_ok Store.error_to_string
      in
      let import hex =
        let identity =
          Git.object_id_of_hex Git.Sha1 hex |> require_ok Git.error_to_string
        in
        Git.import_commit Git.default_configuration ~store ~repository
          ~commit:identity
        |> require_ok Git.error_to_string
      in
      let imported = import commit in
      let repeated = import commit in
      let invalid_utf8 = import invalid_utf8_commit in
      let empty = import empty_commit in
      let transition = imported.Git.imported_transition in
      Alcotest.(check (option string))
        "author bytes retain source timezone" (Some author)
        (Git.imported_transition_author transition);
      Alcotest.(check (option string))
        "committer bytes retain source timezone" (Some committer)
        (Git.imported_transition_committer transition);
      let message_id =
        match Git.imported_transition_message transition with
        | Some message -> message
        | None -> Alcotest.fail "metadata message is absent"
      in
      Alcotest.(check string)
        "multiline message bytes" message
        (Snapshot.Content.load store message_id
        |> require_ok Snapshot.error_to_string);
      Alcotest.(check bool)
        "retry transition identity" true
        (Id.Imported_transition_id.equal
           (Git.imported_transition_id transition)
           (Git.imported_transition_id repeated.Git.imported_transition));
      Alcotest.(check bool)
        "same tree has one snapshot identity" true
        (Store.Stored_object_id.equal
           (Snapshot.Snapshot.stored_object_id
              (Git.imported_transition_snapshot transition))
           (Snapshot.Snapshot.stored_object_id
              (Git.imported_transition_snapshot
                 invalid_utf8.Git.imported_transition)));
      Alcotest.(check bool)
        "metadata changes transition identity" false
        (Id.Imported_transition_id.equal
           (Git.imported_transition_id transition)
           (Git.imported_transition_id invalid_utf8.Git.imported_transition));
      let invalid_message =
        match
          Git.imported_transition_message invalid_utf8.Git.imported_transition
        with
        | Some message -> message
        | None -> Alcotest.fail "invalid UTF-8 message is absent"
      in
      Alcotest.(check string)
        "invalid UTF-8 message bytes" "\255raw-message\n"
        (Snapshot.Content.load store invalid_message
        |> require_ok Snapshot.error_to_string);
      let empty_message =
        match Git.imported_transition_message empty.Git.imported_transition with
        | Some message -> message
        | None -> Alcotest.fail "empty message is absent"
      in
      Alcotest.(check string)
        "empty message bytes" ""
        (Snapshot.Content.load store empty_message
        |> require_ok Snapshot.error_to_string);
      let reopened =
        Store.open_repository ~root:store_root
        |> require_ok Store.error_to_string
      in
      let reopened_transition =
        Git.load_imported_transition reopened
          (Git.imported_transition_id transition)
        |> require_ok Git.error_to_string
      in
      Alcotest.(check (option string))
        "reopened author bytes" (Some author)
        (Git.imported_transition_author reopened_transition))

let imports_lightweight_and_annotated_tags () =
  tag_fixture (fun repository store commit annotation_bytes ->
      let lightweight =
        Git.import_tag Git.default_configuration ~store ~repository
          ~tag:"lightweight"
        |> require_ok Git.error_to_string
      in
      let lightweight_retry =
        Git.import_tag Git.default_configuration ~store ~repository
          ~tag:"lightweight"
        |> require_ok Git.error_to_string
      in
      Alcotest.(check bool)
        "lightweight retry has one tag ID" true
        (Id.Imported_tag_id.equal
           (Git.imported_tag_id lightweight.Git.imported_tag)
           (Git.imported_tag_id lightweight_retry.Git.imported_tag));
      let lightweight_mapping = Git.mapping_id lightweight.Git.tag_mapping in
      let annotated =
        Git.import_tag Git.default_configuration ~store ~repository
          ~tag:"annotated"
        |> require_ok Git.error_to_string
      in
      let reopened =
        Store.open_repository ~root:(Store.root store)
        |> require_ok Store.error_to_string
      in
      let lightweight =
        Git.load_imported_tag reopened
          (Git.imported_tag_id lightweight.Git.imported_tag)
        |> require_ok Git.error_to_string
      in
      Alcotest.(check string)
        "lightweight name" "lightweight"
        (Git.imported_tag_name lightweight);
      Alcotest.(check string)
        "lightweight target"
        (Git.object_id_to_hex commit)
        (Git.imported_tag_target lightweight |> Git.object_id_to_hex);
      Alcotest.(check bool)
        "lightweight target equals direct object" true
        (String.equal
           (Git.imported_tag_target lightweight |> Git.object_id_to_hex)
           (Git.imported_tag_ref_object lightweight |> Git.object_id_to_hex));
      Alcotest.(check bool)
        "lightweight has no annotation" true
        (Option.is_none (Git.imported_tag_annotation lightweight));
      let annotated =
        Git.load_imported_tag reopened
          (Git.imported_tag_id annotated.Git.imported_tag)
        |> require_ok Git.error_to_string
      in
      Alcotest.(check string)
        "annotated name" "annotated"
        (Git.imported_tag_name annotated);
      Alcotest.(check string)
        "annotated target"
        (Git.object_id_to_hex commit)
        (Git.imported_tag_target annotated |> Git.object_id_to_hex);
      (match
         Envelope.decode
           (imported_tag_envelope_bytes reopened
              (Git.imported_tag_id annotated))
       with
      | Ok envelope ->
          Alcotest.(check int)
            "annotated tag envelope type" 25
            (Envelope.object_type_code (Envelope.object_type envelope))
      | Error error ->
          Alcotest.fail
            ("annotated tag envelope failed to decode: "
            ^ Envelope.decode_error_to_string error));
      Alcotest.(check bool)
        "annotated direct object differs from target" false
        (String.equal
           (Git.imported_tag_target annotated |> Git.object_id_to_hex)
           (Git.imported_tag_ref_object annotated |> Git.object_id_to_hex));
      (match Git.imported_tag_target_kind annotated with
      | Git.Tag_commit -> ()
      | Git.Tag_tree | Git.Tag_blob ->
          Alcotest.fail "annotated commit tag has the wrong target kind");
      let annotation =
        match Git.imported_tag_annotation annotated with
        | Some annotation -> annotation
        | None -> Alcotest.fail "annotated tag lost raw bytes"
      in
      Alcotest.(check string)
        "annotated raw bytes" annotation_bytes
        (Snapshot.Content.load reopened annotation
        |> require_ok Snapshot.error_to_string);
      let mapping =
        Git.load_mapping reopened lightweight_mapping
        |> require_ok Git.error_to_string
      in
      match Git.mapping_subject mapping with
      | Git.Imported_tag { tag; _ } ->
          Alcotest.(check bool)
            "mapping names imported tag" true
            (Id.Imported_tag_id.equal tag (Git.imported_tag_id lightweight))
      | Git.Imported_snapshot _ | Git.Imported_transition _
      | Git.Imported_revision _ | Git.Exported_release _
      | Git.Exported_revision _ ->
          Alcotest.fail "tag mapping did not name an imported tag")

let rejects_malformed_tag_data () =
  with_directory "yeokcham-git-tag-errors-" (fun repository ->
      let store_root = Filename.concat repository "store" in
      Unix.mkdir store_root 0o700;
      let store =
        Store.init ~root:store_root |> require_ok Store.error_to_string
      in
      let tag_object = String.make 40 '8' in
      let malformed =
        "object " ^ String.make 40 '9'
        ^ "\n\
           type commit\n\
           tag wrong\n\
           tagger Test <test@example.invalid> 0 +0000\n\n\
           body\n"
      in
      recorded_commands := [];
      queued_results :=
        [
          process_result ~stdout:(stream "false\n") ();
          process_result ~stdout:(stream "sha1\n") ();
          process_result
            ~stdout:(stream ("refs/tags/broken\000" ^ tag_object ^ "\000tag\n"))
            ();
          process_result ~stdout:(stream "tag\n") ();
          process_result ~stdout:(stream malformed) ();
        ];
      Git.import_tag
        ~runner:(module Fake_runner)
        fake_configuration ~store ~repository ~tag:"broken"
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "malformed annotated tag was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured malformed tag" true
               (contains ~needle:"invalid Git tag" (Git.error_to_string error)));
      recorded_commands := [];
      queued_results :=
        [
          process_result ~stdout:(stream "false\n") ();
          process_result ~stdout:(stream "sha1\n") ();
          process_result ~stdout:(stream "") ();
        ];
      Git.import_tag
        ~runner:(module Fake_runner)
        fake_configuration ~store ~repository ~tag:"missing"
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "missing tag was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured missing tag" true
               (contains ~needle:"tag ref is absent"
                  (Git.error_to_string error))))

let rejects_corrupt_tag_binding () =
  tag_fixture (fun repository store _commit _annotation_bytes ->
      let imported =
        Git.import_tag Git.default_configuration ~store ~repository
          ~tag:"annotated"
        |> require_ok Git.error_to_string
      in
      let tag = Git.imported_tag_id imported.Git.imported_tag in
      let components = [ "imported-tags"; Id.Imported_tag_id.to_hex tag ] in
      let existing =
        Store.Ref_file.read store ~components
        |> require_ok Store.error_to_string
      in
      (match existing with
      | Some bytes ->
          Store.Ref_file.compare_and_swap store ~components
            ~expected:(Some bytes) ~replacement:"corrupt"
          |> require_ok Store.error_to_string
      | None -> Alcotest.fail "imported tag binding was not written");
      Git.load_imported_tag store tag
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "corrupt tag binding was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured corrupt tag binding" true
               (contains ~needle:"imported tag error"
                  (Git.error_to_string error))))

let imported_transition_persistence_goldens_are_stable () =
  with_directory "yeokcham-git-transition-golden-" (fun root ->
      let repository = Filename.concat root "repository" in
      let store_root = Filename.concat root "store" in
      Unix.mkdir repository 0o700;
      Unix.mkdir store_root 0o700;
      let git = git_path () in
      direct_process git [ "init"; "--object-format=sha1"; "-q"; repository ];
      write_file (Filename.concat repository "golden") "golden\000bytes";
      direct_process git [ "-C"; repository; "add"; "--all" ];
      let tree = direct_capture git [ "-C"; repository; "write-tree" ] in
      let commit =
        direct_capture_with_environment git golden_commit_environment
          [ "-C"; repository; "commit-tree"; tree; "-m"; "golden" ]
      in
      let store =
        Store.init ~root:store_root |> require_ok Store.error_to_string
      in
      let identity =
        Git.object_id_of_hex Git.Sha1 commit |> require_ok Git.error_to_string
      in
      let imported =
        Git.import_commit Git.default_configuration ~store ~repository
          ~commit:identity
        |> require_ok Git.error_to_string
      in
      let transition = imported.Git.imported_transition in
      let transition_id = Git.imported_transition_id transition in
      let mapping_id = Git.mapping_id imported.Git.commit_mapping in
      let expected_identity =
        "Yeokcham Golden <golden@example.invalid> 1700000000 +0000"
      in
      Alcotest.(check (option string))
        "raw author identity" (Some expected_identity)
        (Git.imported_transition_author transition);
      Alcotest.(check (option string))
        "raw committer identity" (Some expected_identity)
        (Git.imported_transition_committer transition);
      let message =
        match Git.imported_transition_message transition with
        | Some message -> message
        | None -> Alcotest.fail "v2 transition did not retain a message"
      in
      Alcotest.(check string)
        "exact message bytes" "golden\n"
        (Snapshot.Content.load store message
        |> require_ok Snapshot.error_to_string);
      Alcotest.(check string)
        "canonical imported transition envelope"
        (refreshed_golden "git-imported-transition-v2.yeok.hex"
           (imported_transition_envelope_bytes store transition_id))
        (imported_transition_envelope_bytes store transition_id);
      Alcotest.(check string)
        "canonical imported transition binding"
        (refreshed_golden "git-imported-transition-v2.ref.hex"
           (binding_bytes store
              [
                "imported-transitions";
                Id.Imported_transition_id.to_hex transition_id;
              ]))
        (binding_bytes store
           [
             "imported-transitions";
             Id.Imported_transition_id.to_hex transition_id;
           ]);
      Alcotest.(check string)
        "canonical Git commit mapping v3 envelope"
        (refreshed_golden "git-commit-mapping-v3.yeok.hex"
           (mapping_envelope_bytes store mapping_id))
        (mapping_envelope_bytes store mapping_id);
      Alcotest.(check string)
        "canonical Git commit mapping v3 binding"
        (refreshed_golden "git-commit-mapping-v3.ref.hex"
           (binding_bytes store
              [ "git-mappings"; Id.Git_mapping_id.to_hex mapping_id ]))
        (binding_bytes store
           [ "git-mappings"; Id.Git_mapping_id.to_hex mapping_id ]);
      let legacy_transition =
        Git.Legacy_format.create_imported_transition_v1
          ~commit:(Git.imported_transition_commit transition)
          ~tree:(Git.imported_transition_tree transition)
          ~snapshot:(Git.imported_transition_snapshot transition)
          ~parents:(Git.imported_transition_parents transition)
        |> require_ok Git.error_to_string
      in
      let legacy_transition_object =
        Git.Legacy_format.transition_envelope legacy_transition
        |> require_ok Git.error_to_string
        |> Store.put store
        |> require_ok Store.error_to_string
      in
      let legacy_transition_binding =
        Git.Legacy_format.encode_transition_binding
          (Git.imported_transition_id legacy_transition)
          legacy_transition_object
        |> require_ok Git.error_to_string
      in
      ignore
        (refreshed_golden "git-imported-transition-v1.yeok.hex"
           (Store.get store legacy_transition_object
           |> require_ok Store.error_to_string
           |> Envelope.encode));
      ignore
        (refreshed_golden "git-imported-transition-v1.ref.hex"
           legacy_transition_binding);
      Store.Ref_file.compare_and_swap store
        ~components:
          [
            "imported-transitions";
            Id.Imported_transition_id.to_hex
              (Git.imported_transition_id legacy_transition);
          ]
        ~expected:None ~replacement:legacy_transition_binding
      |> require_ok Store.error_to_string;
      let loaded_legacy =
        Git.load_imported_transition store
          (Git.imported_transition_id legacy_transition)
        |> require_ok Git.error_to_string
      in
      Alcotest.(check (option string))
        "v1 transition has no synthetic author" None
        (Git.imported_transition_author loaded_legacy);
      Alcotest.(check bool)
        "v1 transition has no synthetic message" true
        (Option.is_none (Git.imported_transition_message loaded_legacy));
      let legacy_mapping =
        Git.Legacy_format.create_mapping_v2 ~direction:Git.Import
          ~git_object:(Git.mapping_git_object imported.Git.commit_mapping)
          ~git_kind:Git.Commit
          ~subject:
            (Git.Imported_transition
               {
                 transition = Git.imported_transition_id legacy_transition;
                 transition_object = legacy_transition_object;
               })
        |> require_ok Git.error_to_string
      in
      let legacy_mapping_object =
        Git.Legacy_format.mapping_envelope legacy_mapping
        |> require_ok Git.error_to_string
        |> Store.put store
        |> require_ok Store.error_to_string
      in
      let legacy_mapping_binding =
        Git.Legacy_format.encode_mapping_binding
          (Git.mapping_id legacy_mapping)
          legacy_mapping_object
        |> require_ok Git.error_to_string
      in
      ignore
        (refreshed_golden "git-mapping-v2.yeok.hex"
           (Store.get store legacy_mapping_object
           |> require_ok Store.error_to_string
           |> Envelope.encode));
      ignore (refreshed_golden "git-mapping-v2.ref.hex" legacy_mapping_binding);
      Store.Ref_file.compare_and_swap store
        ~components:
          [
            "git-mappings";
            Id.Git_mapping_id.to_hex (Git.mapping_id legacy_mapping);
          ]
        ~expected:None ~replacement:legacy_mapping_binding
      |> require_ok Store.error_to_string;
      match
        Git.load_mapping store (Git.mapping_id legacy_mapping)
        |> require_ok Git.error_to_string
      with
      | mapping ->
          Alcotest.(check bool)
            "legacy mapping retains transition subject" true
            (match Git.mapping_subject mapping with
            | Git.Imported_transition { transition; _ } ->
                Id.Imported_transition_id.equal transition
                  (Git.imported_transition_id legacy_transition)
            | Git.Imported_snapshot _ | Git.Imported_tag _
            | Git.Imported_revision _ | Git.Exported_release _
            | Git.Exported_revision _ ->
                false))

let imported_tag_persistence_goldens_are_stable () =
  with_directory "yeokcham-git-tag-golden-" (fun root ->
      let repository = Filename.concat root "repository" in
      let store_root = Filename.concat root "store" in
      Unix.mkdir repository 0o700;
      Unix.mkdir store_root 0o700;
      let git = git_path () in
      direct_process git [ "init"; "--object-format=sha1"; "-q"; repository ];
      write_file (Filename.concat repository "golden") "golden tag\000bytes";
      direct_process git [ "-C"; repository; "add"; "--all" ];
      let tree = direct_capture git [ "-C"; repository; "write-tree" ] in
      let commit =
        direct_capture_with_environment git golden_commit_environment
          [ "-C"; repository; "commit-tree"; tree; "-m"; "golden" ]
      in
      ignore
        (direct_capture_with_environment git golden_commit_environment
           [
             "-C";
             repository;
             "tag";
             "-a";
             "golden-tag";
             "-m";
             "golden annotation";
             commit;
           ]);
      let store =
        Store.init ~root:store_root |> require_ok Store.error_to_string
      in
      let imported =
        Git.import_tag Git.default_configuration ~store ~repository
          ~tag:"golden-tag"
        |> require_ok Git.error_to_string
      in
      let tag = imported.Git.imported_tag in
      let tag_id = Git.imported_tag_id tag in
      let mapping_id = Git.mapping_id imported.Git.tag_mapping in
      Alcotest.(check string)
        "canonical imported tag envelope"
        (refreshed_golden "git-imported-tag-v1.yeok.hex"
           (imported_tag_envelope_bytes store tag_id))
        (imported_tag_envelope_bytes store tag_id);
      Alcotest.(check string)
        "canonical imported tag binding"
        (refreshed_golden "git-imported-tag-v1.ref.hex"
           (binding_bytes store
              [ "imported-tags"; Id.Imported_tag_id.to_hex tag_id ]))
        (binding_bytes store
           [ "imported-tags"; Id.Imported_tag_id.to_hex tag_id ]);
      Alcotest.(check string)
        "canonical Git mapping v3 envelope"
        (refreshed_golden "git-mapping-v3.yeok.hex"
           (mapping_envelope_bytes store mapping_id))
        (mapping_envelope_bytes store mapping_id);
      Alcotest.(check string)
        "canonical Git mapping v3 binding"
        (refreshed_golden "git-mapping-v3.ref.hex"
           (binding_bytes store
              [ "git-mappings"; Id.Git_mapping_id.to_hex mapping_id ]))
        (binding_bytes store
           [ "git-mappings"; Id.Git_mapping_id.to_hex mapping_id ]))

let rejects_malformed_commit_data () =
  with_directory "yeokcham-git-commit-errors-" (fun repository ->
      let store_root = Filename.concat repository "store" in
      Unix.mkdir store_root 0o700;
      let store =
        Store.init ~root:store_root |> require_ok Store.error_to_string
      in
      let commit =
        Git.object_id_of_hex Git.Sha1 (String.make 40 '4')
        |> require_ok Git.error_to_string
      in
      let malformed = "tree " ^ String.make 40 '0' in
      recorded_commands := [];
      queued_results :=
        [
          process_result ~stdout:(stream "false\n") ();
          process_result ~stdout:(stream "sha1\n") ();
          process_result ~stdout:(stream "commit\n") ();
          process_result ~stdout:(stream malformed) ();
        ];
      Git.import_commit
        ~runner:(module Fake_runner)
        fake_configuration ~store ~repository ~commit
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "malformed Git commit was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured malformed commit" true
               (contains ~needle:"header block" (Git.error_to_string error)));
      let tree = String.make 40 '5' in
      let parent = String.make 40 '6' in
      let metadata_headers =
        "author Test <test@example.invalid> 1700000000 +0000\n"
        ^ "committer Test <test@example.invalid> 1700000000 +0000\n"
      in
      let missing_parent =
        "tree " ^ tree ^ "\nparent " ^ parent ^ "\n" ^ metadata_headers ^ "\n"
      in
      recorded_commands := [];
      queued_results :=
        [
          process_result ~stdout:(stream "false\n") ();
          process_result ~stdout:(stream "sha1\n") ();
          process_result ~stdout:(stream "commit\n") ();
          process_result ~stdout:(stream missing_parent) ();
          process_result ~status:Validation.Failed ~exit_code:(Some 128)
            ~stderr:(stream "fatal: missing\n")
            ();
        ];
      Git.import_commit
        ~runner:(module Fake_runner)
        fake_configuration ~store ~repository ~commit
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "missing parent was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured missing parent" true
               (contains ~needle:"cat-file-type failed"
                  (Git.error_to_string error)));
      recorded_commands := [];
      queued_results :=
        [
          process_result ~stdout:(stream "false\n") ();
          process_result ~stdout:(stream "sha1\n") ();
          process_result ~stdout:(stream "blob\n") ();
        ];
      Git.import_commit
        ~runner:(module Fake_runner)
        fake_configuration ~store ~repository ~commit
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "wrong-type commit was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured wrong object type" true
               (contains ~needle:"has type blob, expected commit"
                  (Git.error_to_string error)));
      let too_many =
        "tree " ^ tree ^ "\nparent " ^ parent ^ "\nparent " ^ String.make 40 '7'
        ^ "\n" ^ metadata_headers ^ "\n"
      in
      let limited =
        Git.configuration_with ~max_commit_parents:1 fake_configuration
      in
      recorded_commands := [];
      queued_results :=
        [
          process_result ~stdout:(stream "false\n") ();
          process_result ~stdout:(stream "sha1\n") ();
          process_result ~stdout:(stream "commit\n") ();
          process_result ~stdout:(stream too_many) ();
        ];
      Git.import_commit
        ~runner:(module Fake_runner)
        limited ~store ~repository ~commit
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "parent limit was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured parent bound" true
               (contains ~needle:"commit parents limit exceeded"
                  (Git.error_to_string error)));
      let self_parent =
        "tree " ^ tree ^ "\nparent " ^ String.make 40 '4' ^ "\n"
        ^ metadata_headers ^ "\n"
      in
      recorded_commands := [];
      queued_results :=
        [
          process_result ~stdout:(stream "false\n") ();
          process_result ~stdout:(stream "sha1\n") ();
          process_result ~stdout:(stream "commit\n") ();
          process_result ~stdout:(stream self_parent) ();
        ];
      Git.import_commit
        ~runner:(module Fake_runner)
        fake_configuration ~store ~repository ~commit
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "self-parent Git commit was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured self parent" true
               (contains ~needle:"names itself as a parent"
                  (Git.error_to_string error)));
      let missing_author =
        "tree " ^ tree
        ^ "\ncommitter Test <test@example.invalid> 1700000000 +0000\n\n"
      in
      recorded_commands := [];
      queued_results :=
        [
          process_result ~stdout:(stream "false\n") ();
          process_result ~stdout:(stream "sha1\n") ();
          process_result ~stdout:(stream "commit\n") ();
          process_result ~stdout:(stream missing_author) ();
        ];
      Git.import_commit
        ~runner:(module Fake_runner)
        fake_configuration ~store ~repository ~commit
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "missing author was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured missing author" true
               (contains ~needle:"author header is absent"
                  (Git.error_to_string error)));
      let rejects_metadata raw expected =
        recorded_commands := [];
        queued_results :=
          [
            process_result ~stdout:(stream "false\n") ();
            process_result ~stdout:(stream "sha1\n") ();
            process_result ~stdout:(stream "commit\n") ();
            process_result ~stdout:(stream raw) ();
          ];
        Git.import_commit
          ~runner:(module Fake_runner)
          fake_configuration ~store ~repository ~commit
        |> Result.fold
             ~ok:(fun _ -> Alcotest.fail "malformed metadata was accepted")
             ~error:(fun error ->
               Alcotest.(check bool)
                 ("structured metadata error: " ^ expected)
                 true
                 (contains ~needle:expected (Git.error_to_string error)))
      in
      rejects_metadata
        ("tree " ^ tree ^ "\nauthor \n" ^ metadata_headers ^ "\n")
        "author header is empty";
      rejects_metadata
        ("tree " ^ tree
       ^ "\nauthor First <first@example.invalid> 1700000000 +0000\n"
       ^ metadata_headers ^ "\n")
        "author header occurs more than once";
      rejects_metadata
        ("tree " ^ tree
       ^ "\nauthor NUL\000 <nul@example.invalid> 1700000000 +0000\n"
       ^ metadata_headers ^ "\n")
        "author header contains a NUL byte")

let rejects_corrupt_transition_binding () =
  commit_fixture (fun repository store _format commit _parents ->
      let imported =
        Git.import_commit Git.default_configuration ~store ~repository ~commit
        |> require_ok Git.error_to_string
      in
      let transition =
        Git.imported_transition_id imported.Git.imported_transition
      in
      let components =
        [ "imported-transitions"; Id.Imported_transition_id.to_hex transition ]
      in
      let existing =
        Store.Ref_file.read store ~components
        |> require_ok Store.error_to_string
      in
      (match existing with
      | Some bytes ->
          Store.Ref_file.compare_and_swap store ~components
            ~expected:(Some bytes) ~replacement:"corrupt"
          |> require_ok Store.error_to_string
      | None -> Alcotest.fail "imported transition binding was not written");
      Git.load_imported_transition store transition
      |> Result.fold
           ~ok:(fun _ ->
             Alcotest.fail "corrupt transition binding was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured corrupt transition binding" true
               (contains ~needle:"imported transition error"
                  (Git.error_to_string error))))

let rejects_missing_transition_message_content () =
  commit_fixture (fun repository store _format commit _parents ->
      let imported =
        Git.import_commit Git.default_configuration ~store ~repository ~commit
        |> require_ok Git.error_to_string
      in
      let transition = imported.Git.imported_transition in
      let message =
        match Git.imported_transition_message transition with
        | Some message -> message
        | None -> Alcotest.fail "imported v2 transition message is absent"
      in
      Unix.unlink
        (Store.object_path store (Snapshot.Content.stored_object_id message));
      Git.load_imported_transition store (Git.imported_transition_id transition)
      |> Result.fold
           ~ok:(fun _ ->
             Alcotest.fail "missing transition message was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured missing transition message" true
               (contains ~needle:"message is unavailable"
                  (Git.error_to_string error))))

let export_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let export_capsule_id seed =
  Id.Capsule_id.of_bytes (export_id seed) |> require_ok Id.parse_error_to_string

let export_workspace_id seed =
  Id.Workspace_id.of_bytes (export_id seed)
  |> require_ok Id.parse_error_to_string

let export_checkpoint scratch snapshot time =
  Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
    ~observed_at:time ~created_at:time
  |> require_ok Scratch.error_to_string
  |> function
  | Scratch.Created checkpoint | Scratch.Unchanged checkpoint ->
      Scratch.Checkpoint.id checkpoint

let release_export_fixture ?(nested_empty = false) ?(empty_root = false)
    ?(message = Some "release export\n") ?(created_at = 7L) run =
  with_directory "yeokcham-git-export-" (fun root ->
      let worktree = Filename.concat root "worktree" in
      let destination = Filename.concat root "destination" in
      Unix.mkdir worktree 0o700;
      Unix.mkdir destination 0o700;
      write_file (Filename.concat worktree "base") "base\n";
      let store =
        Store.init ~root:worktree |> require_ok Store.error_to_string
      in
      let scratch = Scratch.open_repository store in
      let base, _ =
        Snapshot.scan ~root:worktree ~store
        |> require_ok Snapshot.error_to_string
      in
      let initial =
        Scratch.create_initial scratch ~snapshot:base ~created_at:0L
        |> require_ok Scratch.error_to_string
        |> Scratch.Checkpoint.id
      in
      Unix.unlink (Filename.concat worktree "base");
      if not empty_root then (
        write_file (Filename.concat worktree "regular") "regular\000bytes";
        write_file (Filename.concat worktree "run") "#!/bin/sh\nprintf run\n";
        Unix.chmod (Filename.concat worktree "run") 0o755;
        Unix.mkdir (Filename.concat worktree "nested") 0o700;
        write_file (Filename.concat worktree "nested/data") "nested\n";
        if nested_empty then Unix.mkdir (Filename.concat worktree "empty") 0o700;
        Unix.symlink "regular" (Filename.concat worktree "link"));
      let target, _ =
        Snapshot.scan ~root:worktree ~store
        |> require_ok Snapshot.error_to_string
      in
      let target_checkpoint = export_checkpoint scratch target 1L in
      let capsule = export_capsule_id 10 in
      ignore
        (Capsule_store.Durable.create_from_checkpoints ~store ~scratch
           ~id:capsule ~title:"export" ~description:"fixture" ~dependencies:[]
           ~evidence:[] ~from:initial ~target:target_checkpoint ~created_at:2L
           ~changed_at:2L ()
        |> require_ok Capsule_store.error_to_string);
      let workspace = export_workspace_id 20 in
      ignore
        (Workspace_store.Durable.create ~store ~id:workspace ~base ~name:None
           ~description:None ~created_at:3L
        |> require_ok Workspace_store.error_to_string);
      ignore
        (Workspace_store.Durable.enable_current_capsule ~store ~workspace
           ~capsule ~expected_generation:None ~created_at:4L
        |> require_ok Workspace_store.error_to_string);
      let materialised =
        Workspace_store.Durable.materialise ~store ~scratch ~root:worktree
          ~workspace ~observed_at:5L ~created_at:5L ~dry_run:false ()
        |> require_ok Workspace_store.error_to_string
      in
      if materialised.Workspace_store.Durable.partial then
        Alcotest.fail "release export fixture conflicted";
      let release =
        Release.Durable.create ~store ~workspace ~parents:[] ~commands:[]
          ~message ~observed_at:6L ~created_at ()
        |> require_ok Release.error_to_string
      in
      direct_process (git_path ()) [ "init"; "-q"; destination ];
      run (git_path ()) destination store release)

let configured_release_export_metadata ?(author_name = "Configured Author")
    ?(author_email = "author@example.invalid")
    ?(committer_name = "Configured Committer")
    ?(committer_email = "committer@example.invalid")
    ?(message = "configured release\nmessage") () =
  {
    Git.release_export_author =
      { Git.git_identity_name = author_name; git_identity_email = author_email };
    release_export_committer =
      {
        Git.git_identity_name = committer_name;
        git_identity_email = committer_email;
      };
    release_export_message = message;
  }

let exports_release_as_exact_git_commit () =
  release_export_fixture (fun git destination store release ->
      let first =
        Git.export_release Git.default_configuration ~store
          ~repository:destination
          ~release:(Release.release_id release)
        |> require_ok Git.error_to_string
      in
      let repeated =
        Git.export_release Git.default_configuration ~store
          ~repository:destination
          ~release:(Release.release_id release)
        |> require_ok Git.error_to_string
      in
      Alcotest.(check string)
        "repeat has same commit"
        (Git.object_id_to_hex first.Git.export_commit)
        (Git.object_id_to_hex repeated.Git.export_commit);
      Alcotest.(check string)
        "deterministic release ref" first.Git.export_target_ref
        repeated.Git.export_target_ref;
      Alcotest.(check bool)
        "repeat has same mapping" true
        (Id.Git_mapping_id.equal
           (Git.mapping_id first.Git.export_mapping)
           (Git.mapping_id repeated.Git.export_mapping));
      direct_process git [ "-C"; destination; "fsck"; "--full" ];
      Alcotest.(check string)
        "ref names commit"
        (Git.object_id_to_hex first.Git.export_commit)
        (direct_capture git
           [ "-C"; destination; "rev-parse"; first.Git.export_target_ref ]);
      direct_process git
        [
          "-C";
          destination;
          "checkout";
          "-q";
          Git.object_id_to_hex first.Git.export_commit;
        ];
      let exported_snapshot =
        Snapshot.Snapshot.load store (Release.release_final_snapshot release)
        |> require_ok Snapshot.error_to_string
      in
      assert_snapshot_matches_directory ~ignore_git_directory:true store
        exported_snapshot destination;
      Alcotest.(check string)
        "regular checkout bytes" "regular\000bytes"
        (read_file (Filename.concat destination "regular"));
      Alcotest.(check string)
        "nested checkout bytes" "nested\n"
        (read_file (Filename.concat destination "nested/data"));
      Alcotest.(check bool)
        "executable checkout mode" true
        ((Unix.stat (Filename.concat destination "run")).Unix.st_perm land 0o111
        <> 0);
      Alcotest.(check string)
        "symlink checkout target" "regular"
        (Unix.readlink (Filename.concat destination "link"));
      let commit =
        direct_capture git
          [
            "-C";
            destination;
            "show";
            "-s";
            "--format=%an <%ae> %at %aI%x00%cn <%ce> %ct %cI%x00%B";
            Git.object_id_to_hex first.Git.export_commit;
          ]
      in
      Alcotest.(check bool)
        "fixed author metadata" true
        (contains ~needle:"Yeokcham Export <noreply@yeokcham.local> 7" commit);
      Alcotest.(check bool)
        "release message metadata" true
        (contains ~needle:"release export" commit);
      let reopened =
        Store.open_repository ~root:(Store.root store)
        |> require_ok Store.error_to_string
      in
      let mapping =
        Git.load_mapping reopened (Git.mapping_id first.Git.export_mapping)
        |> require_ok Git.error_to_string
      in
      (match Git.mapping_subject mapping with
      | Git.Exported_release { release = actual; final_snapshot; _ } ->
          Alcotest.(check bool)
            "mapping names release" true
            (Id.Release_id.equal actual (Release.release_id release));
          Alcotest.(check bool)
            "mapping names final snapshot" true
            (Snapshot.Snapshot.equal_id final_snapshot
               (Release.release_final_snapshot release))
      | Git.Imported_snapshot _ | Git.Imported_transition _ | Git.Imported_tag _
      | Git.Imported_revision _ | Git.Exported_revision _ ->
          Alcotest.fail "export mapping did not name the release");
      let components =
        [ "git-mappings"; Id.Git_mapping_id.to_hex (Git.mapping_id mapping) ]
      in
      let binding =
        Store.Ref_file.read reopened ~components
        |> require_ok Store.error_to_string
      in
      (match binding with
      | Some binding ->
          Store.Ref_file.compare_and_swap reopened ~components
            ~expected:(Some binding) ~replacement:"corrupt"
          |> require_ok Store.error_to_string
      | None -> Alcotest.fail "export mapping binding was not written");
      Git.load_mapping reopened (Git.mapping_id mapping)
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "corrupt export mapping was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured corrupt export mapping" true
               (contains ~needle:"Git mapping error"
                  (Git.error_to_string error))))

let exports_configured_release_metadata_exactly_and_idempotently () =
  release_export_fixture (fun git destination store release ->
      let release_id = Release.release_id release in
      let metadata = configured_release_export_metadata () in
      let default =
        Git.export_release Git.default_configuration ~store
          ~repository:destination ~release:release_id
        |> require_ok Git.error_to_string
      in
      let first =
        Git.export_release ~metadata Git.default_configuration ~store
          ~repository:destination ~release:release_id
        |> require_ok Git.error_to_string
      in
      let repeated =
        Git.export_release ~metadata Git.default_configuration ~store
          ~repository:destination ~release:release_id
        |> require_ok Git.error_to_string
      in
      let alternate_metadata =
        configured_release_export_metadata ~message:"alternate release message"
          ()
      in
      let alternate =
        Git.export_release ~metadata:alternate_metadata
          Git.default_configuration ~store ~repository:destination
          ~release:release_id
        |> require_ok Git.error_to_string
      in
      Alcotest.(check string)
        "configured retry has same commit"
        (Git.object_id_to_hex first.Git.export_commit)
        (Git.object_id_to_hex repeated.Git.export_commit);
      Alcotest.(check bool)
        "configured output differs from default" false
        (String.equal
           (Git.object_id_to_hex default.Git.export_commit)
           (Git.object_id_to_hex first.Git.export_commit));
      Alcotest.(check bool)
        "different metadata differs" false
        (String.equal
           (Git.object_id_to_hex first.Git.export_commit)
           (Git.object_id_to_hex alternate.Git.export_commit));
      Alcotest.(check bool)
        "configured ref is metadata scoped" true
        (contains
           ~needle:
             ("refs/heads/yeokcham/release-"
             ^ Id.Release_id.to_hex release_id
             ^ "-metadata-")
           first.Git.export_target_ref);
      Alcotest.(check string)
        "configured retry has same ref" first.Git.export_target_ref
        repeated.Git.export_target_ref;
      Alcotest.(check bool)
        "configured retry has same mapping" true
        (Id.Git_mapping_id.equal
           (Git.mapping_id first.Git.export_mapping)
           (Git.mapping_id repeated.Git.export_mapping));
      Alcotest.(check bool)
        "configured metadata does not change release identity" true
        (Id.Release_id.equal release_id first.Git.export_release);
      Alcotest.(check string)
        "configured metadata does not change tree"
        (Git.object_id_to_hex default.Git.export_tree)
        (Git.object_id_to_hex first.Git.export_tree);
      let commit =
        direct_capture git
          [
            "-C";
            destination;
            "show";
            "-s";
            "--format=%an <%ae> %at %aI%x00%cn <%ce> %ct %cI%x00%B";
            Git.object_id_to_hex first.Git.export_commit;
          ]
      in
      Alcotest.(check string)
        "configured author, committer, and message"
        "Configured Author <author@example.invalid> 7 \
         1970-01-01T00:00:07Z\000Configured Committer \
         <committer@example.invalid> 7 1970-01-01T00:00:07Z\000configured \
         release\n\
         message"
        commit;
      direct_process git [ "-C"; destination; "fsck"; "--full" ];
      direct_process git
        [
          "-C";
          destination;
          "checkout";
          "-q";
          Git.object_id_to_hex first.Git.export_commit;
        ];
      let configured_snapshot =
        Snapshot.Snapshot.load store (Release.release_final_snapshot release)
        |> require_ok Snapshot.error_to_string
      in
      assert_snapshot_matches_directory ~ignore_git_directory:true store
        configured_snapshot destination;
      Alcotest.(check string)
        "configured checkout bytes" "regular\000bytes"
        (read_file (Filename.concat destination "regular"));
      let reopened =
        Store.open_repository ~root:(Store.root store)
        |> require_ok Store.error_to_string
      in
      Git.load_mapping reopened (Git.mapping_id first.Git.export_mapping)
      |> require_ok Git.error_to_string
      |> ignore)

let configured_release_metadata_rejects_and_retries_explicitly () =
  release_export_fixture (fun git destination store release ->
      let release_id = Release.release_id release in
      let metadata = configured_release_export_metadata () in
      let ref_prefix =
        "refs/heads/yeokcham/release-"
        ^ Id.Release_id.to_hex release_id
        ^ "-metadata-"
      in
      let assert_no_ref label =
        Alcotest.(check string)
          label ""
          (direct_capture git
             [
               "-C";
               destination;
               "for-each-ref";
               "--format=%(refname)";
               ref_prefix;
             ])
      in
      let invalid =
        configured_release_export_metadata ~author_name:"bad\nauthor" ()
      in
      Git.export_release ~metadata:invalid Git.default_configuration ~store
        ~repository:destination ~release:release_id
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "invalid configured metadata exported")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured configured identity rejection" true
               (contains ~needle:"configured Git author name"
                  (Git.error_to_string error)));
      assert_no_ref "invalid configured metadata leaves no ref";
      let bounded =
        Git.configuration_with ~max_commit_bytes:1 Git.default_configuration
      in
      Git.export_release ~metadata bounded ~store ~repository:destination
        ~release:release_id
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "bounded configured metadata exported")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured configured metadata bound" true
               (contains ~needle:"configured release commit bytes"
                  (Git.error_to_string error)));
      assert_no_ref "over-bound configured metadata leaves no ref";
      Git.export_release ~metadata ~fail_at:Git.Before_git_ref
        Git.default_configuration ~store ~repository:destination
        ~release:release_id
      |> Result.fold
           ~ok:(fun _ ->
             Alcotest.fail "configured pre-ref interruption succeeded")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured configured pre-ref interruption" true
               (contains ~needle:"injected interruption"
                  (Git.error_to_string error)));
      assert_no_ref "configured pre-ref interruption leaves no ref";
      Git.export_release ~metadata ~fail_at:Git.Before_mapping_binding
        Git.default_configuration ~store ~repository:destination
        ~release:release_id
      |> Result.fold
           ~ok:(fun _ ->
             Alcotest.fail "configured pre-mapping interruption succeeded")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured configured pre-mapping interruption" true
               (contains ~needle:"injected interruption"
                  (Git.error_to_string error)));
      Alcotest.(check bool)
        "configured pre-mapping interruption writes ref" true
        (contains ~needle:ref_prefix
           (direct_capture git
              [
                "-C";
                destination;
                "for-each-ref";
                "--format=%(refname)";
                "refs/heads/yeokcham";
              ]));
      let retried =
        Git.export_release ~metadata Git.default_configuration ~store
          ~repository:destination ~release:release_id
        |> require_ok Git.error_to_string
      in
      let reopened =
        Store.open_repository ~root:(Store.root store)
        |> require_ok Store.error_to_string
      in
      Git.load_mapping reopened (Git.mapping_id retried.Git.export_mapping)
      |> require_ok Git.error_to_string
      |> ignore;
      direct_process git
        [ "-C"; destination; "config"; "user.name"; "Yeokcham Fixture" ];
      direct_process git
        [ "-C"; destination; "config"; "user.email"; "fixture@example.invalid" ];
      direct_process git
        [ "-C"; destination; "commit"; "--allow-empty"; "-q"; "-m"; "other" ];
      let other =
        direct_capture git [ "-C"; destination; "rev-parse"; "HEAD" ]
      in
      direct_process git
        [
          "-C"; destination; "update-ref"; retried.Git.export_target_ref; other;
        ];
      Git.export_release ~metadata Git.default_configuration ~store
        ~repository:destination ~release:release_id
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "configured ref collision exported")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured configured ref collision" true
               (contains ~needle:"target ref already names a different commit"
                  (Git.error_to_string error)));
      direct_process git [ "-C"; destination; "fsck"; "--full" ])

let revision_export_fixture ?(empty_first = false) ?(nested_empty = false) run =
  with_directory "yeokcham-git-revision-export-" (fun root ->
      let worktree = Filename.concat root "worktree" in
      let destination = Filename.concat root "destination" in
      Unix.mkdir worktree 0o700;
      Unix.mkdir destination 0o700;
      write_file (Filename.concat worktree "base") "base\n";
      let store =
        Store.init ~root:worktree |> require_ok Store.error_to_string
      in
      let scratch = Scratch.open_repository store in
      let base, _ =
        Snapshot.scan ~root:worktree ~store
        |> require_ok Snapshot.error_to_string
      in
      let initial =
        Scratch.create_initial scratch ~snapshot:base ~created_at:0L
        |> require_ok Scratch.error_to_string
        |> Scratch.Checkpoint.id
      in
      Unix.unlink (Filename.concat worktree "base");
      if not empty_first then (
        write_file (Filename.concat worktree "first") "first\000bytes";
        write_file (Filename.concat worktree "run") "#!/bin/sh\nprintf first\n";
        Unix.chmod (Filename.concat worktree "run") 0o755;
        Unix.symlink "first" (Filename.concat worktree "link");
        Unix.mkdir (Filename.concat worktree "nested") 0o700;
        write_file (Filename.concat worktree "nested/data") "nested\n");
      if nested_empty then Unix.mkdir (Filename.concat worktree "empty") 0o700;
      let first_snapshot, _ =
        Snapshot.scan ~root:worktree ~store
        |> require_ok Snapshot.error_to_string
      in
      let first_checkpoint = export_checkpoint scratch first_snapshot 1L in
      let first_capsule = export_capsule_id 40 in
      let first =
        Capsule_store.Durable.create_from_checkpoints ~store ~scratch
          ~id:first_capsule ~title:"first" ~description:"first revision"
          ~dependencies:[] ~evidence:[] ~from:initial ~target:first_checkpoint
          ~created_at:2L ~changed_at:2L ()
        |> require_ok Capsule_store.error_to_string
      in
      write_file (Filename.concat worktree "second") "second\n";
      let second_snapshot, _ =
        Snapshot.scan ~root:worktree ~store
        |> require_ok Snapshot.error_to_string
      in
      let second_checkpoint = export_checkpoint scratch second_snapshot 3L in
      let second_capsule = export_capsule_id 41 in
      let second =
        Capsule_store.Durable.create_from_checkpoints ~store ~scratch
          ~id:second_capsule ~title:"second" ~description:"second revision"
          ~dependencies:[] ~evidence:[] ~from:first_checkpoint
          ~target:second_checkpoint ~created_at:4L ~changed_at:4L ()
        |> require_ok Capsule_store.error_to_string
      in
      let source resolved =
        let revision = Capsule_store.Durable.resolved_revision resolved in
        Capsule_store.make_revision_link
          ~capsule:(Capsule_store.revision_capsule revision)
          ~revision:(Capsule_store.revision_id revision)
          ~object_id:(Capsule_store.Durable.resolved_revision_object resolved)
      in
      direct_process (git_path ()) [ "init"; "-q"; destination ];
      run (git_path ()) destination store
        [ source first; source second ]
        [ first_snapshot; second_snapshot ])

let exports_revisions_as_exact_linear_git_commits () =
  revision_export_fixture (fun git destination store sources snapshots ->
      let exported =
        Git.export_revisions Git.default_configuration ~store
          ~repository:destination ~revisions:sources
        |> require_ok Git.error_to_string
      in
      let first, second =
        match exported.Git.revision_exports with
        | [ first; second ] -> (first, second)
        | _ -> Alcotest.fail "revision export did not return two commits"
      in
      Alcotest.(check bool)
        "first export keeps source link" true
        (Id.Capsule_revision_id.equal
           (Capsule_store.revision_link_revision
              first.Git.revision_export_source)
           (Capsule_store.revision_link_revision (List.hd sources)));
      Alcotest.(check bool)
        "first export keeps result snapshot" true
        (Snapshot.Snapshot.equal_id first.Git.revision_export_snapshot
           (List.hd snapshots));
      direct_process git [ "-C"; destination; "fsck"; "--full" ];
      Alcotest.(check string)
        "target ref names tip"
        (Git.object_id_to_hex second.Git.revision_export_commit)
        (direct_capture git
           [
             "-C";
             destination;
             "rev-parse";
             exported.Git.revision_export_target_ref;
           ]);
      Alcotest.(check string)
        "first commit has no parent" ""
        (direct_capture git
           [
             "-C";
             destination;
             "show";
             "-s";
             "--format=%P";
             Git.object_id_to_hex first.Git.revision_export_commit;
           ]);
      Alcotest.(check string)
        "second commit has first as its only parent"
        (Git.object_id_to_hex first.Git.revision_export_commit)
        (direct_capture git
           [
             "-C";
             destination;
             "show";
             "-s";
             "--format=%P";
             Git.object_id_to_hex second.Git.revision_export_commit;
           ]);
      direct_process git
        [
          "-C";
          destination;
          "checkout";
          "-q";
          Git.object_id_to_hex first.Git.revision_export_commit;
        ];
      let first_snapshot =
        Snapshot.Snapshot.load store (List.hd snapshots)
        |> require_ok Snapshot.error_to_string
      in
      assert_snapshot_matches_directory ~ignore_git_directory:true store
        first_snapshot destination;
      Alcotest.(check string)
        "first checkout bytes" "first\000bytes"
        (read_file (Filename.concat destination "first"));
      Alcotest.(check bool)
        "first checkout executable mode" true
        ((Unix.stat (Filename.concat destination "run")).Unix.st_perm land 0o111
        <> 0);
      Alcotest.(check string)
        "first checkout symlink target" "first"
        (Unix.readlink (Filename.concat destination "link"));
      Alcotest.(check string)
        "first checkout nested bytes" "nested\n"
        (read_file (Filename.concat destination "nested/data"));
      Alcotest.(check bool)
        "first checkout excludes second" true
        (not (Sys.file_exists (Filename.concat destination "second")));
      direct_process git
        [
          "-C";
          destination;
          "checkout";
          "-q";
          Git.object_id_to_hex second.Git.revision_export_commit;
        ];
      let second_snapshot =
        Snapshot.Snapshot.load store (List.nth snapshots 1)
        |> require_ok Snapshot.error_to_string
      in
      assert_snapshot_matches_directory ~ignore_git_directory:true store
        second_snapshot destination;
      Alcotest.(check string)
        "second checkout bytes" "second\n"
        (read_file (Filename.concat destination "second"));
      let metadata =
        direct_capture git
          [
            "-C";
            destination;
            "show";
            "-s";
            "--format=%an <%ae> %at %z%x00%B";
            Git.object_id_to_hex second.Git.revision_export_commit;
          ]
      in
      Alcotest.(check bool)
        "fixed revision metadata" true
        (contains ~needle:"Yeokcham Export <noreply@yeokcham.local> 4" metadata);
      Alcotest.(check bool)
        "fixed revision message" true
        (contains
           ~needle:
             ("Yeokcham capsule "
             ^ Id.Capsule_id.to_hex
                 (Capsule_store.revision_link_capsule
                    (List.hd (List.rev sources)))
             ^ " revision ")
           metadata);
      let reopened =
        Store.open_repository ~root:(Store.root store)
        |> require_ok Store.error_to_string
      in
      List.iter2
        (fun source current ->
          let mapping =
            Git.load_mapping reopened
              (Git.mapping_id current.Git.revision_export_mapping)
            |> require_ok Git.error_to_string
          in
          match Git.mapping_subject mapping with
          | Git.Exported_revision
              { capsule; revision; revision_object; final_snapshot } ->
              Alcotest.(check bool)
                "mapping keeps capsule" true
                (Id.Capsule_id.equal capsule
                   (Capsule_store.revision_link_capsule source));
              Alcotest.(check bool)
                "mapping keeps revision" true
                (Id.Capsule_revision_id.equal revision
                   (Capsule_store.revision_link_revision source));
              Alcotest.(check bool)
                "mapping keeps revision object" true
                (Store.Stored_object_id.equal revision_object
                   (Capsule_store.revision_link_object source));
              Alcotest.(check bool)
                "mapping keeps final snapshot" true
                (Snapshot.Snapshot.equal_id final_snapshot
                   current.Git.revision_export_snapshot)
          | Git.Imported_snapshot _ | Git.Imported_transition _
          | Git.Imported_tag _ | Git.Imported_revision _
          | Git.Exported_release _ ->
              Alcotest.fail "revision export mapping has the wrong subject")
        sources exported.Git.revision_exports;
      let repeated =
        Git.export_revisions Git.default_configuration ~store
          ~repository:destination ~revisions:sources
        |> require_ok Git.error_to_string
      in
      Alcotest.(check string)
        "restart keeps target ref" exported.Git.revision_export_target_ref
        repeated.Git.revision_export_target_ref;
      Alcotest.(check (list string))
        "restart keeps commits"
        (List.map
           (fun current ->
             Git.object_id_to_hex current.Git.revision_export_commit)
           exported.Git.revision_exports)
        (List.map
           (fun current ->
             Git.object_id_to_hex current.Git.revision_export_commit)
           repeated.Git.revision_exports))

let revision_export_rejects_invalid_selection_and_recovers_partial_mapping () =
  revision_export_fixture (fun git destination store sources _snapshots ->
      let first, second =
        match sources with
        | [ first; second ] -> (first, second)
        | _ -> Alcotest.fail "revision export fixture has invalid sources"
      in
      let reject label revisions configuration needle =
        Git.export_revisions configuration ~store ~repository:destination
          ~revisions
        |> Result.fold
             ~ok:(fun _ -> Alcotest.fail (label ^ " exported"))
             ~error:(fun error ->
               Alcotest.(check bool)
                 label true
                 (contains ~needle (Git.error_to_string error)))
      in
      reject "empty selection" [] Git.default_configuration
        "requires one or more";
      reject "duplicate selection" [ first; first ] Git.default_configuration
        "repeats a capsule/revision";
      reject "reversed chain" [ second; first ] Git.default_configuration
        "do not form";
      let mismatched =
        Capsule_store.make_revision_link
          ~capsule:(Capsule_store.revision_link_capsule first)
          ~revision:(Capsule_store.revision_link_revision second)
          ~object_id:(Capsule_store.revision_link_object second)
      in
      reject "mismatched source" [ mismatched ] Git.default_configuration
        "revision link";
      let bounded =
        Git.configuration_with ~max_export_commits:1 Git.default_configuration
      in
      reject "commit bound" sources bounded "revision export commits limit";
      Git.export_revisions ~fail_at:Git.Before_git_ref Git.default_configuration
        ~store ~repository:destination ~revisions:sources
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "pre-ref interruption exported")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured pre-ref interruption" true
               (contains ~needle:"injected interruption"
                  (Git.error_to_string error)));
      Alcotest.(check string)
        "pre-ref interruption leaves no export ref" ""
        (direct_capture git
           [
             "-C";
             destination;
             "for-each-ref";
             "--format=%(refname)";
             "refs/heads/yeokcham/capsule-linear-";
           ]);
      Git.export_revisions ~fail_at:(Git.Before_revision_mapping_binding 1)
        Git.default_configuration ~store ~repository:destination
        ~revisions:sources
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "partial mapping interruption exported")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured partial mapping interruption" true
               (contains ~needle:"injected interruption"
                  (Git.error_to_string error)));
      let retried =
        Git.export_revisions Git.default_configuration ~store
          ~repository:destination ~revisions:sources
        |> require_ok Git.error_to_string
      in
      let first_export = List.hd retried.Git.revision_exports in
      let first_revision =
        Capsule_store.Durable.verify_link store first
        |> require_ok Capsule_store.error_to_string
      in
      Unix.unlink
        (Store.object_path store (Capsule_store.revision_link_object first));
      Git.load_mapping store
        (Git.mapping_id first_export.Git.revision_export_mapping)
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "mapping accepted a missing revision")
           ~error:(fun error ->
             Alcotest.(check bool)
               "mapping verifies its source revision" true
               (contains ~needle:"exported revision mapping source is invalid"
                  (Git.error_to_string error)));
      Capsule_store.store_revision store first_revision
      |> require_ok Capsule_store.error_to_string
      |> ignore;
      Git.load_mapping store
        (Git.mapping_id first_export.Git.revision_export_mapping)
      |> require_ok Git.error_to_string
      |> ignore;
      direct_process git
        [ "-C"; destination; "config"; "user.name"; "Yeokcham Fixture" ];
      direct_process git
        [ "-C"; destination; "config"; "user.email"; "fixture@example.invalid" ];
      direct_process git
        [ "-C"; destination; "commit"; "--allow-empty"; "-q"; "-m"; "other" ];
      let other =
        direct_capture git [ "-C"; destination; "rev-parse"; "HEAD" ]
      in
      direct_process git
        [
          "-C";
          destination;
          "update-ref";
          retried.Git.revision_export_target_ref;
          other;
        ];
      reject "target ref collision" sources Git.default_configuration
        "target ref already names a different commit")

let exports_empty_root_revision_and_rejects_nested_empty_revision () =
  revision_export_fixture ~empty_first:true
    (fun git destination store sources snapshots ->
      let exported =
        Git.export_revisions Git.default_configuration ~store
          ~repository:destination ~revisions:sources
        |> require_ok Git.error_to_string
      in
      let first = List.hd exported.Git.revision_exports in
      direct_process git
        [
          "-C";
          destination;
          "checkout";
          "-q";
          Git.object_id_to_hex first.Git.revision_export_commit;
        ];
      let visible =
        Sys.readdir destination |> Array.to_list
        |> List.filter (fun name -> not (String.equal name ".git"))
      in
      Alcotest.(check (list string)) "empty revision checkout" [] visible;
      let snapshot = List.hd snapshots in
      let capsule =
        Capsule_store.create_capsule ~id:(export_capsule_id 42) ~title:"no-op"
          ~description:"no-op revision" ~created_at:5L
        |> require_ok Capsule_store.error_to_string
      in
      let revision =
        Capsule_store.create_revision ~capsule ~parent:None
          ~declared_base:snapshot ~expected_result:snapshot ~operations:[]
          ~dependencies:[] ~evidence:[] ~boundaries:[]
          ~provenance:Capsule_store.Created ~created_at:5L
        |> require_ok Capsule_store.error_to_string
      in
      let source =
        Capsule_store.make_revision_link
          ~capsule:(Capsule_store.capsule_id capsule)
          ~revision:(Capsule_store.revision_id revision)
          ~object_id:
            (Capsule_store.store_revision store revision
            |> require_ok Capsule_store.error_to_string)
      in
      let no_op =
        Git.export_revisions Git.default_configuration ~store
          ~repository:destination ~revisions:[ source ]
        |> require_ok Git.error_to_string
      in
      Alcotest.(check int)
        "no-op revision still has one commit" 1
        (List.length no_op.Git.revision_exports);
      direct_process git [ "-C"; destination; "fsck"; "--full" ];
      ());
  revision_export_fixture ~nested_empty:true
    (fun git destination store sources _snapshots ->
      Git.export_revisions Git.default_configuration ~store
        ~repository:destination ~revisions:sources
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "nested empty revision exported")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured nested empty revision rejection" true
               (contains ~needle:"nested empty directory"
                  (Git.error_to_string error)));
      Alcotest.(check string)
        "nested empty revision leaves no export ref" ""
        (direct_capture git
           [
             "-C";
             destination;
             "for-each-ref";
             "--format=%(refname)";
             "refs/heads/yeokcham/capsule-linear-";
           ]))

let exports_empty_release_with_fallback_message () =
  release_export_fixture ~empty_root:true ~message:None
    (fun git destination store release ->
      let result =
        Git.export_release Git.default_configuration ~store
          ~repository:destination
          ~release:(Release.release_id release)
        |> require_ok Git.error_to_string
      in
      direct_process git
        [
          "-C";
          destination;
          "checkout";
          "-q";
          Git.object_id_to_hex result.Git.export_commit;
        ];
      let visible =
        Sys.readdir destination |> Array.to_list
        |> List.filter (fun name -> not (String.equal name ".git"))
      in
      Alcotest.(check (list string)) "empty checkout" [] visible;
      let message =
        direct_capture git
          [
            "-C";
            destination;
            "show";
            "-s";
            "--format=%B";
            Git.object_id_to_hex result.Git.export_commit;
          ]
      in
      Alcotest.(check string)
        "fallback message"
        ("Yeokcham release " ^ Id.Release_id.to_hex (Release.release_id release))
        message)

let export_ref_collision_and_bounds_reject_explicitly () =
  release_export_fixture (fun git destination store release ->
      direct_process git
        [ "-C"; destination; "config"; "user.name"; "Yeokcham Fixture" ];
      direct_process git
        [ "-C"; destination; "config"; "user.email"; "fixture@example.invalid" ];
      direct_process git
        [ "-C"; destination; "commit"; "--allow-empty"; "-q"; "-m"; "existing" ];
      let existing =
        direct_capture git [ "-C"; destination; "rev-parse"; "HEAD" ]
      in
      let target_ref =
        "refs/heads/yeokcham/release-"
        ^ Id.Release_id.to_hex (Release.release_id release)
      in
      direct_process git
        [ "-C"; destination; "update-ref"; target_ref; existing ];
      Git.export_release Git.default_configuration ~store
        ~repository:destination
        ~release:(Release.release_id release)
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "ref collision exported")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured ref collision" true
               (contains ~needle:"target ref already names a different commit"
                  (Git.error_to_string error)));
      with_directory "yeokcham-git-export-bounded-" (fun bounded ->
          direct_process git [ "init"; "-q"; bounded ];
          let configuration =
            Git.configuration_with ~max_blob_bytes:1 ~max_total_blob_bytes:1
              Git.default_configuration
          in
          Git.export_release configuration ~store ~repository:bounded
            ~release:(Release.release_id release)
          |> Result.fold
               ~ok:(fun _ -> Alcotest.fail "over-limit blob exported")
               ~error:(fun error ->
                 Alcotest.(check bool)
                   "structured blob limit" true
                   (contains ~needle:"Git export blob bytes limit exceeded"
                      (Git.error_to_string error)))))

let negative_release_timestamp_rejects_before_export () =
  release_export_fixture ~created_at:(-1L)
    (fun _git destination store release ->
      Git.export_release Git.default_configuration ~store
        ~repository:destination
        ~release:(Release.release_id release)
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "negative timestamp exported")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured timestamp rejection" true
               (contains ~needle:"timestamp must be nonnegative"
                  (Git.error_to_string error))))

let export_interruption_is_explicit_and_retryable () =
  release_export_fixture (fun git destination store release ->
      let release_id = Release.release_id release in
      let target_ref =
        "refs/heads/yeokcham/release-" ^ Id.Release_id.to_hex release_id
      in
      Git.export_release ~fail_at:Git.Before_git_ref Git.default_configuration
        ~store ~repository:destination ~release:release_id
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "pre-ref interruption succeeded")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured pre-ref interruption" true
               (contains ~needle:"injected interruption"
                  (Git.error_to_string error)));
      Alcotest.(check string)
        "pre-ref interruption leaves ref absent" ""
        (direct_capture git
           [
             "-C";
             destination;
             "for-each-ref";
             "--format=%(refname)";
             target_ref;
           ]);
      Git.export_release ~fail_at:Git.Before_mapping_binding
        Git.default_configuration ~store ~repository:destination
        ~release:release_id
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "pre-mapping interruption succeeded")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured pre-mapping interruption" true
               (contains ~needle:"injected interruption"
                  (Git.error_to_string error)));
      Alcotest.(check bool)
        "pre-mapping interruption leaves external ref" true
        (not
           (String.is_empty
              (direct_capture git
                 [ "-C"; destination; "rev-parse"; target_ref ])));
      let retried =
        Git.export_release Git.default_configuration ~store
          ~repository:destination ~release:release_id
        |> require_ok Git.error_to_string
      in
      Git.load_mapping store (Git.mapping_id retried.Git.export_mapping)
      |> require_ok Git.error_to_string
      |> ignore)

let nested_empty_directory_rejects_before_export_ref () =
  release_export_fixture ~nested_empty:true
    (fun git destination store release ->
      let release_id = Release.release_id release in
      Git.export_release Git.default_configuration ~store
        ~repository:destination ~release:release_id
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "nested empty directory exported")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured nested-empty rejection" true
               (contains ~needle:"nested empty directory"
                  (Git.error_to_string error)));
      Alcotest.(check string)
        "nested-empty rejection leaves ref absent" ""
        (direct_capture git
           [
             "-C";
             destination;
             "for-each-ref";
             "--format=%(refname)";
             "refs/heads/yeokcham/release-" ^ Id.Release_id.to_hex release_id;
           ]))

let imports_exact_tree_and_restarts_idempotently () =
  import_fixture (fun repository store tree ->
      let imported =
        Git.import_tree Git.default_configuration ~store ~repository ~tree
        |> require_ok Git.error_to_string
      in
      let repeated =
        Git.import_tree Git.default_configuration ~store ~repository ~tree
        |> require_ok Git.error_to_string
      in
      Alcotest.(check bool)
        "same tree has same snapshot" true
        (Snapshot.Snapshot.equal_id imported.Git.snapshot repeated.Git.snapshot);
      Alcotest.(check bool)
        "same tree has same mapping" true
        (Id.Git_mapping_id.equal
           (Git.mapping_id imported.Git.mapping)
           (Git.mapping_id repeated.Git.mapping));
      write_file (Filename.concat repository "regular") "changed\n";
      write_file (Filename.concat repository "nested/data") "changed nested\n";
      Unix.chmod (Filename.concat repository "run") 0o644;
      Unix.unlink (Filename.concat repository "link");
      Unix.symlink "nested/data" (Filename.concat repository "link");
      let reopened =
        Store.open_repository ~root:(Store.root store)
        |> require_ok Store.error_to_string
      in
      let mapping =
        Git.load_mapping reopened (Git.mapping_id imported.Git.mapping)
        |> require_ok Git.error_to_string
      in
      let mapping_bytes =
        mapping_envelope_bytes reopened (Git.mapping_id mapping)
      in
      Alcotest.(check string)
        "canonical Git mapping envelope"
        (refreshed_golden "git-mapping-v1.yeok.hex" mapping_bytes)
        mapping_bytes;
      (match Git.mapping_subject mapping with
      | Git.Imported_snapshot snapshot ->
          Alcotest.(check bool)
            "mapping points to imported snapshot" true
            (Snapshot.Snapshot.equal_id snapshot imported.Git.snapshot)
      | Git.Imported_transition _ | Git.Imported_tag _ | Git.Imported_revision _
      | Git.Exported_release _ | Git.Exported_revision _ ->
          Alcotest.fail "tree import did not map to a snapshot");
      let snapshot =
        Snapshot.Snapshot.load reopened imported.Git.snapshot
        |> require_ok Snapshot.error_to_string
      in
      with_directory "yeokcham-git-materialized-" (fun destination ->
          Snapshot.Materialize.write ~destination reopened snapshot
          |> require_ok Snapshot.Materialize.error_to_string;
          assert_snapshot_matches_directory reopened snapshot destination;
          Alcotest.(check string)
            "regular bytes" "regular\000bytes"
            (read_file (Filename.concat destination "regular"));
          Alcotest.(check string)
            "nested bytes" "nested\n"
            (read_file (Filename.concat destination "nested/data"));
          Alcotest.(check bool)
            "executable mode" true
            ((Unix.stat (Filename.concat destination "run")).Unix.st_perm
             land 0o111
            <> 0);
          Alcotest.(check string)
            "symlink target" "regular"
            (Unix.readlink (Filename.concat destination "link"))))

let rejects_unsafe_tree_entry_before_blob_read () =
  with_directory "yeokcham-git-unsafe-tree-" (fun repository ->
      let store_root = Filename.concat repository "store" in
      Unix.mkdir store_root 0o700;
      let store =
        Store.init ~root:store_root |> require_ok Store.error_to_string
      in
      let raw_tree = "100644 ../outside\000" ^ String.make 20 '\001' in
      let tree =
        Git.object_id_of_hex Git.Sha1 (String.make 40 '1')
        |> require_ok Git.error_to_string
      in
      recorded_commands := [];
      queued_results :=
        [
          process_result ~stdout:(stream "false\n") ();
          process_result ~stdout:(stream "sha1\n") ();
          process_result ~stdout:(stream "tree\n") ();
          process_result ~stdout:(stream raw_tree) ();
        ];
      Git.import_tree
        ~runner:(module Fake_runner)
        fake_configuration ~store ~repository ~tree
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "unsafe Git tree entry was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured unsafe path error" true
               (contains ~needle:"unsafe entry name"
                  (Git.error_to_string error)));
      Alcotest.(check int)
        "unsafe tree never reads a blob" 4
        (List.length !recorded_commands))

let rejects_unsupported_mode_and_missing_object () =
  with_directory "yeokcham-git-unsupported-tree-" (fun repository ->
      let store_root = Filename.concat repository "store" in
      Unix.mkdir store_root 0o700;
      let store =
        Store.init ~root:store_root |> require_ok Store.error_to_string
      in
      let tree =
        Git.object_id_of_hex Git.Sha1 (String.make 40 '2')
        |> require_ok Git.error_to_string
      in
      let unsupported = "160000 submodule\000" ^ String.make 20 '\002' in
      recorded_commands := [];
      queued_results :=
        [
          process_result ~stdout:(stream "false\n") ();
          process_result ~stdout:(stream "sha1\n") ();
          process_result ~stdout:(stream "tree\n") ();
          process_result ~stdout:(stream unsupported) ();
        ];
      Git.import_tree
        ~runner:(module Fake_runner)
        fake_configuration ~store ~repository ~tree
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "Gitlink tree mode was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured unsupported mode" true
               (contains ~needle:"unsupported Git tree mode"
                  (Git.error_to_string error)));
      recorded_commands := [];
      queued_results :=
        [
          process_result ~stdout:(stream "false\n") ();
          process_result ~stdout:(stream "sha1\n") ();
          process_result ~status:Validation.Failed ~exit_code:(Some 128)
            ~stderr:(stream "fatal: Not a valid object name\n")
            ();
        ];
      Git.import_tree
        ~runner:(module Fake_runner)
        fake_configuration ~store ~repository ~tree
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "missing Git tree was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured missing object" true
               (contains ~needle:"cat-file-type failed"
                  (Git.error_to_string error)));
      let symlink = "120000 link\000" ^ String.make 20 '\003' in
      recorded_commands := [];
      queued_results :=
        [
          process_result ~stdout:(stream "false\n") ();
          process_result ~stdout:(stream "sha1\n") ();
          process_result ~stdout:(stream "tree\n") ();
          process_result ~stdout:(stream symlink) ();
          process_result ~stdout:(stream "blob\n") ();
          process_result ~stdout:(stream "target\000") ();
        ];
      Git.import_tree
        ~runner:(module Fake_runner)
        fake_configuration ~store ~repository ~tree
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "NUL symlink target was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured invalid symlink target" true
               (contains ~needle:"symlink target contains NUL"
                  (Git.error_to_string error))))

let rejects_blob_limit () =
  import_fixture (fun repository store tree ->
      let configuration =
        Git.configuration_with ~max_blob_bytes:4 ~max_total_blob_bytes:4
          Git.default_configuration
      in
      Git.import_tree configuration ~store ~repository ~tree
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "oversized blob was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "bounded blob error" true
               (contains ~needle:"cat-file-blob stdout exceeded 4 bytes"
                  (Git.error_to_string error))))

let ref_inventory git repository =
  direct_capture git
    [
      "-C";
      repository;
      "for-each-ref";
      "--sort=refname";
      "--format=%(refname) %(objectname)";
    ]
  |> String.split_on_char '\n'

let archive_envelope_bytes store archive =
  let components =
    [ "git-archives"; Id.Git_archive_id.to_hex (Git.archive_id archive) ]
  in
  let binding = binding_bytes store components in
  match Encoding.decode binding with
  | Ok (Encoding.Array [ _; _; Encoding.Bytes physical; _ ]) -> (
      match Store.Stored_object_id.of_raw_bytes physical with
      | Some physical ->
          Store.get store physical
          |> require_ok Store.error_to_string
          |> Envelope.encode
      | None -> Alcotest.fail "Git archive binding object ID is invalid")
  | Ok
      ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
      | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _ | Encoding.Null )
  | Error _ ->
      Alcotest.fail "Git archive binding does not decode"

let archives_and_exits_complete_git_history () =
  commit_fixture (fun repository store _format _merge _parents ->
      let git = git_path () in
      direct_process git
        [
          "-C";
          repository;
          "tag";
          "-a";
          "archive-tag";
          "-m";
          "annotated archive tag";
        ];
      let source_refs = ref_inventory git repository in
      let first =
        Git.archive_repository Git.default_configuration ~store ~repository
        |> require_ok Git.error_to_string
      in
      let second =
        Git.archive_repository Git.default_configuration ~store ~repository
        |> require_ok Git.error_to_string
      in
      Alcotest.(check bool)
        "repeated archive has one logical ID" true
        (Id.Git_archive_id.equal (Git.archive_id first) (Git.archive_id second));
      Alcotest.(check int)
        "archive inventory retains every source ref" (List.length source_refs)
        (List.length (Git.archive_refs first));
      Alcotest.(check bool)
        "archive retains the source bare capability" false
        (match Git.archive_capability first with
        | Some capability -> capability.Git.archive_source_bare
        | None -> Alcotest.fail "new archive lost its capability report");
      let listed = Git.list_archives store |> require_ok Git.error_to_string in
      Alcotest.(check int)
        "one immutable archive is listed" 1 (List.length listed);
      let destination =
        Filename.concat (Filename.dirname repository) "exit.git"
      in
      let exited =
        Git.exit_archive Git.default_configuration ~store
          ~archive:(Git.archive_id first) ~destination
        |> require_ok Git.error_to_string
      in
      Alcotest.(check bool)
        "exit returns the archived identity" true
        (Id.Git_archive_id.equal (Git.archive_id first) (Git.archive_id exited));
      direct_process git [ "-C"; destination; "fsck"; "--full" ];
      Alcotest.(check (list string))
        "exit has the exact ref inventory" source_refs
        (ref_inventory git destination);
      let checkout = Filename.concat (Filename.dirname repository) "checkout" in
      direct_process git [ "clone"; "-q"; destination; checkout ];
      Alcotest.(check string)
        "exit preserves regular bytes" "base\n"
        (read_file (Filename.concat checkout "base"));
      Alcotest.(check string)
        "exit preserves symlink" "base"
        (Unix.readlink (Filename.concat checkout "link"));
      Alcotest.(check bool)
        "exit preserves executable mode" true
        ((Unix.stat (Filename.concat checkout "run")).Unix.st_perm land 0o111
        <> 0);
      let nonempty = Filename.concat (Filename.dirname repository) "nonempty" in
      Unix.mkdir nonempty 0o700;
      write_file (Filename.concat nonempty "keep") "keep";
      Git.exit_archive Git.default_configuration ~store
        ~archive:(Git.archive_id first) ~destination:nonempty
      |> Result.fold
           ~ok:(fun _ ->
             Alcotest.fail "nonempty Git exit destination was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "nonempty exit has a structured error" true
               (contains ~needle:"destination directory is not empty"
                  (Git.error_to_string error)));
      let components =
        [ "git-archives"; Id.Git_archive_id.to_hex (Git.archive_id first) ]
      in
      let binding = binding_bytes store components in
      Store.Ref_file.compare_and_swap store ~components ~expected:(Some binding)
        ~replacement:"corrupt"
      |> require_ok Store.error_to_string;
      Git.load_archive store (Git.archive_id first)
      |> Result.fold
           ~ok:(fun _ ->
             Alcotest.fail "corrupt Git archive binding was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "corrupt archive binding has a structured error" true
               (contains ~needle:"Git archive error"
                  (Git.error_to_string error))))

let archive_persistence_goldens_are_stable () =
  with_directory "yeokcham-git-archive-golden-" (fun root ->
      let repository = Filename.concat root "repository" in
      let store_root = Filename.concat root "store" in
      let git = git_path () in
      direct_process git [ "init"; "-q"; repository ];
      Unix.mkdir store_root 0o700;
      direct_process git
        [ "-C"; repository; "config"; "user.name"; "Yeokcham Golden" ];
      direct_process git
        [ "-C"; repository; "config"; "user.email"; "golden@example.invalid" ];
      write_file (Filename.concat repository "archive") "golden archive\n";
      direct_process git [ "-C"; repository; "add"; "--all" ];
      direct_process_with_environment git golden_commit_environment
        [ "-C"; repository; "commit"; "-q"; "-m"; "archive golden" ];
      direct_process_with_environment git golden_commit_environment
        [
          "-C";
          repository;
          "tag";
          "-a";
          "archive-golden";
          "-m";
          "archive golden tag";
        ];
      let store =
        Store.init ~root:store_root |> require_ok Store.error_to_string
      in
      let archive =
        Git.archive_repository Git.default_configuration ~store ~repository
        |> require_ok Git.error_to_string
      in
      let archive_id = Git.archive_id archive in
      Alcotest.(check string)
        "canonical Git archive envelope"
        (refreshed_golden "git-archive-v2.yeok.hex"
           (archive_envelope_bytes store archive))
        (archive_envelope_bytes store archive);
      Alcotest.(check string)
        "canonical Git archive binding"
        (refreshed_golden "git-archive-v2.ref.hex"
           (binding_bytes store
              [ "git-archives"; Id.Git_archive_id.to_hex archive_id ]))
        (binding_bytes store
           [ "git-archives"; Id.Git_archive_id.to_hex archive_id ]);
      let legacy_envelope =
        golden_bytes "git-archive-v1.yeok.hex"
        |> Envelope.decode
        |> require_ok Envelope.decode_error_to_string
      in
      let legacy_physical =
        Store.put store legacy_envelope |> require_ok Store.error_to_string
      in
      let legacy_binding = golden_bytes "git-archive-v1.ref.hex" in
      let legacy_id =
        match Encoding.decode legacy_binding with
        | Ok
            (Encoding.Array [ _; Encoding.Bytes id; Encoding.Bytes physical; _ ])
          ->
            let id =
              Id.Git_archive_id.of_bytes id
              |> require_ok Id.parse_error_to_string
            in
            let physical =
              match Store.Stored_object_id.of_raw_bytes physical with
              | Some physical -> physical
              | None ->
                  Alcotest.fail
                    "legacy archive binding has an invalid object ID"
            in
            Alcotest.(check bool)
              "legacy binding names the fixture envelope" true
              (Store.Stored_object_id.equal physical legacy_physical);
            id
        | Ok
            ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
            | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _
            | Encoding.Null )
        | Error _ ->
            Alcotest.fail "legacy archive binding does not decode"
      in
      Store.Ref_file.compare_and_swap store
        ~components:[ "git-archives"; Id.Git_archive_id.to_hex legacy_id ]
        ~expected:None ~replacement:legacy_binding
      |> require_ok Store.error_to_string;
      let legacy =
        Git.load_archive store legacy_id |> require_ok Git.error_to_string
      in
      Alcotest.(check (option bool))
        "V1 archive retains no invented capability report" None
        (Git.archive_capability legacy
        |> Option.map (fun capability -> capability.Git.archive_source_bare)))

let shallow_archive_rejects_before_publication () =
  commit_fixture (fun repository store _format _merge _parents ->
      let shallow = Filename.concat (Filename.dirname repository) "shallow" in
      let git = git_path () in
      direct_process git
        [ "clone"; "-q"; "--depth"; "1"; "file://" ^ repository; shallow ];
      Git.archive_repository Git.default_configuration ~store
        ~repository:shallow
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "shallow Git repository was archived")
           ~error:(fun error ->
             Alcotest.(check bool)
               "shallow archive has a structured error" true
               (contains ~needle:"shallow Git repositories are not archivable"
                  (Git.error_to_string error)));
      Alcotest.(check int)
        "shallow rejection publishes no archive" 0
        (List.length
           (Git.list_archives store |> require_ok Git.error_to_string)))

let archive_selection_is_exact_and_rejects_before_publication () =
  commit_fixture (fun repository store _format _merge _parents ->
      let git = git_path () in
      direct_process git [ "-C"; repository; "tag"; "selected-ref"; "HEAD" ];
      let selected_ref = "refs/tags/selected-ref" in
      let archive =
        Git.archive_repository ~refs:[ selected_ref ] Git.default_configuration
          ~store ~repository
        |> require_ok Git.error_to_string
      in
      Alcotest.(check (list string))
        "only the selected ref is retained" [ selected_ref ]
        (Git.archive_refs archive
        |> List.map (fun reference -> reference.Git.archive_ref_name));
      let destination =
        Filename.concat (Filename.dirname repository) "selected.git"
      in
      Git.exit_archive Git.default_configuration ~store
        ~archive:(Git.archive_id archive) ~destination
      |> require_ok Git.error_to_string
      |> ignore;
      Alcotest.(check (list string))
        "exit contains only the selected ref" [ selected_ref ]
        (ref_inventory git destination
        |> List.map (fun line ->
            match String.split_on_char ' ' line with
            | name :: _ -> name
            | [] -> Alcotest.fail "Git ref inventory line was empty"));
      let empty_store_root =
        Filename.concat (Filename.dirname repository) "empty-store"
      in
      Unix.mkdir empty_store_root 0o700;
      let empty_store =
        Store.init ~root:empty_store_root |> require_ok Store.error_to_string
      in
      Git.archive_repository ~refs:[ "refs/heads/absent" ]
        Git.default_configuration ~store:empty_store ~repository
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "absent selected Git ref was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "absent selected ref has a structured error" true
               (contains ~needle:"requested Git ref is absent"
                  (Git.error_to_string error)));
      Git.archive_repository
        ~refs:[ selected_ref; selected_ref ]
        Git.default_configuration ~store:empty_store ~repository
      |> Result.fold
           ~ok:(fun _ ->
             Alcotest.fail "duplicate selected Git ref was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "duplicate selected ref has a structured error" true
               (contains ~needle:"requested Git ref name is duplicated"
                  (Git.error_to_string error)));
      Alcotest.(check int)
        "selection failures publish no archive" 0
        (List.length
           (Git.list_archives empty_store |> require_ok Git.error_to_string)))

let detached_adoption_checkpoints store ~source ~target =
  let source_checkpoint =
    Scratch.Checkpoint.create_initial ~snapshot:source ~created_at:0L
  in
  let source =
    Scratch.Checkpoint.store store source_checkpoint
    |> require_ok Scratch.error_to_string
  in
  let source_snapshot =
    Snapshot.Snapshot.load store (Scratch.Checkpoint.snapshot source_checkpoint)
    |> require_ok Snapshot.error_to_string
  in
  let target_snapshot =
    Snapshot.Snapshot.load store target |> require_ok Snapshot.error_to_string
  in
  let source_state =
    Scratch.State.of_snapshot store source_snapshot
    |> require_ok Scratch.error_to_string
  in
  let target_state =
    Scratch.State.of_snapshot store target_snapshot
    |> require_ok Scratch.error_to_string
  in
  let operations = Scratch.State.diff ~from:source_state ~to_:target_state in
  let replayed =
    Scratch.State.apply source_state operations
    |> require_ok Scratch.error_to_string
  in
  Alcotest.(check bool)
    "adoption checkpoint replay is exact" true
    (Scratch.State.equal replayed target_state);
  let event =
    Scratch.Event.create ~parent:source
      ~base:(Scratch.Checkpoint.snapshot source_checkpoint)
      ~resulting:target ~operations ~source:Scratch.Explicit ~observed_at:0L
  in
  let event =
    Scratch.Event.store store event |> require_ok Scratch.error_to_string
  in
  let target =
    Scratch.Checkpoint.create ~parent:source ~event ~snapshot:target
      ~created_at:0L
    |> Scratch.Checkpoint.store store
    |> require_ok Scratch.error_to_string
  in
  (source, target)

let archive_adoption_is_explicit_and_durable () =
  commit_fixture (fun repository store format commit parents ->
      let archive =
        Git.archive_repository Git.default_configuration ~store ~repository
        |> require_ok Git.error_to_string
      in
      let imported =
        Git.import_archive_commit Git.default_configuration ~store
          ~archive:(Git.archive_id archive) ~commit
        |> require_ok Git.error_to_string
      in
      let parent =
        match parents with
        | parent :: _ ->
            Git.object_id_of_hex format parent |> require_ok Git.error_to_string
        | [] -> Alcotest.fail "merge fixture did not provide a parent"
      in
      let imported_parent =
        Git.import_archive_commit Git.default_configuration ~store
          ~archive:(Git.archive_id archive) ~commit:parent
        |> require_ok Git.error_to_string
      in
      let source, target =
        detached_adoption_checkpoints store
          ~source:
            (Git.imported_transition_snapshot
               imported_parent.Git.imported_transition)
          ~target:
            (Git.imported_transition_snapshot imported.Git.imported_transition)
      in
      let capsule = export_capsule_id 91 in
      let scratch = Scratch.open_repository store in
      let resolved =
        Capsule_store.Durable.create_from_checkpoints ~store ~scratch
          ~id:capsule ~title:"adopted Git change"
          ~description:"chosen merge parent delta" ~dependencies:[] ~evidence:[]
          ~from:source ~target ~created_at:0L ~changed_at:0L ()
        |> require_ok Capsule_store.error_to_string
      in
      let revision =
        Capsule_store.Durable.resolved_revision resolved
        |> Capsule_store.revision_id
      in
      let adoption =
        Git.record_archive_adoption store ~archive:(Git.archive_id archive)
          ~commit ~parent:(Some parent)
          ~transition:imported.Git.imported_transition
          ~mapping:imported.Git.commit_mapping
          ~parent_transition:(Some imported_parent.Git.imported_transition)
          ~parent_mapping:(Some imported_parent.Git.commit_mapping) ~capsule
          ~revision ~source ~target
        |> require_ok Git.error_to_string
      in
      let reopened =
        Git.load_adoption store (Git.adoption_id adoption)
        |> require_ok Git.error_to_string
      in
      Alcotest.(check bool)
        "adoption retains its archive" true
        (Id.Git_archive_id.equal
           (Git.adoption_archive reopened)
           (Git.archive_id archive));
      Alcotest.(check string)
        "adoption retains selected commit"
        (Git.object_id_to_hex commit)
        (Git.object_id_to_hex (Git.adoption_commit reopened));
      Alcotest.(check string)
        "adoption retains selected parent"
        (Git.object_id_to_hex parent)
        (match Git.adoption_parent reopened with
        | Some parent -> Git.object_id_to_hex parent
        | None -> Alcotest.fail "adoption lost selected parent");
      Git.record_archive_adoption store ~archive:(Git.archive_id archive)
        ~commit ~parent:None ~transition:imported.Git.imported_transition
        ~mapping:imported.Git.commit_mapping ~parent_transition:None
        ~parent_mapping:None ~capsule ~revision ~source ~target
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "merge adoption accepted no parent")
           ~error:(fun error ->
             Alcotest.(check bool)
               "missing merge parent has a structured error" true
               (contains
                  ~needle:"non-root adoption must name one direct Git parent"
                  (Git.error_to_string error)));
      let components =
        [
          "git-adoptions"; Id.Git_adoption_id.to_hex (Git.adoption_id adoption);
        ]
      in
      let binding = binding_bytes store components in
      Store.Ref_file.compare_and_swap store ~components ~expected:(Some binding)
        ~replacement:"corrupt"
      |> require_ok Store.error_to_string;
      Git.load_adoption store (Git.adoption_id adoption)
      |> Result.fold
           ~ok:(fun _ -> Alcotest.fail "corrupt adoption binding was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "corrupt adoption has a structured error" true
               (contains ~needle:"Git adoption error"
                  (Git.error_to_string error))))

let rejects_corrupt_mapping_binding () =
  import_fixture (fun repository store tree ->
      let imported =
        Git.import_tree Git.default_configuration ~store ~repository ~tree
        |> require_ok Git.error_to_string
      in
      let mapping = Git.mapping_id imported.Git.mapping in
      let components = [ "git-mappings"; Id.Git_mapping_id.to_hex mapping ] in
      let existing =
        Store.Ref_file.read store ~components
        |> require_ok Store.error_to_string
      in
      (match existing with
      | Some bytes ->
          Store.Ref_file.compare_and_swap store ~components
            ~expected:(Some bytes) ~replacement:"corrupt"
          |> require_ok Store.error_to_string
      | None -> Alcotest.fail "Git mapping binding was not written");
      Git.load_mapping store mapping
      |> Result.fold
           ~ok:(fun _ ->
             Alcotest.fail "corrupt Git mapping binding was accepted")
           ~error:(fun error ->
             Alcotest.(check bool)
               "structured corrupt binding error" true
               (contains ~needle:"Git mapping error"
                  (Git.error_to_string error))))

let () =
  Alcotest.run "yeokcham_git"
    [
      ( "preflight",
        [
          Alcotest.test_case "direct argv and bounded configuration" `Quick
            preflight_uses_bounded_direct_argv;
          Alcotest.test_case "unsafe path does not execute" `Quick
            rejects_untrusted_path_before_execution;
          Alcotest.test_case "malformed and truncated output reject" `Quick
            malformed_or_truncated_output_rejects;
          Alcotest.test_case "local Git repository preflight" `Quick
            actual_git_repository_is_inspected;
          Alcotest.test_case "exact tree import survives restart" `Quick
            imports_exact_tree_and_restarts_idempotently;
          Alcotest.test_case "release export checkout is exact" `Quick
            exports_release_as_exact_git_commit;
          Alcotest.test_case
            "configured release export metadata is exact and idempotent" `Quick
            exports_configured_release_metadata_exactly_and_idempotently;
          Alcotest.test_case
            "configured release metadata rejects and retries explicitly" `Quick
            configured_release_metadata_rejects_and_retries_explicitly;
          Alcotest.test_case "revision export is an exact linear chain" `Quick
            exports_revisions_as_exact_linear_git_commits;
          Alcotest.test_case "revision export rejects and retries explicitly"
            `Quick
            revision_export_rejects_invalid_selection_and_recovers_partial_mapping;
          Alcotest.test_case
            "revision export handles empty roots and rejects nested empty \
             directories"
            `Quick exports_empty_root_revision_and_rejects_nested_empty_revision;
          Alcotest.test_case "empty release export has deterministic fallback"
            `Quick exports_empty_release_with_fallback_message;
          Alcotest.test_case "release export ref collision and bounds reject"
            `Quick export_ref_collision_and_bounds_reject_explicitly;
          Alcotest.test_case "negative release timestamp rejects" `Quick
            negative_release_timestamp_rejects_before_export;
          Alcotest.test_case "release export interruption retries explicitly"
            `Quick export_interruption_is_explicit_and_retryable;
          Alcotest.test_case "nested empty directories reject before export"
            `Quick nested_empty_directory_rejects_before_export_ref;
          Alcotest.test_case "merge commit import preserves parent order" `Quick
            imports_merge_commit_and_ordered_parents;
          Alcotest.test_case
            "complete repository import retains bridge evidence" `Quick
            imports_complete_existing_repository;
          Alcotest.test_case "commit metadata retains exact source bytes" `Quick
            imports_commit_metadata_as_exact_bytes;
          Alcotest.test_case "lightweight and annotated tags retain provenance"
            `Quick imports_lightweight_and_annotated_tags;
          Alcotest.test_case "imported transition schemas have stable goldens"
            `Quick imported_transition_persistence_goldens_are_stable;
          Alcotest.test_case "imported tag schemas have stable goldens" `Quick
            imported_tag_persistence_goldens_are_stable;
          Alcotest.test_case "malformed tag data rejects" `Quick
            rejects_malformed_tag_data;
          Alcotest.test_case "malformed commit data rejects" `Quick
            rejects_malformed_commit_data;
          Alcotest.test_case "corrupt transition binding rejects" `Quick
            rejects_corrupt_transition_binding;
          Alcotest.test_case "missing transition message rejects" `Quick
            rejects_missing_transition_message_content;
          Alcotest.test_case "corrupt tag binding rejects" `Quick
            rejects_corrupt_tag_binding;
          Alcotest.test_case "unsafe tree entry rejects before blob read" `Quick
            rejects_unsafe_tree_entry_before_blob_read;
          Alcotest.test_case "unsupported mode and missing object reject" `Quick
            rejects_unsupported_mode_and_missing_object;
          Alcotest.test_case "blob bound rejects" `Quick rejects_blob_limit;
          Alcotest.test_case "archive preserves and exits complete Git history"
            `Quick archives_and_exits_complete_git_history;
          Alcotest.test_case "Git archive schemas have stable goldens" `Quick
            archive_persistence_goldens_are_stable;
          Alcotest.test_case "shallow archive rejects before publication" `Quick
            shallow_archive_rejects_before_publication;
          Alcotest.test_case
            "archive selection is exact and rejects before publication" `Quick
            archive_selection_is_exact_and_rejects_before_publication;
          Alcotest.test_case "archive adoption is explicit and durable" `Quick
            archive_adoption_is_explicit_and_durable;
          Alcotest.test_case "corrupt mapping binding rejects" `Quick
            rejects_corrupt_mapping_binding;
        ] );
    ]
