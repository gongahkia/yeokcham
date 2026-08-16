module Progress = Yeokcham_cli_progress

let read_all descriptor =
  let buffer = Buffer.create 128 in
  let bytes = Bytes.create 128 in
  let rec loop () =
    match Unix.read descriptor bytes 0 (Bytes.length bytes) with
    | 0 -> Buffer.contents buffer
    | count ->
        Buffer.add_string buffer (Bytes.sub_string bytes 0 count);
        loop ()
  in
  loop ()

let capture_stderr callback =
  flush stderr;
  let original = Unix.dup Unix.stderr in
  let reader, writer = Unix.pipe () in
  Unix.dup2 writer Unix.stderr;
  Unix.close writer;
  let restored = ref false in
  let restore () =
    if not !restored then (
      flush stderr;
      Unix.dup2 original Unix.stderr;
      Unix.close original;
      restored := true)
  in
  let result = Fun.protect callback ~finally:restore in
  let output = read_all reader in
  Unix.close reader;
  (result, output)

let test_default_spinner_sequence () =
  Alcotest.(check string) "first frame" "⠁" (Progress.spinner_frame 0);
  Alcotest.(check string) "repeated first frame" "⠁"
    (Progress.spinner_frame 1);
  Alcotest.(check string) "last frame clears" " "
    (Progress.spinner_frame (List.length Progress.spinner_frames - 1));
  Alcotest.(check string) "sequence wraps" "⠁"
    (Progress.spinner_frame (List.length Progress.spinner_frames))

let test_default_template () =
  Alcotest.(check string) "spinner and message" "⠁ Restoring checkpoint"
    (Progress.render_line ~tick:0 ~message:"Restoring checkpoint");
  Alcotest.(check string) "clear line" "\r\027[2K" Progress.clear_sequence;
  Alcotest.check (Alcotest.float 0.0001) "20 Hz" 0.05
    Progress.refresh_interval_seconds

let test_visibility_policy () =
  let check name expected ~no_progress ~stderr_isatty ~environment =
    Alcotest.(check bool) name expected
      (Progress.should_render ~no_progress ~stderr_isatty ~environment)
  in
  check "interactive by default" true ~no_progress:false ~stderr_isatty:true
    ~environment:None;
  check "flag disables" false ~no_progress:true ~stderr_isatty:true
    ~environment:None;
  check "environment disables" false ~no_progress:false ~stderr_isatty:true
    ~environment:(Some "1");
  check "non-TTY disables" false ~no_progress:false ~stderr_isatty:false
    ~environment:None;
  check "other environment value preserves progress" true ~no_progress:false
    ~stderr_isatty:true ~environment:(Some "0")

let test_disabled_progress_runs_the_callback () =
  let invoked = ref false in
  let result =
    Progress.with_progress ~enabled:false "must not render" (fun () ->
        invoked := true;
        42)
  in
  Alcotest.(check bool) "callback invoked" true !invoked;
  Alcotest.(check int) "callback result" 42 result

let test_spinner_draws_and_clears () =
  let (), output =
    capture_stderr (fun () ->
        Progress.with_progress ~enabled:true "Applying update" (fun () ->
            ignore (Unix.select [] [] [] 0.06)))
  in
  Alcotest.(check bool) "first draw uses the default template" true
    (String.starts_with ~prefix:(Progress.clear_sequence ^ "⠁ Applying update")
       output);
  Alcotest.(check bool) "completion clears the line" true
    (String.ends_with ~suffix:Progress.clear_sequence output)

let test_disabled_progress_does_not_draw () =
  let (), output =
    capture_stderr (fun () ->
        Progress.with_progress ~enabled:false "must not render" (fun () -> ()))
  in
  Alcotest.(check string) "no terminal bytes" "" output

let () =
  Alcotest.run "CLI progress"
    [
      ( "uv-compatible spinner",
        [
          Alcotest.test_case "uses the default frame sequence" `Quick
            test_default_spinner_sequence;
          Alcotest.test_case "uses the default template and clearing" `Quick
            test_default_template;
        ] );
      ( "visibility",
        [
          Alcotest.test_case "requires an interactive, enabled terminal" `Quick
            test_visibility_policy;
          Alcotest.test_case "disabled progress is transparent" `Quick
            test_disabled_progress_runs_the_callback;
          Alcotest.test_case "enabled progress draws and clears stderr" `Slow
            test_spinner_draws_and_clears;
          Alcotest.test_case "disabled progress does not draw stderr" `Quick
            test_disabled_progress_does_not_draw;
        ] );
    ]
