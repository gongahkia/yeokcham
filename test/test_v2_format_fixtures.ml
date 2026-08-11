module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_v2_model
module Object = Yeokcham_v2_object

let default_seed = 20_260_729

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  !value

let state_for name = Random.State.make [| stable_seed name |]
let () = Printf.printf "v2 format fixture property base seed: %d\n%!" base_seed

let require_ok error_to_string = function
  | Ok value -> value
  | Error error -> Alcotest.fail (error_to_string error)

let fixture_path name = Filename.concat "golden" name

let read name =
  Golden.read_lower_hex_file (fixture_path name) |> require_ok Fun.id

let canonical_envelope name =
  Golden.decode_canonical_lower_hex_file ~path:(fixture_path name)
    ~decode:Envelope.decode ~encode:Envelope.encode
    ~error_to_string:Envelope.error_to_string
  |> require_ok Fun.id

let canonical_ledger name =
  Golden.decode_canonical_lower_hex_file ~path:(fixture_path name)
    ~decode:Ledger.decode ~encode:Ledger.encode
    ~error_to_string:Ledger.error_to_string
  |> require_ok Fun.id

let canonical_object name =
  Golden.decode_canonical_lower_hex_file ~path:(fixture_path name)
    ~decode:Object.decode ~encode:Object.encode
    ~error_to_string:Object.error_to_string
  |> require_ok Fun.id

let repository_id =
  Model.Repository_id.of_bytes (String.make 32 'r')
  |> require_ok Model.identity_error_to_string

let address_key =
  Address.key_of_bytes (String.make 32 'a')
  |> require_ok Address.error_to_string

let encryption_key =
  Envelope.key_of_bytes (String.make 32 'e')
  |> require_ok Envelope.error_to_string

let valid_fixtures_are_exact_and_canonical () =
  ignore (canonical_envelope "v2-ciphertext-envelope-v1.cbor.hex");
  let generic_address =
    Model.Opaque_object_ref.of_bytes (read "v2-opaque-object-address-v1.hex")
    |> require_ok Model.identity_error_to_string
  in
  Alcotest.(check string)
    "canonical generic opaque identity fixture"
    (read "v2-opaque-object-address-v1.hex")
    (Model.Opaque_object_ref.to_bytes generic_address);
  let ledger_event = canonical_ledger "v2-ref-ledger-event-v1.cbor.hex" in
  let ledger_frame = canonical_object "v2-object-ledger-frame-v1.cbor.hex" in
  ignore (canonical_object "v2-object-scratch-snapshot-frame-v1.cbor.hex");
  ignore (canonical_object "v2-object-capsule-frame-v1.cbor.hex");
  ignore (canonical_object "v2-object-capsule-revision-frame-v1.cbor.hex");
  ignore (canonical_object "v2-object-capsule-revision-frame-v2.cbor.hex");
  ignore (canonical_object "v2-object-workspace-frame-v1.cbor.hex");
  ignore (canonical_object "v2-object-workspace-revision-frame-v1.cbor.hex");
  ignore (canonical_object "v2-object-workspace-attempt-frame-v1.cbor.hex");
  ignore (canonical_object "v2-object-conflict-frame-v1.cbor.hex");
  ignore (canonical_object "v2-object-resolution-frame-v1.cbor.hex");
  let ledger_envelope =
    canonical_envelope "v2-ref-ledger-envelope-v1.cbor.hex"
  in
  Alcotest.(check string)
    "ledger envelope decrypts to the canonical ledger frame fixture"
    (read "v2-object-ledger-frame-v1.cbor.hex")
    (Envelope.open_envelope ~key:encryption_key ledger_envelope
    |> require_ok Envelope.error_to_string);
  Alcotest.(check bool)
    "ledger typed frame retains the canonical event" true
    (match Object.ledger ledger_frame with
    | Some event ->
        Ledger.Event_id.equal
          (Ledger.event_id ledger_event)
          (Ledger.event_id event)
    | None -> false);
  Alcotest.(check bool)
    "ledger event ID survives canonical fixture decoding" true
    (Ledger.Event_id.equal
       (Ledger.event_id ledger_event)
       (Ledger.event_id (canonical_ledger "v2-ref-ledger-event-v1.cbor.hex")));
  let ledger_address =
    Address.derive ~repository_id ~key:address_key ~envelope:ledger_envelope
  in
  Alcotest.(check string)
    "canonical encrypted ledger opaque address fixture"
    (read "v2-ref-ledger-opaque-address-v1.hex")
    (Model.Opaque_object_ref.to_bytes ledger_address)

let expect_envelope_fixture_error name predicate =
  match Envelope.decode (read name) with
  | Error error when predicate error -> ()
  | Error error ->
      Alcotest.failf "%s returned the wrong error: %s" name
        (Envelope.error_to_string error)
  | Ok _ -> Alcotest.failf "%s unexpectedly decoded" name

