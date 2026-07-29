module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Hash = Paengi_hash.Sha256

let raw_of_hex encoded =
  let nibble = function
    | '0' .. '9' as character -> Char.code character - Char.code '0'
    | 'a' .. 'f' as character -> Char.code character - Char.code 'a' + 10
    | 'A' .. 'F' as character -> Char.code character - Char.code 'A' + 10
    | _ -> invalid_arg "non-hex test vector"
  in
  let length = String.length encoded in
  if length mod 2 <> 0 then invalid_arg "odd test vector";
  String.init (length / 2) (fun index ->
      let offset = index * 2 in
      Char.chr ((nibble encoded.[offset] lsl 4) lor nibble encoded.[offset + 1]))

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

let payload = require_encoding (Encoding.map [ (1L, Encoding.bool true) ])

let sample =
  require_envelope
    (Envelope.create ~object_type:Envelope.Snapshot ~object_format_version:1
       ~mandatory_features:0L ~payload ())

let mutate input offset character =
  let output = Bytes.of_string input in
  Bytes.set output offset character;
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
    (Option.is_none (Envelope.object_type_of_code 13))

let golden_envelope () =
  let expected =
    raw_of_hex
      "50454e4701030001000000000000000001000000000000000399ea8b710e1438755cd7ea29deb16a182a74224f71da67867be1e5007df043a8a101f5"
  in
  Alcotest.(check int) "header size" 57 Envelope.header_size;
  Alcotest.(check int) "envelope version" 1 Envelope.envelope_version;
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

let construction_and_features () =
  let invalid_low =
    Envelope.create ~object_type:Envelope.Content ~object_format_version:(-1)
      ~mandatory_features:0L ~payload ()
    |> Result.map (fun _ -> false)
  in
  Alcotest.(check bool)
    "negative version rejected" true
    (invalid_low = Error (Envelope.Invalid_object_format_version (-1)));
  let invalid_high =
    Envelope.create ~object_type:Envelope.Content ~object_format_version:65_536
      ~mandatory_features:0L ~payload ()
    |> Result.map (fun _ -> false)
  in
  Alcotest.(check bool)
    "large version rejected" true
    (invalid_high = Error (Envelope.Invalid_object_format_version 65_536));
  let unsupported =
    Envelope.create ~object_type:Envelope.Content ~object_format_version:0
      ~mandatory_features:1L ~payload ()
    |> Result.map (fun _ -> false)
  in
  Alcotest.(check bool)
    "unknown feature cannot be written" true
    (unsupported = Error (Envelope.Unsupported_mandatory_features 1L));
  let with_feature =
    require_envelope
      (Envelope.create ~supported_features:1L ~object_type:Envelope.Content
         ~object_format_version:65_535 ~mandatory_features:1L ~payload ())
  in
  let encoded = Envelope.encode with_feature in
  Alcotest.(check int) "version high byte" 255 (Char.code encoded.[6]);
  Alcotest.(check int) "version low byte" 255 (Char.code encoded.[7]);
  expect_kind "unknown feature rejected by default"
    (Envelope.Unknown_mandatory_features 1L) encoded;
  match Envelope.decode ~supported_features:1L encoded with
  | Error error -> Alcotest.fail (Envelope.decode_error_to_string error)
  | Ok decoded ->
      Alcotest.(check int64)
        "known feature preserved" 1L
        (Envelope.mandatory_features decoded)

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
  let unknown_features =
    mutate encoded 15 (Char.chr 1) |> recalculate_checksum
  in
  expect_kind "unknown features after checksum"
    (Envelope.Unknown_mandatory_features 1L) unknown_features

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

let ascii_generator =
  QCheck2.Gen.map
    (fun raw ->
      String.map (fun character -> Char.chr (Char.code character land 0x7f)) raw)
    (QCheck2.Gen.string_size (QCheck2.Gen.int_range 0 32))

let raw_generator = QCheck2.Gen.string_size (QCheck2.Gen.int_range 0 128)

