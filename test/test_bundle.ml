module Bundle = Yeokcham_bundle
module Bundle_store = Yeokcham_bundle_store
module Divergence_store = Yeokcham_divergence_store
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Store = Yeokcham_store

let require format = function
  | Ok value -> value
  | Error error -> Alcotest.fail (format error)

let require_bundle result = require Bundle.error_to_string result
let require_bundle_store result = require Bundle_store.error_to_string result
let require_envelope result = require Envelope.creation_error_to_string result
let require_store result = require Store.error_to_string result

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

let refreshed_golden name actual =
  Golden.refresh_lower_hex_file (Filename.concat "golden" name) actual
  |> require Fun.id

let key =
  Bundle.key_of_bytes (String.init 32 (fun index -> Char.chr index))
  |> require_bundle

let wrong_key =
  Bundle.key_of_bytes (String.init 32 (fun index -> Char.chr (index + 32)))
  |> require_bundle

let nonce =
  Bundle.nonce_of_bytes (String.init 12 (fun index -> Char.chr (index + 64)))
  |> require_bundle

let content bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require_envelope

let sample_entries () =
  [ content "bundle-a"; content "bundle-b" ]
  |> List.map (fun envelope ->
      Bundle.entry_of_envelope
        ~object_id:(Store.id_of_envelope envelope)
        envelope
      |> require_bundle)

let sample_plaintext () =
  Bundle.make_plaintext (sample_entries ()) |> require_bundle

let sample_bundle () =
  Bundle.seal ~repository_format:Store.repository_format ~key ~nonce
    (sample_plaintext ())
  |> require_bundle

let encoding_text value =
  Encoding.text value |> require Encoding.construction_error_to_string

let replace_bundle_field bytes index replacement =
  match Encoding.decode bytes with
  | Ok (Encoding.Array values) ->
      Encoding.array
        (List.mapi
           (fun field value ->
             if Int.equal field index then replacement else value)
           values)
      |> require Encoding.construction_error_to_string
      |> Encoding.encode
  | Ok
      ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
      | Encoding.Bool _ | Encoding.Null ) ->
      Alcotest.fail "bundle outer container is not an array"
  | Error error -> Alcotest.fail (Encoding.decode_error_to_string error)

let alter_bytes bytes =
  if String.length bytes = 0 then Alcotest.fail "cannot alter empty bytes";
  String.init (String.length bytes) (fun index ->
      if index = 0 then Char.chr (Char.code bytes.[index] lxor 1)
      else bytes.[index])

let alter_last_byte bytes =
  if String.length bytes = 0 then Alcotest.fail "cannot alter empty bytes";
  let last = String.length bytes - 1 in
  String.init (String.length bytes) (fun index ->
      if Int.equal index last then Char.chr (Char.code bytes.[index] lxor 1)
      else bytes.[index])

let rec remove_tree path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove_tree (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_repositories run =
  let root = Filename.temp_file "yeokcham-bundle-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let source_root = Filename.concat root "source" in
  let destination_root = Filename.concat root "destination" in
  Unix.mkdir source_root 0o700;
  Unix.mkdir destination_root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let source = Store.init ~root:source_root |> require_store in
      let destination = Store.init ~root:destination_root |> require_store in
      run source destination)

let equal_object_id_lists left right =
  List.length left = List.length right
  && List.for_all2 Store.Stored_object_id.equal left right

let assert_ref_unchanged repository reference =
  let actual =
    Store.read_ref repository ~name:"scratch-head" |> require_store
  in
  Alcotest.(check bool)
    "application ref is unchanged" true
    (Option.exists (Store.Mutable_ref.equal reference) actual)

