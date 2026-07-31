module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Hash = Paengi_hash.Sha256
module Golden = Paengi_testkit.Golden_fixture

let require_encoding = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Encoding.construction_error_to_string error)

let require_envelope = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Envelope.creation_error_to_string error)

let require_decoded input =
  match Envelope.decode input with
  | Ok value -> value
  | Error error -> Alcotest.fail (Envelope.decode_error_to_string error)

let require_error input =
  match Envelope.decode input with
  | Error error -> error
  | Ok _ -> Alcotest.fail "envelope decoder unexpectedly accepted input"

let require_golden name =
  match Golden.read_lower_hex_file (Filename.concat "golden" name) with
  | Ok bytes -> bytes
  | Error message -> Alcotest.fail message

let payload = require_encoding (Encoding.map [ (1L, Encoding.bool true) ])

let sample =
  require_envelope
    (Envelope.create ~object_type:Envelope.Snapshot
       ~object_format_version:Envelope.current_object_format_version
       ~mandatory_features:Envelope.supported_mandatory_features ~payload ())

let mutate input offset character =
  let output = Bytes.of_string input in
  Bytes.set output offset character;
  Bytes.unsafe_to_string output

let with_uint16 input offset value =
  let output = Bytes.of_string input in
  Bytes.set output offset (Char.chr (value lsr 8));
  Bytes.set output (offset + 1) (Char.chr (value land 0xff));
  Bytes.unsafe_to_string output

let with_uint64 input offset value =
  let output = Bytes.of_string input in
  for index = 0 to 7 do
    let shift = (7 - index) * 8 in
    let byte = Int64.(to_int (logand (shift_right_logical value shift) 255L)) in
    Bytes.set output (offset + index) (Char.chr byte)
  done;
  Bytes.unsafe_to_string output

let recalculate_checksum input =
  let prefix = String.sub input 0 25 in
  let payload =
    String.sub input Envelope.header_size
      (String.length input - Envelope.header_size)
  in
  let checksum =
    Hash.feed_string Hash.empty prefix |> fun context ->
    Hash.feed_string context payload |> Hash.get |> Hash.to_raw_string
  in
  prefix ^ checksum ^ payload

let expect_kind name expected input =
  let actual = (require_error input).Envelope.kind in
  Alcotest.(check bool) name true (actual = expected)

let expect_rejection_before_payload name expected input =
  let invoked = ref false in
  let result =
    Envelope.decode_with input ~payload_decoder:(fun _ ->
        invoked := true;
        Ok ())
  in
  (match result with
  | Error error ->
      Alcotest.(check bool) name true (error.Envelope.kind = expected)
  | Ok _ ->
      Alcotest.failf "%s: envelope decoder unexpectedly accepted input" name);
  Alcotest.(check bool) (name ^ " before payload") false !invoked

let object_type_codes () =
  let expected =
    [
      (Envelope.Content, 1);
      (Envelope.Tree, 2);
      (Envelope.Snapshot, 3);
      (Envelope.Scratch_event, 4);
      (Envelope.Checkpoint, 5);
      (Envelope.Capsule, 6);
      (Envelope.Capsule_revision, 7);
      (Envelope.Release, 8);
      (Envelope.Conflict, 9);
      (Envelope.Validation, 10);
      (Envelope.Resolution, 11);
      (Envelope.Repository_config, 12);
      (Envelope.Chunk, 13);
      (Envelope.File_manifest, 14);
      (Envelope.Retention_change, 15);
      (Envelope.Scratch_generation_segment, 16);
      (Envelope.Scratch_generation, 17);
      (Envelope.Scratch_cleanup_manifest, 18);
      (Envelope.Workspace, 19);
      (Envelope.Workspace_revision, 20);
      (Envelope.Workspace_attempt, 21);
      (Envelope.Release_attestation, 22);
    ]
  in
  List.iter
    (fun (object_type, code) ->
      Alcotest.(check int)
        "object type code" code
        (Envelope.object_type_code object_type);
      Alcotest.(check bool)
        "object type decoding" true
        (Envelope.object_type_of_code code = Some object_type))
    expected;
  Alcotest.(check bool)
    "zero type is reserved" true
    (Option.is_none (Envelope.object_type_of_code 0));
  Alcotest.(check bool)
    "unassigned type is rejected" true
    (Option.is_none (Envelope.object_type_of_code 23))

