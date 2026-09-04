module Spec = Yeokcham_v4_cli_spec

let contains text needle =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec loop offset =
    offset + needle_length <= text_length
    && (String.equal (String.sub text offset needle_length) needle
       || loop (offset + 1))
  in
  needle_length > 0 && loop 0

let command_paths_are_unique_and_valid () =
  match Spec.validate Spec.commands with
  | Ok () -> ()
  | Error error -> Alcotest.fail error

let completion_is_deterministic_and_complete () =
  [ Spec.Bash; Spec.Zsh; Spec.Fish ]
  |> List.iter (fun shell ->
      let rendered = Spec.render_completion shell in
      Alcotest.(check string)
        "rendering is deterministic" rendered
        (Spec.render_completion shell);
      Spec.command_words ()
      |> List.iter (fun word ->
          Alcotest.(check bool)
            ("completion has command word " ^ word)
            true (contains rendered word));
      Spec.option_specs ()
      |> List.iter (fun option ->
          Alcotest.(check bool)
            ("completion has option spelling " ^ option.Spec.option_name)
            true
            (contains rendered option.Spec.option_name)));
  Alcotest.(check bool)
    "Bash uses a registered function" true
    (String.contains (Spec.render_completion Spec.Bash) 'F');
  Alcotest.(check bool)
    "Zsh has a compdef header" true
    (String.starts_with ~prefix:"#compdef" (Spec.render_completion Spec.Zsh));
  Alcotest.(check bool)
    "Fish has declarative commands" true
    (String.contains (Spec.render_completion Spec.Fish) 'c')

let () =
  Alcotest.run "V4 CLI specification"
    [
      ( "specification",
        [
          Alcotest.test_case "paths and options are valid" `Quick
            command_paths_are_unique_and_valid;
          Alcotest.test_case "completion is deterministic and complete" `Quick
            completion_is_deterministic_and_complete;
        ] );
    ]
