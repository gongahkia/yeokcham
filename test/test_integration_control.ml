module C = Yeokcham_v1_model.Core
module I = Yeokcham_v1_integration

let ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let model value = ok C.error_to_string value
let record c = C.Record_id.of_raw (String.make 32 c) |> model
let object_id c = C.Object_id.of_raw (String.make 32 c) |> model
let digest c = C.Digest.of_raw (String.make 32 c) |> model

let stored c =
  Yeokcham_store.Stored_object_id.of_raw_bytes (String.make 32 c) |> Option.get

let golden name =
  let path =
    List.find Sys.file_exists
      [ "golden/integration/" ^ name; "test/golden/integration/" ^ name ]
  in
  In_channel.with_open_bin path In_channel.input_all |> String.trim

let hex bytes =
  String.concat ""
    (List.init (String.length bytes) (fun i ->
         Printf.sprintf "%02x" (Char.code bytes.[i])))

let independent_controls () =
  let workspace = C.Workspace_id.of_raw (String.make 16 'w') |> model in
  let cursor = C.History_id.make ~workspace ~sequence:7L |> model in
  let observation =
    C.make_workspace_observation ~workspace ~cursor ~working_basis:(record 'a')
      ~basis_snapshot:(object_id 'v') ~observed_snapshot:(object_id 'o')
      ~correspondence:[]
    |> model
  in
  let request =
    C.make_composition_request
      ~repository:(C.Repository_id.of_raw (String.make 32 'q') |> model)
      ~branch:(C.Branch_id.of_raw (String.make 16 'b') |> model)
      ~accepted_heads:[ record 'a' ]
      ~selected_revisions:[ record 'r' ]
      ~resolution_ids:[ record 'z' ]
      ~authority_heads:[ digest 'h' ]
      ~policy_heads:[] ~review_evidence:[] ~workspace:observation
      ~composition_profile:"line-hunks-v1"
    |> model
  in
  List.iter
    (fun schema ->
      let choices =
        if schema = 1 then []
        else
          [
            I.make_workspace_decision ~path:[ "note.txt" ]
              ~replacement_snapshot:(object_id 'x')
            |> ok I.error_to_string;
          ]
      in
      let bytes =
        I.For_test.encode_control ~request
          ~event_heads:[ record 'e' ]
          ~proof_root:(stored 'p') ~selection_root:(stored 's')
          ~observation_digest:(digest 'd') ~known_present:(object_id 'k')
          ~accepted_snapshot:(Some (object_id 'v'))
          ~readiness:
            (I.Ready
               C.
                 {
                   accepted_snapshot = object_id 'v';
                   workspace_snapshot = object_id 't';
                 })
          ~no_op:false ~workspace_decisions:choices
        |> ok I.error_to_string
      in
      Alcotest.(check string)
        "exact independent canonical envelope"
        (golden (Printf.sprintf "plan-v%d.hex" schema))
        (hex bytes);
      Alcotest.(check string)
        "identity covers complete private envelope"
        (golden (Printf.sprintf "plan-v%d-id.hex" schema))
        (Yeokcham_hash.Sha256.digest_string bytes
        |> Yeokcham_hash.Sha256.to_raw_string |> hex))
    [ 1; 2 ]

let () =
  Alcotest.run "Integration control vectors"
    [
      ( "control",
        [
          Alcotest.test_case "independent schemas and identities" `Quick
            independent_controls;
        ] );
    ]
