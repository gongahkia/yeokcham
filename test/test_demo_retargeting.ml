let require condition message = if not condition then Alcotest.fail message

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
      Filename.concat cwd ("_build/default/bin/" ^ name);
      Filename.concat cwd ("../_build/default/bin/" ^ name);
    ]

let environment key value =
  Unix.environment () |> Array.to_list
  |> List.filter (fun entry ->
      not (String.starts_with ~prefix:(key ^ "=") entry))
  |> fun inherited -> Array.of_list ((key ^ "=" ^ value) :: inherited)

let run ~environment program arguments =
  let output = Filename.temp_file "yeokcham-demo-retargeting-output-" "" in
  Fun.protect
    ~finally:(fun () -> Unix.unlink output)
    (fun () ->
      let descriptor =
        Unix.openfile output [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
      in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          let status =
            Unix.create_process_env program
              (Array.of_list (program :: arguments))
              environment Unix.stdin descriptor descriptor
            |> Unix.waitpid [] |> snd
          in
          (status, In_channel.with_open_bin output In_channel.input_all)))

let exited = function
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let contains text needle =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec loop index =
    if index + needle_length > text_length then false
    else if String.sub text index needle_length = needle then true
    else loop (index + 1)
  in
  loop 0

let retargeting_outcomes_remain_nonpersistent_and_explicit () =
  let environment =
    environment "YEOKCHAM_RETARGETING_DEMO_BIN" (binary "retargeting_demo_v1.exe")
  in
  let status, output =
    run ~environment "sh" [ script "demonstrate-retargeting-v1.sh" ]
  in
  require (exited status) "retargeting demonstration failed";
  require
    (contains output "semantic case=incomplete-alias outcome=uncertain-anchor")
    "incomplete evidence applied";
  require
    (contains output "semantic case=incomplete-alias"
    && contains output "automatic=false")
    "incomplete evidence is automatic";
  require
    (contains output
       "semantic case=exact-textual-fallback outcome=uncertain-anchor \
        stage=exact-textual-fallback confidence=low automatic=false \
        fallback=true")
    "textual fallback lost its explicit low-confidence boundary";
  require
    (contains output "semantic case=ambiguity outcome=ambiguous-anchor"
    && contains output "candidates=2")
    "semantic ambiguity lost candidates";
  require
    (contains output
       "textual case=unique-preimage outcome=applied \
        stage=unique-exact-preimage bytes=prefix done suffix")
    "unique textual preimage did not apply";
  require
    (contains output
       "textual case=ambiguity outcome=conflict kind=ambiguous-match")
    "textual ambiguity is not structured";
  require
    (contains output
       "textual case=invalid-operation outcome=rejected error=original span is \
        invalid")
    "invalid patch did not return a structured error"

let arguments_reject () =
  let status, _ =
    run ~environment:(Unix.environment ()) "sh"
      [ script "demonstrate-retargeting-v1.sh"; "unexpected" ]
  in
  require (not (exited status)) "unexpected script argument was accepted"

let () =
  Alcotest.run "retargeting uncertainty demonstration"
    [
      ( "retargeting",
        [
          Alcotest.test_case "uncertainty and fallback stay explicit" `Quick
            retargeting_outcomes_remain_nonpersistent_and_explicit;
          Alcotest.test_case "arguments reject" `Quick arguments_reject;
        ] );
    ]