let canonical_fixtures_and_inverses () =
  let plaintext = sample_plaintext () in
  let bundle = sample_bundle () in
  let plaintext_bytes = Bundle.plaintext_bytes plaintext in
  let header_bytes = Bundle.header_bytes bundle in
  let bundle_bytes = Bundle.encode bundle in
  Alcotest.(check string)
    "plaintext fixture"
    (refreshed_golden "encrypted-bundle-plaintext-v1.yeok.hex" plaintext_bytes)
    plaintext_bytes;
  Alcotest.(check string)
    "header fixture"
    (refreshed_golden "encrypted-bundle-header-v1.cbor.hex" header_bytes)
    header_bytes;
  Alcotest.(check string)
    "outer fixture"
    (refreshed_golden "encrypted-bundle-v1.cbor.hex" bundle_bytes)
    bundle_bytes;
  let decoded_plaintext =
    Bundle.decode_plaintext (Bundle.plaintext_bytes plaintext) |> require_bundle
  in
  Alcotest.(check string)
    "plaintext decoder inverse"
    (Bundle.plaintext_bytes plaintext)
    (Bundle.plaintext_bytes decoded_plaintext);
  let decoded = Bundle.decode (Bundle.encode bundle) |> require_bundle in
  let opened =
    Bundle.open_bundle ~repository_format:Store.repository_format ~key decoded
    |> require_bundle
  in
  Alcotest.(check string)
    "plaintext inverse"
    (Bundle.plaintext_bytes plaintext)
    (Bundle.plaintext_bytes opened);
  let reordered =
    Bundle.make_plaintext (List.rev (sample_entries ())) |> require_bundle
  in
  Alcotest.(check string)
    "entry order is canonical"
    (Bundle.plaintext_bytes plaintext)
    (Bundle.plaintext_bytes reordered);
  let duplicate = List.hd (sample_entries ()) in
  Alcotest.(check bool)
    "duplicate object ID rejects" true
    (Result.is_error (Bundle.make_plaintext [ duplicate; duplicate ]));
  Alcotest.(check bool)
    "trailing outer bytes reject" true
    (Result.is_error (Bundle.decode (Bundle.encode bundle ^ "\000")));
  Alcotest.(check bool)
    "trailing plaintext bytes reject" true
    (Result.is_error
       (Bundle.decode_plaintext (Bundle.plaintext_bytes plaintext ^ "\000")));
  Alcotest.(check bool)
    "malformed plaintext rejects" true
    (Result.is_error (Bundle.decode_plaintext ""))

