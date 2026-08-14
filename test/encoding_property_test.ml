module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope

let default_seed = 20_260_729

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> (
      match int_of_string_opt value with
      | Some seed -> seed
      | None -> invalid_arg "PROPERTY_TEST_SEED must be an integer")

let stable_seed name =
  let mask = 0x3fff_ffffL in
  let hash =
    String.fold_left
      (fun state character ->
        Int64.(
          logand
            (add (mul state 16_777_619L) (of_int (Char.code character)))
            mask))
      (Int64.of_int base_seed) name
  in
  Int64.to_int hash

let state_for name =
  let seed = stable_seed name in
  Printf.printf "encoding property seed [%s]: %d\n%!" name seed;
  Random.State.make [| base_seed; seed |]

let () = Printf.printf "encoding property base seed: %d\n%!" base_seed

let require_value = function
  | Ok value -> value
  | Error error -> failwith (Encoding.construction_error_to_string error)

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
          (fun value -> require_value (Encoding.text value))
          ascii_generator;
        QCheck2.Gen.map Encoding.bool QCheck2.Gen.bool;
        QCheck2.Gen.return Encoding.null;
      ]
  in
  if depth = 0 then scalar
  else
    let child = value_generator (depth - 1) in
    let arrays =
      QCheck2.Gen.map require_value
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
          require_value (Encoding.map entries))
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
      Envelope.Chunk;
      Envelope.File_manifest;
      Envelope.Retention_change;
      Envelope.Scratch_generation_segment;
      Envelope.Scratch_generation;
      Envelope.Scratch_cleanup_manifest;
      Envelope.Workspace;
      Envelope.Workspace_revision;
      Envelope.Workspace_attempt;
      Envelope.Release_attestation;
      Envelope.Git_mapping;
      Envelope.Imported_transition;
      Envelope.Imported_tag;
      Envelope.Ref_event;
      Envelope.Device_identity;
      Envelope.Divergent_ref_set;
      Envelope.Git_archive;
      Envelope.Git_adoption;
    ]

let boundary_lengths =
  [ 0; 1; 2; 23; 24; 25; 55; 56; 57; 58; 63; 64; 127; 128; 255; 256 ]

let malformed_byte_inputs =
  [
    "";
    "\x58\x18";
    "\x5a\x00\x01\x00\x00";
    "\x81";
    String.make 65 (Char.chr 0x81) ^ "\xf6";
    String.make 56 '\000';
  ]

let byte_generator =
  let length_generator =
    QCheck2.Gen.oneof
      [ QCheck2.Gen.oneof_list boundary_lengths; QCheck2.Gen.int_range 0 256 ]
  in
  let arbitrary =
    QCheck2.Gen.bind length_generator (fun length ->
        QCheck2.Gen.string_size (QCheck2.Gen.return length))
  in
  QCheck2.Gen.oneof [ arbitrary; QCheck2.Gen.oneof_list malformed_byte_inputs ]

type 'value decoded = Decoded of 'value | Rejected | Raised of string

let safely_decode decoder input =
  try match decoder input with Ok value -> Decoded value | Error _ -> Rejected
  with exn -> Raised (Printexc.to_string exn)

let profile_round_trip =
  QCheck2.Test.make ~count:500 ~name:"profile round trip" (value_generator 4)
    (fun value ->
      match Encoding.decode (Encoding.encode value) with
      | Ok decoded -> Encoding.equal value decoded
      | Error _ -> false)

let envelope_round_trip =
  QCheck2.Test.make ~count:500 ~name:"envelope round trip"
    QCheck2.Gen.(pair object_type_generator (value_generator 4))
    (fun (object_type, payload) ->
      match
        Envelope.create ~object_type
          ~object_format_version:Envelope.current_object_format_version
          ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
      with
      | Error _ -> false
      | Ok envelope -> (
          match Envelope.decode (Envelope.encode envelope) with
          | Ok decoded ->
              Envelope.object_type decoded = object_type
              && Envelope.object_format_version decoded
                 = Envelope.current_object_format_version
              && Int64.equal
                   (Envelope.mandatory_features decoded)
                   Envelope.supported_mandatory_features
              && Encoding.equal (Envelope.payload decoded) payload
          | Error _ -> false))

let profile_decoder_totality =
  QCheck2.Test.make ~count:2_000
    ~name:"profile decoder totality and canonical bytes" byte_generator
    (fun input ->
      match safely_decode (fun bytes -> Encoding.decode bytes) input with
      | Decoded value -> String.equal (Encoding.encode value) input
      | Rejected -> true
      | Raised _ -> false)

let envelope_decoder_totality =
  QCheck2.Test.make ~count:2_000
    ~name:"envelope decoder totality and canonical bytes" byte_generator
    (fun input ->
      match safely_decode Envelope.decode input with
      | Decoded value -> String.equal (Envelope.encode value) input
      | Rejected -> true
      | Raised _ -> false)

let deterministic_bytes length =
  String.init length (fun index ->
      Char.chr ((base_seed + (index * 73)) land 0xff))

let assert_totality name decoder encoder input =
  match safely_decode decoder input with
  | Decoded value -> Alcotest.(check string) name input (encoder value)
  | Rejected -> ()
  | Raised exn -> Alcotest.failf "%s raised %s" name exn