let rec value_generator depth =
  let scalar =
    QCheck2.Gen.oneof
      [
        QCheck2.Gen.map Encoding.integer QCheck2.Gen.int64;
        QCheck2.Gen.map Encoding.bytes raw_generator;
        QCheck2.Gen.map
          (fun value -> require_encoding (Encoding.text value))
          ascii_generator;
        QCheck2.Gen.map Encoding.bool QCheck2.Gen.bool;
        QCheck2.Gen.return Encoding.null;
      ]
  in
  if depth = 0 then scalar
  else
    let child = value_generator (depth - 1) in
    let arrays =
      QCheck2.Gen.map require_encoding
        (QCheck2.Gen.map Encoding.array
           (QCheck2.Gen.list_size (QCheck2.Gen.int_range 0 4) child))
    in
    let maps =
      QCheck2.Gen.map
        (fun values ->
          let keys = [ 0L; 24L; 256L; 65_536L ] in
          let entries =
            List.mapi (fun index value -> (List.nth keys index, value)) values
          in
          require_encoding (Encoding.map entries))
        (QCheck2.Gen.list_size (QCheck2.Gen.int_range 0 4) child)
    in
    QCheck2.Gen.oneof_weighted [ (6, scalar); (2, arrays); (2, maps) ]

let object_type_generator =
  QCheck2.Gen.oneof_list
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
    ]

let round_trip_property =
  QCheck2.Test.make ~count:500 ~name:"envelopes round-trip with exact bytes"
    QCheck2.Gen.(
      pair object_type_generator (pair (int_range 0 65_535) (value_generator 4)))
    (fun (object_type, (object_format_version, payload)) ->
      match
        Envelope.create ~object_type ~object_format_version
          ~mandatory_features:0L ~payload ()
      with
      | Error _ -> false
      | Ok envelope -> (
          let encoded = Envelope.encode envelope in
          match Envelope.decode encoded with
          | Error _ -> false
          | Ok decoded ->
              Envelope.object_type decoded = object_type
              && Envelope.object_format_version decoded = object_format_version
              && Int64.equal (Envelope.mandatory_features decoded) 0L
              && Encoding.equal (Envelope.payload decoded) payload
              && String.equal (Envelope.encode decoded) encoded))

let corruption_property =
  QCheck2.Test.make ~count:500 ~name:"every single-byte mutation is rejected"
    QCheck2.Gen.(pair (value_generator 3) nat)
    (fun (payload, candidate) ->
      match
        Envelope.create ~object_type:Envelope.Content ~object_format_version:1
          ~mandatory_features:0L ~payload ()
      with
      | Error _ -> false
      | Ok envelope ->
          let encoded = Envelope.encode envelope in
          let offset = candidate mod String.length encoded in
          let original = Char.code encoded.[offset] in
          let corrupted = mutate encoded offset (Char.chr (original lxor 1)) in
          Result.is_error (Envelope.verify corrupted))

let random_bytes_property =
  QCheck2.Test.make ~count:2_000
    ~name:"arbitrary envelope bytes reject or re-encode exactly" raw_generator
    (fun input ->
      match Envelope.decode input with
      | Error _ -> true
      | Ok value -> String.equal input (Envelope.encode value))

let () =
  Alcotest.run "object envelope"
    [
      ( "layout",
        [
          Alcotest.test_case "object type registry" `Quick object_type_codes;
          Alcotest.test_case "golden envelope" `Quick golden_envelope;
          Alcotest.test_case "construction and features" `Quick
            construction_and_features;
        ] );
      ( "rejection",
        [
          Alcotest.test_case "header and payload corruption" `Quick
            rejection_cases;
          Alcotest.test_case "truncation and callback ordering" `Quick
            truncation_and_callback_order;
        ] );
      ( "properties",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick round_trip_property;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick corruption_property;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick random_bytes_property;
        ] );
    ]
