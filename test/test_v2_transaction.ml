module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_v2_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_v2_model
module Transaction = Yeokcham_v2_transaction

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let repository_id =
  Model.Repository_id.of_bytes (String.make 32 'r')
  |> require_ok Model.identity_error_to_string

let transaction_id character =
  Model.Transaction_id.of_bytes (String.make 32 character)
  |> require_ok Model.identity_error_to_string

let object_ref character =
  Model.Opaque_object_ref.of_bytes (String.make 32 character)
  |> require_ok Model.identity_error_to_string

let encryption_key =
  Envelope.key_of_bytes (String.make 32 'e')
  |> require_ok Envelope.error_to_string

let envelope character =
  let nonce =
    Envelope.nonce_of_bytes (String.make 12 character)
    |> require_ok Envelope.error_to_string
  in
  Envelope.seal ~key:encryption_key ~nonce ~mandatory_features:0L
    ("transaction fixture " ^ String.make 1 character)
  |> require_ok Envelope.error_to_string

let sample_prepare () =
  Transaction.make_prepare ~repository_id ~transaction_id:(transaction_id 't')
    ~mandatory_features:0L
    [
      Transaction.stage ~object_ref:(object_ref 'a') ~envelope:(envelope 'a');
      Transaction.stage ~object_ref:(object_ref 'b') ~envelope:(envelope 'b');
    ]
  |> require_ok Transaction.error_to_string

let refreshed_golden name actual =
  Golden.refresh_lower_hex_file (Filename.concat "golden" name) actual
  |> require_ok Fun.id

let canonical_prepare_and_commit_goldens () =
  let prepare = sample_prepare () in
  let commit = Transaction.make_commit prepare in
  let prepare_bytes = Transaction.encode_prepare prepare in
  let commit_bytes = Transaction.encode_commit commit in
  Alcotest.(check string)
    "canonical prepare bytes"
    (refreshed_golden "v2-transaction-prepare-v1.cbor.hex" prepare_bytes)
    prepare_bytes;
  Alcotest.(check string)
    "canonical commit bytes"
    (refreshed_golden "v2-transaction-commit-v1.cbor.hex" commit_bytes)
    commit_bytes;
  let decoded_prepare =
    Transaction.decode_prepare prepare_bytes
    |> require_ok Transaction.error_to_string
  in
  let decoded_commit =
    Transaction.decode_commit commit_bytes
    |> require_ok Transaction.error_to_string
  in
  Transaction.validate_commit ~prepare:decoded_prepare decoded_commit
  |> require_ok Transaction.error_to_string;
  Alcotest.(check string)
    "prepare digest binds canonical prepare bytes"
    (Transaction.prepare_digest prepare)
    (Transaction.commit_prepare_digest commit)

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
      Alcotest.fail "transaction record is not an array"
  | Error error -> Alcotest.fail (Encoding.decode_error_to_string error)

let staged_entries encoded =
  match Encoding.decode encoded with
  | Ok (Encoding.Array [ _; _; _; _; Encoding.Array entries ]) -> entries
  | Ok
      ( Encoding.Array _ | Encoding.Integer _ | Encoding.Bytes _
      | Encoding.Text _ | Encoding.Map _ | Encoding.Bool _ | Encoding.Null ) ->
      Alcotest.fail "transaction prepare has no staged entry array"
  | Error error -> Alcotest.fail (Encoding.decode_error_to_string error)

let expected_fixture name bytes =
  Alcotest.(check string) name (refreshed_golden name bytes) bytes