let golden_envelope () =
  let expected = require_golden "envelope-v1-snapshot.peng.hex" in
  Alcotest.(check int) "header size" 57 Envelope.header_size;
  Alcotest.(check int) "envelope version" 1 Envelope.envelope_version;
  Alcotest.(check int)
    "current object format version" 1 Envelope.current_object_format_version;
  Alcotest.(check int64)
    "supported mandatory features" 0L Envelope.supported_mandatory_features;
  Alcotest.(check int)
    "checksum algorithm code" 1 Envelope.checksum_algorithm_code;
  Alcotest.(check string) "golden bytes" expected (Envelope.encode sample);
  let decoded = require_decoded expected in
  Alcotest.(check bool)
    "object type" true
    (Envelope.object_type decoded = Envelope.Snapshot);
  Alcotest.(check int)
    "object format version" 1
    (Envelope.object_format_version decoded);
  Alcotest.(check int64) "features" 0L (Envelope.mandatory_features decoded);
  Alcotest.(check bool)
    "payload" true
    (Encoding.equal payload (Envelope.payload decoded));
  Alcotest.(check string) "re-encode" expected (Envelope.encode decoded)

let retained_unknown_mandatory_feature_fixtures () =
  List.iter
    (fun (name, features) ->
      let invoked = ref false in
      let result =
        Envelope.decode_with (require_golden name) ~payload_decoder:(fun _ ->
            invoked := true;
            Ok ())
      in
      match result with
      | Error error ->
          Alcotest.(check int)
            "unknown mandatory feature offset" 8 error.Envelope.offset;
          Alcotest.(check bool)
            "unknown mandatory feature kind" true
            (error.Envelope.kind = Envelope.Unknown_mandatory_features features);
          Alcotest.(check bool)
            "unknown mandatory feature stops before payload" false !invoked
      | Ok _ -> Alcotest.fail "unknown mandatory feature fixture accepted")
    [
      ("envelope-v1-snapshot-feature-bit-0.peng.hex", 1L);
      ("envelope-v1-snapshot-feature-bit-63.peng.hex", Int64.min_int);
    ]

let construction_boundaries () =
  List.iter
    (fun version ->
      let result =
        Envelope.create ~object_type:Envelope.Content
          ~object_format_version:version ~mandatory_features:0L ~payload ()
        |> Result.map (fun _ -> false)
      in
      Alcotest.(check bool)
        "unsupported version cannot be written" true
        (result = Error (Envelope.Invalid_object_format_version version)))
    [ -1; 0; 2; 65_535; 65_536 ];
  List.iter
    (fun features ->
      let result =
        Envelope.create ~object_type:Envelope.Content
          ~object_format_version:Envelope.current_object_format_version
          ~mandatory_features:features ~payload ()
        |> Result.map (fun _ -> false)
      in
      Alcotest.(check bool)
        "mandatory features cannot be written before assignment" true
        (result = Error (Envelope.Unsupported_mandatory_features features)))
    [ 1L; Int64.shift_left 1L 62; Int64.min_int ]

let registered_types_round_trip () =
  List.iter
    (fun object_type ->
      let envelope =
        require_envelope
          (Envelope.create ~object_type
             ~object_format_version:Envelope.current_object_format_version
             ~mandatory_features:Envelope.supported_mandatory_features ~payload
             ())
      in
      let decoded = require_decoded (Envelope.encode envelope) in
      Alcotest.(check bool)
        "registered type round-trips" true
        (Envelope.object_type decoded = object_type))
    [
      Envelope.Content;
      Envelope.Tree;
      Envelope.Snapshot;
      Envelope.Scratch_event;
      Envelope.Checkpoint;
      Envelope.Capsule;
      Envelope.Capsule_revision;
      Envelope.Release;
      Envelope.Conflict;
      Envelope.Validation;
      Envelope.Resolution;
      Envelope.Repository_config;
      Envelope.Chunk;
      Envelope.File_manifest;
      Envelope.Retention_change;
      Envelope.Scratch_generation_segment;
      Envelope.Scratch_generation;
      Envelope.Scratch_cleanup_manifest;
    ]

