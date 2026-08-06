module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_model
open Model

let require_path components =
  match Path.of_components components with
  | Ok path -> path
  | Error error -> Alcotest.fail (Path.error_to_string error)

let require_built_snapshot entries =
  match Snapshot.of_entries entries with
  | Ok snapshot -> snapshot
  | Error error -> Alcotest.fail (construction_error_to_string error)

let require_event = function
  | Ok event -> event
  | Error error -> Alcotest.fail (canonical_decode_error_to_string error)

let require_checkpoint = function
  | Ok checkpoint -> checkpoint
  | Error error -> Alcotest.fail (canonical_decode_error_to_string error)

let require_envelope = function
  | Ok envelope -> envelope
  | Error error -> Alcotest.fail (Envelope.creation_error_to_string error)

let require_decoded_envelope = function
  | Ok envelope -> envelope
  | Error error -> Alcotest.fail (Envelope.decode_error_to_string error)

let require_golden name =
  match Golden.read_lower_hex_file (Filename.concat "golden" name) with
  | Ok bytes -> bytes
  | Error error -> Alcotest.fail error

let file ?(mode = Regular) content = { mode; content }

let enveloped object_type payload =
  Envelope.create ~object_type
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:
      (match Encoding.decode payload with
      | Ok value -> value
      | Error error -> Alcotest.fail (Encoding.decode_error_to_string error))
    ()
  |> require_envelope |> Envelope.encode

let nested_snapshot () =
  let bin = require_path [ "bin" ] in
  let docs = require_path [ "docs" ] in
  let guides = require_path [ "docs"; "guides" ] in
  require_built_snapshot
    [
      File_path
        (require_path [ "latest" ], file ~mode:Symlink "docs/guides/guide.txt");
      File_path (require_path [ "docs"; "guides"; "guide.txt" ], file "guide\n");
      Directory_path guides;
      File_path
        ( require_path [ "bin"; "run" ],
          file ~mode:Executable "#!/bin/sh\necho yeokcham\n" );
      Directory_path docs;
      Directory_path bin;
    ]

let scratch_history () =
  let docs = require_path [ "docs" ] in
  let archive = require_path [ "archive" ] in
  let old = require_path [ "docs"; "old.txt" ] in
  let run = require_path [ "docs"; "run" ] in
  let removed = require_path [ "archive"; "remove.txt" ] in
  let draft = require_path [ "docs"; "draft.txt" ] in
  let final = require_path [ "archive"; "final.txt" ] in
  let initial =
    require_built_snapshot
      [
        Directory_path docs;
        Directory_path archive;
        File_path (old, file "first\n");
        File_path (run, file "#!/bin/sh\nexit 0\n");
        File_path (removed, file "obsolete\000bytes");
      ]
  in
  let parent =
    Checkpoint.initial ~snapshot:initial ~created_at:11L
      ~retention:[ Periodic_retention ]
  in
  let event =
    Scratch_event.create ~parent:(Checkpoint.id parent)
      ~operations:
        [
          Create_file { path = draft; content = "draft\255"; mode = Regular };
          Modify_file
            {
              path = old;
              expected_content = "first\n";
              replacement_content = "second\n";
            };
          Delete_path
            { path = removed; prior = File (file "obsolete\000bytes") };
          Move_path
            {
              source = draft;
              destination = final;
              prior = File (file "draft\255");
            };
          Change_mode
            {
              path = run;
              expected_mode = Regular;
              replacement_mode = Executable;
            };
        ]
      ~observed_at:12L ~source:Scan
  in
  let checkpoint =
    match
      Scratch.apply_event ~parent ~created_at:13L
        ~retention:[ Recent_window; User_pinned ]
        event
    with
    | Ok checkpoint -> checkpoint
    | Error error -> Alcotest.fail (event_transition_error_to_string error)
  in
  (event, checkpoint)

let check_golden_bytes name object_type payload =
  let actual = enveloped object_type payload in
  Alcotest.(check string) name (require_golden name) actual;
  let decoded =
    require_decoded_envelope (Envelope.decode (require_golden name))
  in
  Alcotest.(check bool)
    (name ^ " type") true
    (Envelope.object_type decoded = object_type);
  Encoding.encode (Envelope.payload decoded)

let empty_snapshot_golden () =
  let snapshot = Snapshot.empty in
  let payload = Snapshot.canonical_bytes snapshot in
  let decoded_payload =
    check_golden_bytes "model-v1-snapshot-empty.yeok.hex" Envelope.Snapshot
      payload
  in
  let decoded =
    match Snapshot.decode_canonical_bytes decoded_payload with
    | Ok snapshot -> snapshot
    | Error error -> Alcotest.fail (canonical_decode_error_to_string error)
  in
  Alcotest.(check bool)
    "empty snapshot decodes" true
    (Snapshot.equal snapshot decoded)

let nested_snapshot_golden () =
  let snapshot = nested_snapshot () in
  let payload = Snapshot.canonical_bytes snapshot in
  let decoded_payload =
    check_golden_bytes "model-v1-snapshot-nested.yeok.hex" Envelope.Snapshot
      payload
  in
  let decoded =
    match Snapshot.decode_canonical_bytes decoded_payload with
    | Ok snapshot -> snapshot
    | Error error -> Alcotest.fail (canonical_decode_error_to_string error)
  in
  Alcotest.(check bool)
    "nested snapshot decodes" true
    (Snapshot.equal snapshot decoded);
  Alcotest.(check string)
    "nested snapshot canonical payload" payload
    (Snapshot.canonical_bytes decoded)

let scratch_event_golden () =
  let event, _ = scratch_history () in
  let payload = Scratch_event.canonical_bytes event in
  let decoded_payload =
    check_golden_bytes "model-v1-scratch-event.yeok.hex" Envelope.Scratch_event
      payload
  in
  let decoded =
    Scratch_event.decode_canonical_bytes decoded_payload |> require_event
  in
  Alcotest.(check string)
    "scratch event decodes" payload
    (Scratch_event.canonical_bytes decoded)

let checkpoint_golden () =
  let _, checkpoint = scratch_history () in
  let payload = Checkpoint.canonical_bytes checkpoint in
  let decoded_payload =
    check_golden_bytes "model-v1-checkpoint.yeok.hex" Envelope.Checkpoint
      payload
  in
  let decoded =
    Checkpoint.decode_canonical_bytes
      ~snapshot:(Checkpoint.snapshot checkpoint)
      decoded_payload
    |> require_checkpoint
  in
  Alcotest.(check string)
    "checkpoint decodes" payload
    (Checkpoint.canonical_bytes decoded)

let () =
  Alcotest.run "canonical model objects"
    [
      ( "golden",
        [
          Alcotest.test_case "empty snapshot" `Quick empty_snapshot_golden;
          Alcotest.test_case "nested snapshot" `Quick nested_snapshot_golden;
          Alcotest.test_case "scratch event" `Quick scratch_event_golden;
          Alcotest.test_case "checkpoint" `Quick checkpoint_golden;
        ] );
    ]