let malformed_records_and_names_fail_closed () =
  let prepare = sample_prepare () in
  let prepare_bytes = Transaction.encode_prepare prepare in
  let commit = Transaction.make_commit prepare in
  let commit_bytes = Transaction.encode_commit commit in
  let entries = staged_entries prepare_bytes in
  let first, second =
    match entries with
    | [ first; second ] -> (first, second)
    | _ -> Alcotest.fail "sample prepare should contain two entries"
  in
  let truncated =
    Golden.truncate prepare_bytes ~length:(String.length prepare_bytes - 1)
    |> require_ok Fun.id
  in
  let trailing = prepare_bytes ^ "\000" in
  let unknown_feature = replace_field prepare_bytes 3 (Encoding.integer 1L) in
  let duplicate =
    replace_field prepare_bytes 4
      (Encoding.array [ first; first ]
      |> require_ok Encoding.construction_error_to_string)
  in
  let reordered =
    replace_field prepare_bytes 4
      (Encoding.array [ second; first ]
      |> require_ok Encoding.construction_error_to_string)
  in
  let mismatched_commit =
    replace_field commit_bytes 2 (Encoding.bytes (String.make 32 'm'))
  in
  expected_fixture "v2-transaction-prepare-v1.truncated.cbor.hex" truncated;
  expected_fixture "v2-transaction-prepare-v1.trailing.cbor.hex" trailing;
  expected_fixture "v2-transaction-prepare-v1.unknown-feature.cbor.hex"
    unknown_feature;
  expected_fixture "v2-transaction-prepare-v1.duplicate-object-ref.cbor.hex"
    duplicate;
  expected_fixture "v2-transaction-prepare-v1.reordered-object-ref.cbor.hex"
    reordered;
  expected_fixture "v2-transaction-commit-v1.mismatched-prepare.cbor.hex"
    mismatched_commit;
  Alcotest.(check bool)
    "prepare trailing byte rejects" true
    (Result.is_error
       (Transaction.decode_prepare
          (refreshed_golden "v2-transaction-prepare-v1.trailing.cbor.hex"
             trailing)));
  Alcotest.(check bool)
    "prepare truncation rejects" true
    (Result.is_error
       (Transaction.decode_prepare
          (refreshed_golden "v2-transaction-prepare-v1.truncated.cbor.hex"
             truncated)));
  Alcotest.(check bool)
    "commit trailing byte rejects" true
    (Result.is_error (Transaction.decode_commit (commit_bytes ^ "\000")));
  Alcotest.(check bool)
    "oversized commit rejects before decoding" true
    (Result.is_error
       (Transaction.decode_commit
          (commit_bytes ^ String.make Transaction.max_commit_bytes '\000')));
  Alcotest.(check bool)
    "unknown prepare feature rejects" true
    (Result.is_error
       (Transaction.decode_prepare
          (refreshed_golden "v2-transaction-prepare-v1.unknown-feature.cbor.hex"
             unknown_feature)));
  Alcotest.(check bool)
    "duplicate fixture rejects" true
    (Result.is_error
       (Transaction.decode_prepare
          (refreshed_golden
             "v2-transaction-prepare-v1.duplicate-object-ref.cbor.hex" duplicate)));
  Alcotest.(check bool)
    "reordered fixture rejects" true
    (Result.is_error
       (Transaction.decode_prepare
          (refreshed_golden
             "v2-transaction-prepare-v1.reordered-object-ref.cbor.hex" reordered)));
  let duplicate_ref_prepare =
    Transaction.make_prepare ~repository_id ~transaction_id:(transaction_id 'd')
      ~mandatory_features:0L
      [
        Transaction.stage ~object_ref:(object_ref 'a') ~envelope:(envelope 'a');
        Transaction.stage ~object_ref:(object_ref 'a') ~envelope:(envelope 'b');
      ]
  in
  Alcotest.(check bool)
    "duplicate addresses reject" true
    (Result.is_error duplicate_ref_prepare);
  let reordered_prepare =
    Transaction.make_prepare ~repository_id ~transaction_id:(transaction_id 'o')
      ~mandatory_features:0L
      [
        Transaction.stage ~object_ref:(object_ref 'b') ~envelope:(envelope 'b');
        Transaction.stage ~object_ref:(object_ref 'a') ~envelope:(envelope 'a');
      ]
  in
  Alcotest.(check bool)
    "reordered addresses reject" true
    (Result.is_error reordered_prepare);
  let different_prepare =
    Transaction.make_prepare ~repository_id ~transaction_id:(transaction_id 't')
      ~mandatory_features:0L
      [
        Transaction.stage ~object_ref:(object_ref 'c') ~envelope:(envelope 'c');
      ]
    |> require_ok Transaction.error_to_string
  in
  Alcotest.(check bool)
    "commit cannot bind different prepare bytes" true
    (Result.is_error
       (Transaction.validate_commit ~prepare:different_prepare commit));
  let mismatched_commit =
    Transaction.decode_commit
      (refreshed_golden "v2-transaction-commit-v1.mismatched-prepare.cbor.hex"
         mismatched_commit)
    |> require_ok Transaction.error_to_string
  in
  Alcotest.(check bool)
    "mismatched commit fixture rejects" true
    (Result.is_error (Transaction.validate_commit ~prepare mismatched_commit));
  List.iter
    (fun name ->
      Alcotest.(check bool)
        ("unsafe journal name " ^ name)
        true
        (Result.is_error (Transaction.parse_journal_filename name)))
    [
      "../" ^ Transaction.prepare_filename (transaction_id 't');
      String.uppercase_ascii (Transaction.prepare_filename (transaction_id 't'));
      "short.prepare";
      Transaction.prepare_filename (transaction_id 't') ^ ".bak";
    ];
  Alcotest.(check bool)
    "known private temporary is recognized" true
    (Transaction.is_temporary_journal_filename
       ("." ^ Transaction.prepare_filename (transaction_id 't') ^ ".tmp-42-0"));
  Alcotest.(check bool)
    "unsafe temporary is not recognized" false
    (Transaction.is_temporary_journal_filename ".../prepare.tmp-42-0")

let () =
  Alcotest.run "V2 durable object transaction records"
    [
      ( "unit",
        [
          Alcotest.test_case "canonical prepare and commit goldens" `Quick
            canonical_prepare_and_commit_goldens;
          Alcotest.test_case "malformed records and unsafe names fail closed"
            `Quick malformed_records_and_names_fail_closed;
        ] );
    ]
