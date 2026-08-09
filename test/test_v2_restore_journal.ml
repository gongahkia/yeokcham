module Encoding = Yeokcham_encoding
module Golden = Yeokcham_testkit.Golden_fixture
module Journal = Yeokcham_v2_restore_journal
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_v2_model

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let identity of_bytes character =
  of_bytes (String.make 32 character)
  |> require_ok Model.identity_error_to_string

let sample () =
  Journal.make_prepared
    ~repository_id:(identity Model.Repository_id.of_bytes 'r')
    ~operation_id:(identity Model.Transaction_id.of_bytes 'o')
    ~safety_event_id:(identity Ledger.Event_id.of_bytes 'e')
    ~target_event_id:(identity Ledger.Event_id.of_bytes 't')
    ~safety_snapshot:(identity Model.Opaque_object_ref.of_bytes 's')
    ~target_snapshot:(identity Model.Opaque_object_ref.of_bytes 't')
    ~action_count:3 ~mandatory_features:0L
  |> require_ok Journal.error_to_string

let expected_golden name actual =
  let expected =
    Golden.read_lower_hex_file (Filename.concat "golden" name)
    |> require_ok Fun.id
  in
  Alcotest.(check string) name expected actual

let canonical_journal_fixture_and_transitions () =
  let prepared = sample () in
  let encoded = Journal.encode prepared in
  expected_golden "v2-restore-journal-v2.cbor.hex" encoded;
  let decoded = Journal.decode encoded |> require_ok Journal.error_to_string in
  Alcotest.(check int64) "prepared generation" 0L (Journal.generation decoded);
  Alcotest.(check int) "prepared count" 0 (Journal.completed_actions decoded);
  Alcotest.(check string)
    "target event survives canonical decode"
    (String.init 64 (fun index -> if index mod 2 = 0 then '7' else '4'))
    (Ledger.Event_id.to_hex (Journal.target_event_id decoded));
  let applying_zero =
    Journal.advance decoded (Journal.Applying 0)
    |> require_ok Journal.error_to_string
  in
  let applying_one =
    Journal.advance applying_zero (Journal.Applying 1)
    |> require_ok Journal.error_to_string
  in
  let applying_two =
    Journal.advance applying_one (Journal.Applying 2)
    |> require_ok Journal.error_to_string
  in
  let applying_three =
    Journal.advance applying_two (Journal.Applying 3)
    |> require_ok Journal.error_to_string
  in
  let materialized =
    Journal.advance applying_three Journal.Materialized
    |> require_ok Journal.error_to_string
  in
  let published =
    Journal.advance materialized Journal.Published
    |> require_ok Journal.error_to_string
  in
  Alcotest.(check int64)
    "published generation" 6L
    (Journal.generation published);
  Alcotest.(check int)
    "published actions complete" 3
    (Journal.completed_actions published);
  Alcotest.(check string)
    "published canonical re-encoding" (Journal.encode published)
    (Journal.decode (Journal.encode published)
    |> require_ok Journal.error_to_string
    |> Journal.encode)

let replace_field encoded index replacement =
  match Encoding.decode encoded with
  | Ok (Encoding.Array values) ->
      Encoding.array
        (List.mapi
           (fun field value ->
             if Int.equal field index then replacement else value)
           values)
      |> require_ok Encoding.construction_error_to_string
      |> Encoding.encode
  | Ok
      ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
      | Encoding.Bool _ | Encoding.Null ) ->
      Alcotest.fail "restore journal is not an array"
  | Error error -> Alcotest.fail (Encoding.decode_error_to_string error)

let invalid_records_and_transitions_reject () =
  let prepared = sample () in
  let encoded = Journal.encode prepared in
  Alcotest.(check bool)
    "cannot skip pre-action journal" true
    (Result.is_error (Journal.advance prepared (Journal.Applying 1)));
  Alcotest.(check bool)
    "cannot materialize before actions" true
    (Result.is_error (Journal.advance prepared Journal.Materialized));
  Alcotest.(check bool)
    "safety and target must differ" true
    (Result.is_error
       (Journal.make_prepared
          ~repository_id:(identity Model.Repository_id.of_bytes 'r')
          ~operation_id:(identity Model.Transaction_id.of_bytes 'o')
          ~safety_event_id:(identity Ledger.Event_id.of_bytes 'e')
          ~target_event_id:(identity Ledger.Event_id.of_bytes 't')
          ~safety_snapshot:(identity Model.Opaque_object_ref.of_bytes 's')
          ~target_snapshot:(identity Model.Opaque_object_ref.of_bytes 's')
          ~action_count:1 ~mandatory_features:0L));
  Alcotest.(check bool)
    "unknown feature rejects" true
    (Result.is_error
       (Journal.decode (replace_field encoded 11 (Encoding.integer 1L))));
  Alcotest.(check bool)
    "prepared with progress rejects" true
    (Result.is_error
       (Journal.decode (replace_field encoded 9 (Encoding.integer 1L))));
  Alcotest.(check bool)
    "trailing byte rejects" true
    (Result.is_error (Journal.decode (encoded ^ "\000")));
  Alcotest.(check bool)
    "oversized record rejects before decoding" true
    (Result.is_error
       (Journal.decode (encoded ^ String.make Journal.max_record_bytes '\000')))

let filename_and_chain_validation_are_strict () =
  let prepared = sample () in
  let filename = Journal.filename prepared in
  Alcotest.(check string)
    "prepared filename"
    ("restore-"
    ^ String.concat "" (List.init 32 (fun _ -> "6f"))
    ^ "-0000000000000000.cbor")
    filename;
  let parsed =
    Journal.parse_filename filename |> require_ok Journal.error_to_string
  in
  Alcotest.(check int64)
    "filename generation" 0L
    (Journal.journal_file_generation parsed);
  Alcotest.(check bool)
    "filename operation identity" true
    (Model.Transaction_id.equal
       (Journal.journal_file_operation_id parsed)
       (Journal.operation_id prepared));
  Alcotest.(check bool)
    "malformed filename rejects" true
    (Result.is_error
       (Journal.parse_filename
          "restore-OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO-0000000000000000.cbor"));
  let started =
    Journal.advance prepared (Journal.Applying 0)
    |> require_ok Journal.error_to_string
  in
  Alcotest.(check bool)
    "generation chain validates" true
    (Result.is_ok (Journal.validate_chain [ prepared; started ]));
  Alcotest.(check bool)
    "chain cannot start after prepared" true
    (Result.is_error (Journal.validate_chain [ started ]))

let () =
  Alcotest.run "V2 opaque restore journal"
    [
      ( "unit",
        [
          Alcotest.test_case "canonical fixture and legal transitions" `Quick
            canonical_journal_fixture_and_transitions;
          Alcotest.test_case "invalid records and transitions reject" `Quick
            invalid_records_and_transitions_reject;
          Alcotest.test_case "filename and chain validation are strict" `Quick
            filename_and_chain_validation_are_strict;
        ] );
    ]
