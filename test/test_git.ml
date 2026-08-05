module Git = Paengi_git
module Capsule_store = Paengi_capsule_store
module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Golden = Paengi_testkit.Golden_fixture
module Id = Paengi_id
module Release = Paengi_release
module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store
module Validation = Paengi_validation
module Workspace_store = Paengi_workspace_store

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

let store_golden_envelope store name =
  let envelope =
    Envelope.decode (golden name) |> require_ok Envelope.decode_error_to_string
  in
  Store.put store envelope |> require_ok Store.error_to_string

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
  commit_environment ~author_name:"Paengi Golden"
    ~author_email:"golden@example.invalid" ~author_date:"1700000000 +0000"
    ~committer_name:"Paengi Golden" ~committer_email:"golden@example.invalid"
    ~committer_date:"1700000000 +0000"

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

let commit_fixture run =
  with_directory "paengi-git-commit-" (fun root ->
      let repository = Filename.concat root "repository" in
      let store_root = Filename.concat root "store" in
      Unix.mkdir repository 0o700;
      Unix.mkdir store_root 0o700;
      let git = git_path () in
      direct_process git [ "init"; "-q"; repository ];
      direct_process git
        [ "-C"; repository; "config"; "user.name"; "Paengi Test" ];
      direct_process git
        [ "-C"; repository; "config"; "user.email"; "test@example.invalid" ];
      write_file (Filename.concat repository "base") "base\n";
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
  with_directory "paengi-git-tag-" (fun root ->
      let repository = Filename.concat root "repository" in
      let store_root = Filename.concat root "store" in
      Unix.mkdir repository 0o700;
      Unix.mkdir store_root 0o700;
      let git = git_path () in
      direct_process git [ "init"; "-q"; repository ];
      direct_process git
        [ "-C"; repository; "config"; "user.name"; "Paengi Test" ];
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
      with_directory "paengi-git-commit-materialized-" (fun destination ->
          Snapshot.Materialize.write ~destination reopened snapshot
          |> require_ok Snapshot.Materialize.error_to_string;
          Alcotest.(check string)
            "base bytes" "base\n"
            (read_file (Filename.concat destination "base"));
          Alcotest.(check string)
            "main bytes" "main\n"
            (read_file (Filename.concat destination "main"));
          Alcotest.(check string)
            "side bytes" "side\n"
            (read_file (Filename.concat destination "side"))))

let imports_commit_metadata_as_exact_bytes () =
  with_directory "paengi-git-commit-metadata-" (fun root ->
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
  with_directory "paengi-git-tag-errors-" (fun repository ->
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
  with_directory "paengi-git-transition-golden-" (fun root ->
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
        "Paengi Golden <golden@example.invalid> 1700000000 +0000"
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
        (golden "git-imported-transition-v2.peng.hex")
        (imported_transition_envelope_bytes store transition_id);
      Alcotest.(check string)
        "canonical imported transition binding"
        (golden "git-imported-transition-v2.ref.hex")
        (binding_bytes store
           [
             "imported-transitions";
             Id.Imported_transition_id.to_hex transition_id;
           ]);
      Alcotest.(check string)
        "canonical Git commit mapping v3 envelope"
        (golden "git-commit-mapping-v3.peng.hex")
        (mapping_envelope_bytes store mapping_id);
      Alcotest.(check string)
        "canonical Git commit mapping v3 binding"
        (golden "git-commit-mapping-v3.ref.hex")
        (binding_bytes store
           [ "git-mappings"; Id.Git_mapping_id.to_hex mapping_id ]);
      let legacy_transition_binding =
        golden "git-imported-transition-v1.ref.hex"
      in
      let legacy_transition =
        match Encoding.decode legacy_transition_binding with
        | Ok
            (Encoding.Array [ _; Encoding.Bytes identity; Encoding.Bytes _; _ ])
          ->
            Id.Imported_transition_id.of_bytes identity
            |> require_ok Id.parse_error_to_string
        | Ok
            ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
            | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _
            | Encoding.Null )
        | Error _ ->
            Alcotest.fail "legacy transition binding is malformed"
      in
      ignore (store_golden_envelope store "git-imported-transition-v1.peng.hex");
      Store.Ref_file.compare_and_swap store
        ~components:
          [
            "imported-transitions";
            Id.Imported_transition_id.to_hex legacy_transition;
          ]
        ~expected:None ~replacement:legacy_transition_binding
      |> require_ok Store.error_to_string;
      let loaded_legacy =
        Git.load_imported_transition store legacy_transition
        |> require_ok Git.error_to_string
      in
      Alcotest.(check (option string))
        "v1 transition has no synthetic author" None
        (Git.imported_transition_author loaded_legacy);
      Alcotest.(check bool)
        "v1 transition has no synthetic message" true
        (Option.is_none (Git.imported_transition_message loaded_legacy));
      let legacy_mapping_binding = golden "git-mapping-v2.ref.hex" in
      let legacy_mapping =
        match Encoding.decode legacy_mapping_binding with
        | Ok
            (Encoding.Array [ _; Encoding.Bytes identity; Encoding.Bytes _; _ ])
          ->
            Id.Git_mapping_id.of_bytes identity
            |> require_ok Id.parse_error_to_string
        | Ok
            ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
            | Encoding.Array _ | Encoding.Map _ | Encoding.Bool _
            | Encoding.Null )
        | Error _ ->
            Alcotest.fail "legacy mapping binding is malformed"
      in
      ignore (store_golden_envelope store "git-mapping-v2.peng.hex");
      Store.Ref_file.compare_and_swap store
        ~components:[ "git-mappings"; Id.Git_mapping_id.to_hex legacy_mapping ]
        ~expected:None ~replacement:legacy_mapping_binding
      |> require_ok Store.error_to_string;
      match
        Git.load_mapping store legacy_mapping |> require_ok Git.error_to_string
      with
      | mapping ->
          Alcotest.(check bool)
            "legacy mapping retains transition subject" true
            (match Git.mapping_subject mapping with
            | Git.Imported_transition { transition; _ } ->
                Id.Imported_transition_id.equal transition legacy_transition
            | Git.Imported_snapshot _ | Git.Imported_tag _
            | Git.Imported_revision _ | Git.Exported_release _
            | Git.Exported_revision _ ->
                false))

let imported_tag_persistence_goldens_are_stable () =
  with_directory "paengi-git-tag-golden-" (fun root ->
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
        (golden "git-imported-tag-v1.peng.hex")
        (imported_tag_envelope_bytes store tag_id);
      Alcotest.(check string)
        "canonical imported tag binding"
        (golden "git-imported-tag-v1.ref.hex")
        (binding_bytes store
           [ "imported-tags"; Id.Imported_tag_id.to_hex tag_id ]);
      Alcotest.(check string)
        "canonical Git mapping v3 envelope"
        (golden "git-mapping-v3.peng.hex")
        (mapping_envelope_bytes store mapping_id);
      Alcotest.(check string)
        "canonical Git mapping v3 binding"
        (golden "git-mapping-v3.ref.hex")
        (binding_bytes store
           [ "git-mappings"; Id.Git_mapping_id.to_hex mapping_id ]))

let rejects_malformed_commit_data () =
  with_directory "paengi-git-commit-errors-" (fun repository ->
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
  with_directory "paengi-git-export-" (fun root ->
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
            "--format=%an <%ae> %at %z%x00%cn <%ce> %ct %cz%x00%B";
            Git.object_id_to_hex first.Git.export_commit;
          ]
      in
      Alcotest.(check bool)
        "fixed author metadata" true
        (contains ~needle:"Paengi Export <noreply@paengi.local> 7" commit);
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
        ("Paengi release " ^ Id.Release_id.to_hex (Release.release_id release))
        message)

let export_ref_collision_and_bounds_reject_explicitly () =
  release_export_fixture (fun git destination store release ->
      direct_process git
        [ "-C"; destination; "config"; "user.name"; "Paengi Fixture" ];
      direct_process git
        [ "-C"; destination; "config"; "user.email"; "fixture@example.invalid" ];
      direct_process git
        [ "-C"; destination; "commit"; "--allow-empty"; "-q"; "-m"; "existing" ];
      let existing =
        direct_capture git [ "-C"; destination; "rev-parse"; "HEAD" ]
      in
      let target_ref =
        "refs/heads/paengi/release-"
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
      with_directory "paengi-git-export-bounded-" (fun bounded ->
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
        "refs/heads/paengi/release-" ^ Id.Release_id.to_hex release_id
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
             "refs/heads/paengi/release-" ^ Id.Release_id.to_hex release_id;
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
        (golden "git-mapping-v1.peng.hex")
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
          Alcotest.test_case "release export checkout is exact" `Quick
            exports_release_as_exact_git_commit;
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
          Alcotest.test_case "corrupt mapping binding rejects" `Quick
            rejects_corrupt_mapping_binding;
        ] );
    ]