let byte_length_boundaries () =
  List.iter
    (fun length ->
      let input = deterministic_bytes length in
      assert_totality
        (Printf.sprintf "Profile 1 generated length %d" length)
        (fun bytes -> Encoding.decode bytes)
        Encoding.encode input;
      assert_totality
        (Printf.sprintf "Envelope 1 generated length %d" length)
        Envelope.decode Envelope.encode input)
    boundary_lengths;
  List.iteri
    (fun index input ->
      assert_totality
        (Printf.sprintf "Profile 1 malformed length %d" index)
        (fun bytes -> Encoding.decode bytes)
        Encoding.encode input;
      assert_totality
        (Printf.sprintf "Envelope 1 malformed length %d" index)
        Envelope.decode Envelope.encode input)
    malformed_byte_inputs

let fixture_directory =
  let candidates = [ "fixtures/encoding"; "test/fixtures/encoding" ] in
  match List.find_opt Sys.file_exists candidates with
  | Some directory -> directory
  | None -> failwith "encoding fixtures are unavailable"

let fixture_bytes name =
  let path = Filename.concat fixture_directory name in
  let encoded =
    In_channel.with_open_bin path In_channel.input_all |> String.trim
  in
  let nibble = function
    | '0' .. '9' as character -> Char.code character - Char.code '0'
    | 'a' .. 'f' as character -> Char.code character - Char.code 'a' + 10
    | _ -> Alcotest.failf "%s is not lowercase hexadecimal" name
  in
  let length = String.length encoded in
  if length mod 2 <> 0 then
    Alcotest.failf "%s has an odd hexadecimal length" name;
  String.init (length / 2) (fun index ->
      let offset = index * 2 in
      Char.chr ((nibble encoded.[offset] lsl 4) lor nibble encoded.[offset + 1]))

let expect_profile_error name expected =
  match Encoding.decode (fixture_bytes name) with
  | Error error ->
      Alcotest.(check bool) name true (error.Encoding.kind = expected)
  | Ok _ -> Alcotest.failf "%s unexpectedly decoded" name

let expect_envelope_error name expected =
  match Envelope.decode (fixture_bytes name) with
  | Error error ->
      Alcotest.(check bool) name true (error.Envelope.kind = expected)
  | Ok _ -> Alcotest.failf "%s unexpectedly decoded" name

let fixtures () =
  List.iter
    (fun name ->
      let input = fixture_bytes name in
      match safely_decode (fun bytes -> Encoding.decode bytes) input with
      | Decoded value ->
          Alcotest.(check string) name input (Encoding.encode value)
      | Rejected -> Alcotest.failf "%s unexpectedly rejected" name
      | Raised exn -> Alcotest.failf "%s raised %s" name exn)
    [ "cbor-valid-empty-bytes.hex"; "cbor-valid-negative-integer.hex" ];
  expect_profile_error "cbor-invalid-truncated.hex" (Encoding.Truncated 1);
  expect_profile_error "cbor-invalid-reserved.hex"
    (Encoding.Reserved_additional_information 28);
  expect_profile_error "cbor-invalid-nonminimal.hex"
    (Encoding.Non_minimal_argument 0L);
  expect_profile_error "cbor-invalid-indefinite.hex" Encoding.Indefinite_length;
  expect_profile_error "cbor-invalid-utf8.hex" Encoding.Invalid_utf8_text;
  expect_profile_error "cbor-invalid-duplicate-map-key.hex"
    (Encoding.Duplicate_decoded_map_key 1L);
  expect_profile_error "cbor-invalid-unordered-map-key.hex"
    (Encoding.Non_increasing_map_key { previous = 2L; current = 1L });
  expect_profile_error "cbor-invalid-trailing.hex" (Encoding.Trailing_bytes 1);
  expect_profile_error "cbor-invalid-declared-length.hex"
    (Encoding.Declared_length_exceeds_input 65_536L);
  let valid_envelope = fixture_bytes "envelope-valid-snapshot.hex" in
  (match safely_decode Envelope.decode valid_envelope with
  | Decoded value ->
      Alcotest.(check string)
        "envelope-valid-snapshot.hex" valid_envelope (Envelope.encode value)
  | Rejected ->
      Alcotest.fail "envelope-valid-snapshot.hex unexpectedly rejected"
  | Raised exn -> Alcotest.failf "envelope-valid-snapshot.hex raised %s" exn);
  expect_envelope_error "envelope-invalid-truncated-header.hex"
    (Envelope.Truncated_header 4);
  expect_envelope_error "envelope-invalid-magic.hex" Envelope.Invalid_magic;
  expect_envelope_error "envelope-invalid-version.hex"
    (Envelope.Unsupported_envelope_version 2);
  expect_envelope_error "envelope-invalid-length-mismatch.hex"
    (Envelope.Length_mismatch { declared = 4L; actual = 3 });
  expect_envelope_error "envelope-invalid-checksum.hex"
    Envelope.Checksum_mismatch;
  expect_envelope_error "envelope-invalid-feature-bit-0.hex"
    (Envelope.Unknown_mandatory_features 1L);
  expect_envelope_error "envelope-invalid-payload.hex"
    (Envelope.Invalid_payload "byte 2: indefinite length is not permitted")

let property_case name test =
  QCheck_alcotest.to_alcotest ~speed_level:`Quick ~rand:(state_for name) test

let () =
  Alcotest.run "encoding properties"
    [
      ( "fixtures",
        [
          Alcotest.test_case "checked-in decoder inputs" `Quick fixtures;
          Alcotest.test_case "zero, boundary, near-limit, and malformed lengths"
            `Quick byte_length_boundaries;
        ] );
      ( "properties",
        [
          property_case "profile-round-trip" profile_round_trip;
          property_case "envelope-round-trip" envelope_round_trip;
          property_case "profile-decoder-totality" profile_decoder_totality;
          property_case "envelope-decoder-totality" envelope_decoder_totality;
        ] );
    ]
