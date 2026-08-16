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

let contains text fragment =
  let text_length = String.length text in
  let fragment_length = String.length fragment in
  let rec search index =
    if index + fragment_length > text_length then false
    else if String.sub text index fragment_length = fragment then true
    else search (index + 1)
  in
  search 0

let test_default_spinner_sequence () =
  Alcotest.(check string) "first frame" "⠁" (Progress.spinner_frame 0);
  Alcotest.(check string) "repeated first frame" "⠁" (Progress.spinner_frame 1);
  Alcotest.(check string)
    "last frame clears" " "
    (Progress.spinner_frame (List.length Progress.spinner_frames - 1));
  Alcotest.(check string)
    "sequence wraps" "⠁"
    (Progress.spinner_frame (List.length Progress.spinner_frames))

let test_default_template () =
  Alcotest.(check string)
    "spinner and message" "⠁ Restoring checkpoint"
    (Progress.render_line ~tick:0 ~message:"Restoring checkpoint");
  Alcotest.(check string) "clear line" "\r\027[2K" Progress.clear_sequence;
  Alcotest.check (Alcotest.float 0.0001) "20 Hz" 0.05
    Progress.refresh_interval_seconds

let test_default_bar_template () =
  Alcotest.(check int)
    "fallback width" 20
    (Progress.bar_width ~columns:None ~message:"Restoring" ~completed:0 ~total:4);
  Alcotest.(check int)
    "terminal width" 23
    (Progress.bar_width ~columns:(Some 40) ~message:"Restoring" ~completed:2
       ~total:4);
  Alcotest.(check string)
    "half complete" "Restoring [██████████░░░░░░░░░░] 2/4"
    (Progress.render_bar ~columns:None ~message:"Restoring" ~completed:2
       ~total:4);
  Alcotest.(check string)
    "clamped complete" "Restoring [████████████████████] 4/4"
    (Progress.render_bar ~columns:None ~message:"Restoring" ~completed:9
       ~total:4)

let test_visibility_policy () =
  let check name expected ~no_progress ~stderr_isatty ~environment =
    Alcotest.(check bool)
      name expected
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
  Alcotest.(check bool)
    "first draw uses the default template" true
    (String.starts_with
       ~prefix:(Progress.clear_sequence ^ "⠁ Applying update")
       output);
  Alcotest.(check bool)
    "completion clears the line" true
    (String.ends_with ~suffix:Progress.clear_sequence output)

let test_disabled_progress_does_not_draw () =
  let (), output =
    capture_stderr (fun () ->
        Progress.with_progress ~enabled:false "must not render" (fun () -> ()))
  in
  Alcotest.(check string) "no terminal bytes" "" output

let test_determinate_progress_replaces_spinner_and_clears () =
  let (), output =
    capture_stderr (fun () ->
        Progress.with_progress ~enabled:true "Planning restore" (fun () ->
            Progress.with_determinate_progress ~enabled:true
              ~message:"Restoring checkpoint" (fun ~report ->
                report ~completed:0 ~total:4;
                ignore (Unix.select [] [] [] 0.06);
                report ~completed:2 ~total:4;
                ignore (Unix.select [] [] [] 0.06))))
  in
  Alcotest.(check bool)
    "spinner was shown while planning" true
    (contains output "⠁ Planning restore");
  Alcotest.(check bool)
    "bar starts at zero" true
    (contains output "Restoring checkpoint [");
  Alcotest.(check bool)
    "bar receives the reported count" true (contains output " 2/4");
  Alcotest.(check bool)
    "completion clears the line" true
    (String.ends_with ~suffix:Progress.clear_sequence output)

let test_disabled_determinate_progress_does_not_draw () =
  let (), output =
    capture_stderr (fun () ->
        Progress.with_determinate_progress ~enabled:false
          ~message:"must not render" (fun ~report ->
            report ~completed:0 ~total:1;
            report ~completed:1 ~total:1))
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
          Alcotest.test_case "uses the default determinate bar" `Quick
            test_default_bar_template;
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
          Alcotest.test_case "determinate progress replaces spinner and clears"
            `Slow test_determinate_progress_replaces_spinner_and_clears;
          Alcotest.test_case
            "disabled determinate progress does not draw stderr" `Quick
            test_disabled_determinate_progress_does_not_draw;
        ] );
    ]
