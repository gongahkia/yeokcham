module Hook = Yeokcham_v4_hook
module Runner = Yeokcham_v4_hook_runner

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

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
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let write_script root name body =
  let path = Filename.concat root name in
  Out_channel.with_open_bin path (fun output ->
      Out_channel.output_string output ("#!/bin/sh\n" ^ body));
  Unix.chmod path 0o700;
  path

let event () =
  Runner.make_event ~event:Hook.Save ~command:"save"
    ~repository:(Some "repository-public-id") ~paths:[ "src/main.ml" ]
    ~identifiers:[ ("checkpoint", "checkpoint-public-id") ]
  |> require_ok Fun.id

let hook argv =
  Hook.make ~event:Hook.Save ~argv |> require_ok Hook.error_to_string

let argv_launch_is_redacted_and_preserves_arguments () =
  with_directory "v4-hook-runner-" (fun root ->
      let script =
        write_script root "observe"
          "if [ \"$1\" != 'with spaces' ] || [ \"$2\" != 'quote\"value' ]; \
           then exit 9; fi\n\
           if [ -n \"${YEOKCHAM_HOOK_TEST_SECRET+x}\" ]; then exit 8; fi\n\
           IFS= read -r event\n\
           case \"$event\" in *'\"event\":\"save\"'*) exit 0 ;; *) exit 7 ;; \
           esac\n"
      in
      Unix.putenv "YEOKCHAM_HOOK_TEST_SECRET" "must-not-reach-hook";
      let result =
        Runner.invoke ~timeout_seconds:1 (event ())
          (hook [ script; "with spaces"; "quote\"value" ])
      in
      Alcotest.(check (option string))
        "argv launch succeeds without inherited secret" None
        (Option.map Runner.warning_to_string result))

let failures_are_warnings_and_events_reject_secrets () =
  with_directory "v4-hook-runner-failure-" (fun root ->
      let nonzero = write_script root "nonzero" "exit 7\n" in
      let output = write_script root "output" "printf unexpected\n" in
      let sleeper = write_script root "sleeper" "sleep 2\n" in
      let signalled = write_script root "signalled" "kill -TERM $$\n" in
      let nonzero_result =
        Runner.invoke ~timeout_seconds:1 (event ()) (hook [ nonzero ])
      in
      let output_result =
        Runner.invoke ~timeout_seconds:1 (event ()) (hook [ output ])
      in
      let timeout_result =
        Runner.invoke ~timeout_seconds:1 (event ()) (hook [ sleeper ])
      in
      let signalled_result =
        Runner.invoke ~timeout_seconds:1 (event ()) (hook [ signalled ])
      in
      let missing_result =
        Runner.invoke ~timeout_seconds:1 (event ())
          (hook [ Filename.concat root "missing" ])
      in
      Alcotest.(check bool)
        "nonzero is a warning" true
        (Option.is_some nonzero_result);
      Alcotest.(check bool)
        "observer output is a warning" true
        (Option.is_some output_result);
      Alcotest.(check bool)
        "timeout is a warning" true
        (Option.is_some timeout_result);
      Alcotest.(check bool)
        "signal is a warning" true
        (Option.is_some signalled_result);
      Alcotest.(check bool)
        "missing executable is a warning" true
        (Option.is_some missing_result);
      Alcotest.(check bool)
        "secret-shaped identifier rejects" true
        (Result.is_error
           (Runner.make_event ~event:Hook.Save ~command:"save" ~repository:None
              ~paths:[]
              ~identifiers:[ ("token", "secret") ])))

let () =
  Alcotest.run "V4 hook runner"
    [
      ( "observer boundary",
        [
          Alcotest.test_case "argv launch is redacted and exact" `Quick
            argv_launch_is_redacted_and_preserves_arguments;
          Alcotest.test_case "failures stay warnings and secrets reject" `Quick
            failures_are_warnings_and_events_reject_secrets;
        ] );
    ]
