module Git = Paengi_git
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
        ] );
    ]