let rfc8439_aead_vector () =
  let key =
    Mirage_crypto.Chacha20.of_secret
      (raw_of_hex
         "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
  in
  let nonce = raw_of_hex "070000004041424344454647" in
  let adata = raw_of_hex "50515253c0c1c2c3c4c5c6c7" in
  let plaintext =
    raw_of_hex
      "4c616469657320616e642047656e746c656d656e206f662074686520636c617373206f66202739393a204966204920636f756c64206f6666657220796f75206f6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73637265656e20776f756c642062652069742e"
  in
  let expected =
    raw_of_hex
      "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b61161ae10b594f09e26a7e902ecbd0600691"
  in
  let actual =
    Mirage_crypto.Chacha20.authenticate_encrypt ~key ~nonce ~adata plaintext
  in
  Alcotest.(check string) "RFC 8439 AEAD" expected actual;
  Alcotest.(check (option string))
    "RFC 8439 AEAD inverse" (Some plaintext)
    (Mirage_crypto.Chacha20.authenticate_decrypt ~key ~nonce ~adata actual)

let rejection_paths () =
  let bundle = sample_bundle () in
  Alcotest.(check bool)
    "short key rejects" true
    (Result.is_error (Bundle.key_of_bytes "short"));
  Alcotest.(check bool)
    "short nonce rejects" true
    (Result.is_error (Bundle.nonce_of_bytes "short"));
  Alcotest.(check bool)
    "wrong key rejects" true
    (Result.is_error
       (Bundle.open_bundle ~repository_format:Store.repository_format
          ~key:wrong_key bundle));
  Alcotest.(check bool)
    "wrong repository rejects" true
    (Result.is_error
       (Bundle.open_bundle ~repository_format:"yeokcham-test-format" ~key bundle));
  let altered_nonce =
    replace_bundle_field (Bundle.encode bundle) 3
      (Encoding.bytes (String.make 12 '\255'))
    |> Bundle.decode |> require_bundle
  in
  Alcotest.(check bool)
    "altered authenticated nonce rejects" true
    (Result.is_error
       (Bundle.open_bundle ~repository_format:Store.repository_format ~key
          altered_nonce));
  let altered_ciphertext =
    replace_bundle_field (Bundle.encode bundle) 4
      (Encoding.bytes
         (match Encoding.decode (Bundle.encode bundle) with
         | Ok (Encoding.Array [ _; _; _; _; Encoding.Bytes ciphertext; _ ]) ->
             alter_bytes ciphertext
         | Ok
             ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
             | Encoding.Map _ | Encoding.Bool _ | Encoding.Null
             | Encoding.Array _ ) ->
             Alcotest.fail "bundle ciphertext field is absent"
         | Error error -> Alcotest.fail (Encoding.decode_error_to_string error)))
    |> Bundle.decode |> require_bundle
  in
  Alcotest.(check bool)
    "altered ciphertext rejects" true
    (Result.is_error
       (Bundle.open_bundle ~repository_format:Store.repository_format ~key
          altered_ciphertext));
  let altered_tag =
    replace_bundle_field (Bundle.encode bundle) 4
      (Encoding.bytes
         (match Encoding.decode (Bundle.encode bundle) with
         | Ok (Encoding.Array [ _; _; _; _; Encoding.Bytes ciphertext; _ ]) ->
             alter_last_byte ciphertext
         | Ok
             ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _
             | Encoding.Map _ | Encoding.Bool _ | Encoding.Null
             | Encoding.Array _ ) ->
             Alcotest.fail "bundle ciphertext field is absent"
         | Error error -> Alcotest.fail (Encoding.decode_error_to_string error)))
    |> Bundle.decode |> require_bundle
  in
  Alcotest.(check bool)
    "altered tag rejects" true
    (Result.is_error
       (Bundle.open_bundle ~repository_format:Store.repository_format ~key
          altered_tag));
  let unsupported_version =
    replace_bundle_field (Bundle.encode bundle) 0 (Encoding.integer 2L)
    |> Bundle.decode
  in
  Alcotest.(check bool)
    "unsupported version rejects" true
    (Result.is_error unsupported_version);
  let unsupported_feature =
    replace_bundle_field (Bundle.encode bundle) 5 (Encoding.integer 1L)
    |> Bundle.decode
  in
  Alcotest.(check bool)
    "unsupported feature rejects" true
    (Result.is_error unsupported_feature);
  let unsupported_algorithm =
    replace_bundle_field (Bundle.encode bundle) 1 (encoding_text "other-aead")
    |> Bundle.decode
  in
  Alcotest.(check bool)
    "unsupported algorithm rejects" true
    (Result.is_error unsupported_algorithm)

