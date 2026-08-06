module Hash = Yeokcham_hash.Sha256

let nibble = function
  | '0' .. '9' as character -> Char.code character - Char.code '0'
  | 'a' .. 'f' as character -> Char.code character - Char.code 'a' + 10
  | 'A' .. 'F' as character -> Char.code character - Char.code 'A' + 10
  | _ -> invalid_arg "non-hex test vector"

let raw_of_hex encoded =
  let length = String.length encoded in
  if length mod 2 <> 0 then invalid_arg "odd test vector";
  String.init (length / 2) (fun index ->
      let offset = index * 2 in
      Char.chr ((nibble encoded.[offset] lsl 4) lor nibble encoded.[offset + 1]))

let vectors =
  [
    ( "empty",
      "",
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" );
    ( "one byte",
      raw_of_hex "d3",
      "28969cdfa74a12c82f3bad960b0b000aca2ac329deea5c2328ebc6f2ba9802c1" );
    ( "multiblock",
      raw_of_hex
        "451101250ec6f26652249d59dc974b7361d571a8101cdfd36aba3b5854d3ae086b5fdd4597721b66e3c0dc5d8c606d9657d0e323283a5217d1f53f2f284f57b85c8a61ac8924711f895c5ed90ef17745ed2d728abd22a5f7a13479a462d71b56c19a74a40b655c58edfe0a188ad2cf46cbf30524f65d423c837dd1ff2bf462ac4198007345bb44dbb7b1c861298cdf61982a833afc728fae1eda2f87aa2c9480858bec",
      "3c593aa539fdcdae516cdf2f15000f6634185c88f505b39775fb9ab137a10aa2" );
    ( "million bytes",
      String.make 1_000_000 'a',
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0" );
  ]

let published_vectors () =
  List.iter
    (fun (name, input, expected_hex) ->
      let actual = Hash.digest_string input |> Hash.to_raw_string in
      Alcotest.(check string) name (raw_of_hex expected_hex) actual)
    vectors

let metadata_and_raw_conversion () =
  Alcotest.(check string) "algorithm" "sha256" Hash.algorithm;
  Alcotest.(check int) "digest size" 32 Hash.digest_size;
  let digest = Hash.digest_string "yeokcham" in
  let raw = Hash.to_raw_string digest in
  Alcotest.(check int) "raw size" Hash.digest_size (String.length raw);
  Alcotest.(check bool)
    "raw round trip" true
    (match Hash.of_raw_string raw with
    | None -> false
    | Some decoded ->
        Hash.equal digest decoded && Hash.compare digest decoded = 0);
  Alcotest.(check bool)
    "reject short raw" true
    (Option.is_none (Hash.of_raw_string (String.make 31 '\000')));
  Alcotest.(check bool)
    "reject long raw" true
    (Option.is_none (Hash.of_raw_string (String.make 33 '\000')))

let arbitrary_input =
  QCheck2.Gen.(string_size (0 -- 8192) >>= fun raw -> pair (return raw) nat)

let chunked_digest raw width =
  let rec feed context offset =
    if offset = String.length raw then Hash.get context
    else
      let length = min width (String.length raw - offset) in
      feed
        (Hash.feed_string context ~off:offset ~len:length raw)
        (offset + length)
  in
  feed Hash.empty 0

let chunk_property =
  QCheck2.Test.make ~count:300
    ~name:"one-shot string, bytes, and variable chunks agree" arbitrary_input
    (fun (raw, candidate) ->
      let width = (candidate mod 257) + 1 in
      let string_digest = Hash.digest_string raw in
      let bytes_digest = Hash.digest_bytes (Bytes.of_string raw) in
      let chunk_digest = chunked_digest raw width in
      Hash.equal string_digest bytes_digest
      && Hash.equal string_digest chunk_digest
      && String.length (Hash.to_raw_string string_digest) = Hash.digest_size)

let () =
  Alcotest.run "SHA-256"
    [
      ( "implementation",
        [
          Alcotest.test_case "published vectors" `Quick published_vectors;
          Alcotest.test_case "metadata and raw conversion" `Quick
            metadata_and_raw_conversion;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick chunk_property;
        ] );
    ]