let rejection_cases () =
  let encoded = Envelope.encode sample in
  expect_kind "invalid magic" Envelope.Invalid_magic (mutate encoded 0 'X');
  expect_kind "unknown envelope version"
    (Envelope.Unsupported_envelope_version 2)
    (mutate encoded 4 (Char.chr 2));
  expect_kind "unknown checksum algorithm"
    (Envelope.Unknown_checksum_algorithm 2)
    (mutate encoded 16 (Char.chr 2));
  expect_kind "payload length high bit" Envelope.Payload_length_out_of_range
    (mutate encoded 17 (Char.chr 0x80));
  expect_kind "declared payload length mismatch"
    (Envelope.Length_mismatch { declared = 4L; actual = 3 })
    (mutate encoded 24 (Char.chr 4));
  expect_kind "trailing byte"
    (Envelope.Length_mismatch { declared = 3L; actual = 4 })
    (encoded ^ "\000");
  expect_kind "covered header corruption" Envelope.Checksum_mismatch
    (mutate encoded 6 (Char.chr 2));
  expect_kind "checksum corruption" Envelope.Checksum_mismatch
    (mutate encoded 25 (Char.chr 0));
  expect_kind "payload corruption" Envelope.Checksum_mismatch
    (mutate encoded Envelope.header_size (Char.chr 0));
  let unknown_type = mutate encoded 5 (Char.chr 127) |> recalculate_checksum in
  expect_kind "unknown type after checksum" (Envelope.Unknown_object_type 127)
    unknown_type;
  let unsupported_version = with_uint16 encoded 6 2 |> recalculate_checksum in
  expect_rejection_before_payload "unsupported version after checksum"
    (Envelope.Unsupported_object_format_version 2) unsupported_version;
  let low_feature = with_uint64 encoded 8 1L |> recalculate_checksum in
  expect_rejection_before_payload "low mandatory feature after checksum"
    (Envelope.Unknown_mandatory_features 1L) low_feature;
  let high_feature =
    with_uint64 encoded 8 Int64.min_int |> recalculate_checksum
  in
  expect_rejection_before_payload "high mandatory feature after checksum"
    (Envelope.Unknown_mandatory_features Int64.min_int) high_feature;
  let unknown_type_before_version =
    let with_type = mutate encoded 5 (Char.chr 127) in
    with_uint16 with_type 6 2 |> recalculate_checksum
  in
  expect_kind "object type precedes object format"
    (Envelope.Unknown_object_type 127) unknown_type_before_version;
  let version_before_feature =
    let with_feature = with_uint64 encoded 8 1L in
    with_uint16 with_feature 6 2 |> recalculate_checksum
  in
  expect_kind "object format precedes mandatory features"
    (Envelope.Unsupported_object_format_version 2) version_before_feature

let truncation_and_callback_order () =
  let encoded = Envelope.encode sample in
  for length = 0 to String.length encoded - 1 do
    let prefix = String.sub encoded 0 length in
    match Envelope.decode prefix with
    | Error _ -> ()
    | Ok _ -> Alcotest.failf "truncated envelope accepted at length %d" length
  done;
  let corrupted = mutate encoded 6 (Char.chr 2) in
  let invoked = ref false in
  let result =
    Envelope.decode_with corrupted ~payload_decoder:(fun _ ->
        invoked := true;
        Error "payload decoder must not run")
  in
  Alcotest.(check bool)
    "corrupt envelope rejected" true (Result.is_error result);
  Alcotest.(check bool)
    "payload decoder not called before checksum" false !invoked;
  let invalid_payload =
    mutate encoded Envelope.header_size (Char.chr 0xff) |> recalculate_checksum
  in
  let invoked = ref false in
  let result =
    Envelope.decode_with invalid_payload ~payload_decoder:(fun _ ->
        invoked := true;
        Error "expected payload failure")
  in
  let payload_error_classified =
    match result with
    | Error error ->
        String.starts_with ~prefix:"byte 57: invalid payload: "
          (Envelope.decode_error_to_string error)
    | Ok _ -> false
  in
  Alcotest.(check bool)
    "verified invalid payload reaches callback" true !invoked;
  Alcotest.(check bool)
    "payload error is classified" true payload_error_classified;
  expect_kind "Profile 1 failure follows checksum validation"
    (Envelope.Invalid_payload "byte 0: indefinite length is not permitted")
    invalid_payload

let () =
  Alcotest.run "object envelope"
    [
      ( "layout",
        [
          Alcotest.test_case "object type registry" `Quick object_type_codes;
          Alcotest.test_case "golden envelope" `Quick golden_envelope;
          Alcotest.test_case "construction boundaries" `Quick
            construction_boundaries;
          Alcotest.test_case "registered types round-trip" `Quick
            registered_types_round_trip;
        ] );
      ( "rejection",
        [
          Alcotest.test_case "retained unknown mandatory-feature fixtures"
            `Quick retained_unknown_mandatory_feature_fixtures;
          Alcotest.test_case "header and payload corruption" `Quick
            rejection_cases;
          Alcotest.test_case "truncation and callback ordering" `Quick
            truncation_and_callback_order;
        ] );
    ]
