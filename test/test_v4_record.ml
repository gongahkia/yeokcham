module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_v4_model
module Record = Yeokcham_v4_record

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let id parser value = parser value |> Result.get_ok
let snapshot value = id Model.Snapshot_id.of_string value
let draft value = id Model.Draft_id.of_string value
let change value = id Model.Change_id.of_string value
let revision value = id Model.Revision_id.of_string value
let device value = id Model.Device_id.of_string value

let text_edit path start_byte end_byte =
  let edit_path = Model.Path.of_components [ path ] |> Result.get_ok in
  let span = Model.make_span ~start_byte ~end_byte |> Result.get_ok in
  Model.{ edit_path; edit_kind = Text span }

let fixture_project () =
  Model.init ~creator:(device "device-alice")
    ~initial_snapshot:(snapshot "snapshot-base")
    ~initial_draft:(draft "draft-one") ~title:"fixture"

let shared_project () =
  let project = fixture_project () in
  let change_revision =
    Model.make_change_revision ~change:(change "change-alpha")
      ~revision:(revision "revision-alpha")
      ~parent:None ~author:(device "device-alice")
      ~base:(snapshot "snapshot-base")
      ~result:(snapshot "snapshot-alpha")
      ~edits:[ text_edit "main.ml" 0 4; text_edit "other.ml" 8 12 ]
    |> require_ok Model.error_to_string
  in
  Model.share_active project change_revision |> require_ok Model.error_to_string

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let read_golden name =
  Golden.read_lower_hex_file (golden_path name) |> require_ok Fun.id

let current_golden_state_bytes_are_stable () =
  let expected = read_golden "v4/state-v2.cbor.hex" in
  let actual =
    fixture_project () |> Record.encode_project
    |> require_ok Record.error_to_string
  in
  Alcotest.(check string) "initial state bytes" expected actual;
  let decoded =
    Record.decode_project expected |> require_ok Record.error_to_string
  in
  Alcotest.(check string)
    "re-encoded fixture is byte-identical" expected
    (Record.encode_project decoded |> require_ok Record.error_to_string)

let legacy_v1_fixture_remains_decodable () =
  let decoded =
    read_golden "v4/state-v1.cbor.hex"
    |> Record.decode_project
    |> require_ok Record.error_to_string
  in
  Alcotest.(check string)
    "legacy state gains its retained initial checkpoint" "snapshot-base"
    (Model.Snapshot_id.to_string
       (Model.active_draft decoded).Model.latest_checkpoint);
  Alcotest.(check string)
    "legacy state upgrades to the current canonical record"
    (read_golden "v4/state-v2.cbor.hex")
    (Record.encode_project decoded |> require_ok Record.error_to_string)

let state_round_trips_with_shared_change () =
  let project = shared_project () in
  let encoded =
    Record.encode_project project |> require_ok Record.error_to_string
  in
  let decoded =
    Record.decode_project encoded |> require_ok Record.error_to_string
  in
  Alcotest.(check bool)
    "state survives a canonical round trip" true
    (Model.export project = Model.export decoded);
  Alcotest.(check int)
    "decoded projection is decision-free" 0
    (List.length (Model.projection decoded).Model.decisions)

let malformed_model_state_is_rejected_before_encoding () =
  let state = Model.export (fixture_project ()) in
  let malformed =
    Model.{ state with state_drafts = state.state_drafts @ state.state_drafts }
  in
  match Record.encode_state malformed with
  | Error error ->
      Alcotest.(check bool)
        "duplicate-draft error is preserved" true
        (String.starts_with ~prefix:"invalid persisted project state:"
           (Record.error_to_string error))
  | Ok _ -> Alcotest.fail "encoded duplicate drafts"

let noncanonical_cbor_is_rejected () =
  let canonical =
    fixture_project () |> Record.encode_project
    |> require_ok Record.error_to_string
  in
  let nonminimal_array =
    "\x98\x08" ^ String.sub canonical 1 (String.length canonical - 1)
  in
  match Record.decode_project nonminimal_array with
  | Error error ->
      Alcotest.(check bool)
        "canonical decoder reports the non-minimal length" true
        (String.ends_with ~suffix:"non-minimal argument: 8"
           (Record.error_to_string error))
  | Ok _ -> Alcotest.fail "accepted non-minimal CBOR array length"

let () =
  Alcotest.run "V4 record"
    [
      ( "state",
        [
          Alcotest.test_case "current golden state bytes are stable" `Quick
            current_golden_state_bytes_are_stable;
          Alcotest.test_case "legacy V1 fixture remains decodable" `Quick
            legacy_v1_fixture_remains_decodable;
          Alcotest.test_case "shared state round trips" `Quick
            state_round_trips_with_shared_change;
          Alcotest.test_case "malformed model state is rejected" `Quick
            malformed_model_state_is_rejected_before_encoding;
          Alcotest.test_case "noncanonical CBOR is rejected" `Quick
            noncanonical_cbor_is_rejected;
        ] );
    ]