let expect_ledger_fixture_error name predicate =
  match Ledger.decode (read name) with
  | Error error when predicate error -> ()
  | Error error ->
      Alcotest.failf "%s returned the wrong error: %s" name
        (Ledger.error_to_string error)
  | Ok _ -> Alcotest.failf "%s unexpectedly decoded" name

let expect_object_fixture_error name predicate =
  match Object.decode (read name) with
  | Error error when predicate error -> ()
  | Error error ->
      Alcotest.failf "%s returned the wrong error: %s" name
        (Object.error_to_string error)
  | Ok _ -> Alcotest.failf "%s unexpectedly decoded" name

let fixed_invalid_fixtures_reject_with_typed_errors () =
  List.iter
    (fun name ->
      expect_envelope_fixture_error name ((function
        | Envelope.Invalid_payload _ -> true
        | _ -> false)
        [@warning "-4"]))
    [
      "v2-ciphertext-envelope-v1.truncated.cbor.hex";
      "v2-ciphertext-envelope-v1.trailing.cbor.hex";
    ];
  expect_envelope_fixture_error
    "v2-ciphertext-envelope-v1.unknown-feature.cbor.hex" (function
    | Envelope.Unsupported_mandatory_features 1L -> true
    | _ -> false)
  [@warning "-4"];
  List.iter
    (fun name ->
      expect_ledger_fixture_error name ((function
        | Ledger.Invalid_payload _ -> true
        | _ -> false)
        [@warning "-4"]))
    [
      "v2-ref-ledger-event-v1.truncated.cbor.hex";
      "v2-ref-ledger-event-v1.trailing.cbor.hex";
    ];
  expect_ledger_fixture_error "v2-ref-ledger-event-v1.unknown-feature.cbor.hex"
    (function
    | Ledger.Unsupported_mandatory_features 1L -> true
    | _ -> false)
  [@warning "-4"];
  expect_ledger_fixture_error "v2-ref-ledger-event-v1.wrong-event-id.cbor.hex"
    (function
    | Ledger.Invalid_event_id -> true
    | _ -> false)
  [@warning "-4"];
  List.iter
    (fun name ->
      expect_object_fixture_error name ((function
        | Object.Invalid_payload _ -> true
        | _ -> false)
        [@warning "-4"]))
    [
      "v2-object-scratch-snapshot-frame-v1.truncated.cbor.hex";
      "v2-object-scratch-snapshot-frame-v1.trailing.cbor.hex";
    ];
  expect_object_fixture_error
    "v2-object-scratch-snapshot-frame-v1.unknown-kind.cbor.hex" (function
    | Object.Unknown_kind 11L -> true
    | _ -> false)
  [@warning "-4"];
  expect_object_fixture_error
    "v2-object-scratch-snapshot-frame-v1.unknown-feature.cbor.hex" (function
    | Object.Unsupported_mandatory_features 1L -> true
    | _ -> false)
  [@warning "-4"];
  let envelope = canonical_envelope "v2-ciphertext-envelope-v1.cbor.hex" in
  let wrong_address =
    Model.Opaque_object_ref.of_bytes
      (read "v2-opaque-object-address-v1.wrong-identity.hex")
    |> require_ok Model.identity_error_to_string
  in
  (match
     Address.verify ~repository_id ~key:address_key ~address:wrong_address
       ~envelope
   with
  | Error (Address.Address_mismatch _) -> ()
  | Ok () -> Alcotest.fail "wrong opaque address unexpectedly verified"
  | Error error ->
      Alcotest.failf "wrong opaque address returned the wrong error: %s"
        (Address.error_to_string error))
  [@warning "-4"]

let envelope_bytes = read "v2-ciphertext-envelope-v1.cbor.hex"

let fixed_envelope_truncations_reject =
  QCheck2.Test.make ~count:100
    ~name:"every fixture-derived proper envelope truncation rejects"
    QCheck2.Gen.(int_range 0 (String.length envelope_bytes - 1))
    (fun length ->
      match Golden.truncate envelope_bytes ~length with
      | Error _ -> false
      | Ok truncated -> Result.is_error (Envelope.decode truncated))

let () =
  Alcotest.run "V2 canonical format fixtures"
    [
      ( "unit",
        [
          Alcotest.test_case "valid fixtures are exact and canonical" `Quick
            valid_fixtures_are_exact_and_canonical;
          Alcotest.test_case "fixed corrupt fixtures reject with typed errors"
            `Quick fixed_invalid_fixtures_reject_with_typed_errors;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "envelope-truncations")
            fixed_envelope_truncations_reject;
        ] );
    ]
