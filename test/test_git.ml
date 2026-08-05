module Git = Paengi_git
module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Golden = Paengi_testkit.Golden_fixture
module Id = Paengi_id
module Snapshot = Paengi_snapshot
module Store = Paengi_store
module Validation = Paengi_validation

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

let golden name =
  let paths =
    [ Filename.concat "golden" name; Filename.concat "test/golden" name ]
  in
  match List.find_opt Sys.file_exists paths with
  | Some path -> Golden.read_lower_hex_file path |> require_ok Fun.id
  | None -> Alcotest.fail ("missing golden fixture: " ^ name)

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

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let read_file path = In_channel.with_open_bin path In_channel.input_all

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
  with_directory "paengi-git-fake-" (fun repository ->
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
  with_directory "paengi-git-output-" (fun repository ->
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
  with_directory "paengi-git-fixture-" (fun repository ->
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
  with_directory "paengi-git-import-" (fun root ->
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
        (golden "git-mapping-v1.peng.hex")
        mapping_bytes;
      (match Git.mapping_subject mapping with
      | Git.Imported_snapshot snapshot ->
          Alcotest.(check bool)
            "mapping points to imported snapshot" true
            (Snapshot.Snapshot.equal_id snapshot imported.Git.snapshot)
      | Git.Imported_revision _ | Git.Exported_release _
      | Git.Exported_revision _ ->
          Alcotest.fail "tree import did not map to a snapshot");
      let snapshot =
        Snapshot.Snapshot.load reopened imported.Git.snapshot
        |> require_ok Snapshot.error_to_string
      in
      with_directory "paengi-git-materialized-" (fun destination ->
          Snapshot.Materialize.write ~destination reopened snapshot
          |> require_ok Snapshot.Materialize.error_to_string;
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
  with_directory "paengi-git-unsafe-tree-" (fun repository ->
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
        "unsafe tree never reads a blob" 3
        (List.length !recorded_commands))

let rejects_unsupported_mode_and_missing_object () =
  with_directory "paengi-git-unsupported-tree-" (fun repository ->
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
               (contains ~needle:"cat-file-tree failed"
                  (Git.error_to_string error)));
      let symlink = "120000 link\000" ^ String.make 20 '\003' in
      recorded_commands := [];
      queued_results :=
        [
          process_result ~stdout:(stream "false\n") ();
          process_result ~stdout:(stream "sha1\n") ();
          process_result ~stdout:(stream symlink) ();
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
  Alcotest.run "paengi_git"
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
          Alcotest.test_case "unsafe tree entry rejects before blob read" `Quick
            rejects_unsafe_tree_entry_before_blob_read;
          Alcotest.test_case "unsupported mode and missing object reject" `Quick
            rejects_unsupported_mode_and_missing_object;
          Alcotest.test_case "blob bound rejects" `Quick rejects_blob_limit;
          Alcotest.test_case "corrupt mapping binding rejects" `Quick
            rejects_corrupt_mapping_binding;
        ] );
    ]
