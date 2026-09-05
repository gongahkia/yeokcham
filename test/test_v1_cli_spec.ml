module Spec = Yeokcham_v1_cli_spec

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

let every_command_accepts_the_shared_format_option () =
  List.iter
    (fun command ->
      match
        List.find_opt
          (fun option -> String.equal option.Spec.option_name "--format")
          command.Spec.command_options
      with
      | Some option ->
          if
            option.Spec.option_repeatable
            || option.Spec.option_value <> Spec.Choice [ "text"; "json" ]
          then
            Alcotest.fail
              ("command has an invalid shared format option: "
              ^ String.concat " " command.Spec.command_path)
      | None ->
          Alcotest.fail
            ("command lacks the shared format option: "
            ^ String.concat " " command.Spec.command_path))
    Spec.commands

let receipt_and_diagnostic_paths_are_never_hook_eligible () =
  let excluded =
    [
      [ "receive" ];
      [ "sync" ];
      [ "bootstrap" ];
      [ "daemon"; "start" ];
      [ "daemon"; "status" ];
      [ "daemon"; "stop" ];
      [ "daemon"; "sync" ];
      [ "relay"; "serve" ];
      [ "relay"; "access"; "issue" ];
      [ "relay"; "access"; "rotate" ];
      [ "relay"; "access"; "revoke" ];
      [ "relay"; "access"; "list" ];
      [ "verify" ];
      [ "repair"; "plan" ];
      [ "repair"; "apply" ];
      [ "repair"; "defer" ];
    ]
  in
  List.iter
    (fun path ->
      match Spec.find path with
      | Some { Spec.command_hook_eligible = false; _ } -> ()
      | Some _ ->
          Alcotest.fail
            ("receipt or diagnostic command is hook eligible: "
           ^ String.concat " " path)
      | None ->
          Alcotest.fail
            ("missing command specification: " ^ String.concat " " path))
    excluded

let () =
  Alcotest.run "V1 CLI specification"
    [
      ( "specification",
        [
          Alcotest.test_case "paths and options are valid" `Quick
            command_paths_are_unique_and_valid;
          Alcotest.test_case "completion is deterministic and complete" `Quick
            completion_is_deterministic_and_complete;
          Alcotest.test_case "every command accepts the shared format" `Quick
            every_command_accepts_the_shared_format_option;
          Alcotest.test_case "receipt and diagnostic paths exclude hooks" `Quick
            receipt_and_diagnostic_paths_are_never_hook_eligible;
        ] );
    ]
