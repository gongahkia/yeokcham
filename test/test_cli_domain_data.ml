module C = Yeokcham_v1_cli_data

let ok = function Ok value -> value | Error message -> Alcotest.fail message
let json data = Yojson.Safe.to_string data
let decode data = C.decode (json data)
let field name data = Yojson.Safe.Util.member name data
let fixture_path = "golden/local/cli-domain-v2.json"

let action : C.next_action =
  C.
    {
      arguments = [ "yeokcham"; "ignore"; "explain"; "notes" ];
      explanation = "Inspect the capture rule for this path.";
      applicable = true;
      confirmation_required = false;
    }

let data =
  `Assoc
    [
      ("saved_state", `String "workspace:3");
      ("capture", `Assoc [ ("state", `String "incomplete") ]);
    ]

let envelope () =
  C.domain_success ~command:"status" ~outcome:`Incomplete
    ~code:"capture-incomplete"
    ~message:"Capture is incomplete; saved state remains available." ~data
    ~warnings:[] ~next_actions:[ action ] ()

let golden_outcome_and_actions () =
  let path =
    if Sys.file_exists fixture_path then fixture_path
    else "test/" ^ fixture_path
  in
  let expected =
    In_channel.with_open_bin path In_channel.input_all |> String.trim
  in
  let actual = C.encode (envelope ()) in
  Alcotest.(check string) "versioned domain JSON" expected actual;
  let reopened = C.decode expected |> ok in
  Alcotest.(check int) "new schema explicit" 2 (C.version reopened);
  Alcotest.(check bool)
    "successful inspection can report incomplete task" true (C.ok reopened);
  Alcotest.(check bool)
    "incomplete is not completed" true
    (C.outcome reopened = Some `Incomplete);
  Alcotest.(check bool)
    "actual data available" true
    (C.data reopened = Some data);
  Alcotest.(check bool)
    "action arguments survive" true
    (C.next_actions reopened = [ action ]);
  Alcotest.(check bool)
    "legacy result alias retained" true
    (C.result reopened = Some data)

let interrupted_failure_retains_context () =
  let error =
    { C.code = "recovery-pending"; message = "Resume the original operation." }
  in
  let envelope =
    C.domain_failure ~command:"switch" ~outcome:`Interrupted ~error
      ~operation_id:"operation-id" ~plan_id:"plan-id"
      ~data:(`Assoc [ ("target", `String "experiment") ])
      ~warnings:[ "Files are not fully applied." ]
      ~next_actions:
        [ { action with C.arguments = [ "yeokcham"; "switch"; "experiment" ] } ]
      ()
  in
  let reopened = C.encode envelope |> C.decode |> ok in
  Alcotest.(check bool) "failure explicit" false (C.ok reopened);
  Alcotest.(check bool)
    "interrupted outcome retained" true
    (C.outcome reopened = Some `Interrupted);
  let encoded = C.encode reopened |> Yojson.Safe.from_string in
  Alcotest.(check string)
    "operation retained" "operation-id"
    (field "operation_id" encoded |> Yojson.Safe.Util.to_string);
  Alcotest.(check string)
    "plan retained" "plan-id"
    (field "plan_id" encoded |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool)
    "failure does not fabricate legacy result" true
    (C.result reopened = None)

let rejects_inconsistent_or_unactionable_data () =
  let base =
    C.encode (envelope ())
    |> Yojson.Safe.from_string |> Yojson.Safe.Util.to_assoc
  in
  let replace name value =
    `Assoc ((name, value) :: List.remove_assoc name base)
  in
  let invalid =
    [
      replace "outcome" (`String "blocked");
      replace "outcome" (`String "future-state");
      replace "data" (`Assoc [ ("different", `Bool true) ]);
      replace "next_actions"
        (`List
           [
             `Assoc
               [
                 ( "arguments",
                   `List [ `String "yeokcham"; `String "bad\000arg" ] );
                 ("explanation", `String "Invalid");
                 ("applicable", `Bool true);
                 ("confirmation_required", `Bool false);
               ];
           ]);
      replace "next_actions"
        (`List
           [
             `Assoc
               [
                 ("arguments", `List []);
                 ("explanation", `String "Empty action");
                 ("applicable", `Bool true);
                 ("confirmation_required", `Bool false);
               ];
           ]);
      replace "operation_id" (`String "line\nbreak");
      `Assoc (("outcome", `String "incomplete") :: base);
      `Assoc (("unknown", `Bool true) :: base);
    ]
  in
  List.iter
    (fun invalid ->
      match decode invalid with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "accepted contradictory domain fields")
    invalid

let arguments_preserve_literal_path_bytes () =
  let argument = "notes with spaces\nand a newline" in
  let action =
    { action with C.arguments = [ "yeokcham"; "ignore"; "explain"; argument ] }
  in
  let envelope =
    C.domain_success ~command:"ignore-explain" ~outcome:`Completed
      ~code:"ignore-explained" ~message:"Capture rule inspected."
      ~data:(`Assoc []) ~warnings:[] ~next_actions:[ action ] ()
  in
  let reopened = C.encode envelope |> C.decode |> ok in
  Alcotest.(check bool)
    "argv is not shell text" true
    (C.next_actions reopened = [ action ])

let () =
  Alcotest.run "CLI domain outcomes"
    [
      ( "schema",
        [
          Alcotest.test_case "golden incomplete inspection and actions" `Quick
            golden_outcome_and_actions;
          Alcotest.test_case "interrupted failure includes operation context"
            `Quick interrupted_failure_retains_context;
          Alcotest.test_case "contradictions and malformed actions refuse"
            `Quick rejects_inconsistent_or_unactionable_data;
          Alcotest.test_case "literal arguments remain an array" `Quick
            arguments_preserve_literal_path_bytes;
        ] );
    ]