let import_is_idempotent_and_keeps_refs_unchanged () =
  with_repositories (fun source destination ->
      let source_envelopes = [ content "source-a"; content "source-b" ] in
      let source_ids =
        List.map (Store.put source) source_envelopes |> List.map require_store
      in
      let retained =
        Store.put destination (content "destination") |> require_store
      in
      let reference =
        Store.compare_and_swap_ref destination ~name:"scratch-head"
          ~expected:None ~target:(Some retained)
        |> require_store
      in
      let components =
        Divergence_store.binding_components ~ref_name:"scratch-head"
      in
      let binding = Divergence_store.encode_binding retained in
      Store.Ref_file.compare_and_swap destination ~components ~expected:None
        ~replacement:binding
      |> require_store;
      let exported =
        Bundle_store.export source ~key ~object_ids:(List.rev source_ids)
        |> require_bundle_store
      in
      let reexported =
        Bundle_store.export source ~key ~object_ids:source_ids
        |> require_bundle_store
      in
      Alcotest.(check bool)
        "fresh export bytes differ" true
        (not (String.equal exported reexported));
      let imported =
        Bundle_store.import destination ~key exported |> require_bundle_store
      in
      Alcotest.(check bool)
        "imported IDs are canonical" true
        (equal_object_id_lists
           (List.sort Store.Stored_object_id.compare source_ids)
           imported);
      List.iter2
        (fun source_envelope object_id ->
          let destination_envelope =
            Store.get destination object_id |> require_store
          in
          Alcotest.(check string)
            "exact Envelope bytes survive import"
            (Envelope.encode source_envelope)
            (Envelope.encode destination_envelope))
        source_envelopes source_ids;
      assert_ref_unchanged destination reference;
      Alcotest.(check (option string))
        "divergence binding is unchanged" (Some binding)
        (Store.Ref_file.read destination ~components |> require_store);
      let reopened =
        Store.open_repository ~root:(Store.root destination) |> require_store
      in
      let retried =
        Bundle_store.import reopened ~key exported |> require_bundle_store
      in
      Alcotest.(check bool)
        "retry is idempotent" true
        (equal_object_id_lists imported retried);
      assert_ref_unchanged reopened reference)

let empty_and_bounded_exports () =
  with_repositories (fun source destination ->
      let retained =
        Store.put destination (content "destination") |> require_store
      in
      let reference =
        Store.compare_and_swap_ref destination ~name:"scratch-head"
          ~expected:None ~target:(Some retained)
        |> require_store
      in
      let empty =
        Bundle_store.export source ~key ~object_ids:[] |> require_bundle_store
      in
      Alcotest.(check (list string))
        "empty import has no objects" []
        (Bundle_store.import destination ~key empty
        |> require_bundle_store
        |> List.map Store.Stored_object_id.to_hex);
      assert_ref_unchanged destination reference;
      let object_id = Store.put source (content "source") |> require_store in
      let oversized = List.init (Bundle.max_entries + 1) (fun _ -> object_id) in
      Alcotest.(check bool)
        "oversized export rejects before reads" true
        (Result.is_error
           (Bundle_store.export source ~key ~object_ids:oversized)))

let rejected_import_publishes_nothing () =
  with_repositories (fun source destination ->
      let source_id =
        Store.put source (content "source-only") |> require_store
      in
      let retained =
        Store.put destination (content "destination") |> require_store
      in
      let reference =
        Store.compare_and_swap_ref destination ~name:"scratch-head"
          ~expected:None ~target:(Some retained)
        |> require_store
      in
      let exported =
        Bundle_store.export source ~key ~object_ids:[ source_id ]
        |> require_bundle_store
      in
      Alcotest.(check bool)
        "wrong key import rejects" true
        (Result.is_error
           (Bundle_store.import destination ~key:wrong_key exported));
      Alcotest.(check bool)
        "wrong key imports nothing" true
        (Result.is_error (Store.get destination source_id));
      assert_ref_unchanged destination reference;
      Alcotest.(check bool)
        "noncanonical outer import rejects" true
        (Result.is_error
           (Bundle_store.import destination ~key (exported ^ "\000")));
      Alcotest.(check bool)
        "noncanonical outer imports nothing" true
        (Result.is_error (Store.get destination source_id));
      assert_ref_unchanged destination reference)

let () =
  Alcotest.run "encrypted bundles"
    [
      ( "bundle",
        [
          Alcotest.test_case "canonical fixtures and inverses" `Quick
            canonical_fixtures_and_inverses;
          Alcotest.test_case "RFC 8439 AEAD vector" `Quick rfc8439_aead_vector;
          Alcotest.test_case "structured rejection paths" `Quick rejection_paths;
          Alcotest.test_case "durable idempotent import" `Quick
            import_is_idempotent_and_keeps_refs_unchanged;
          Alcotest.test_case "empty and bounded exports" `Quick
            empty_and_bounded_exports;
          Alcotest.test_case "rejected import publishes nothing" `Quick
            rejected_import_publishes_nothing;
        ] );
    ]
