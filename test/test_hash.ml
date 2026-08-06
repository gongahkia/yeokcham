module Fake_hash : Yeokcham_hash.S = struct
  let algorithm = "test-fnv1a64"
  let digest_size = 8

  type context = int64
  type digest = string

  let empty = -3750763034362895579L

  let checked_length total off = function
    | None ->
        if off < 0 || off > total then invalid_arg "hash slice offset";
        total - off
    | Some length ->
        if off < 0 || off > total || length < 0 || length > total - off then
          invalid_arg "hash slice";
        length

  let feed get total context off requested_length =
    let length = checked_length total off requested_length in
    let state = ref context in
    for index = off to off + length - 1 do
      state :=
        Int64.mul
          (Int64.logxor !state (Int64.of_int (Char.code (get index))))
          1099511628211L
    done;
    !state

  let feed_bytes context ?(off = 0) ?len input =
    feed (Bytes.get input) (Bytes.length input) context off len

  let feed_string context ?(off = 0) ?len input =
    feed (String.get input) (String.length input) context off len

  let get context =
    String.init digest_size (fun index ->
        Int64.shift_right_logical context ((digest_size - index - 1) * 8)
        |> Int64.logand 255L |> Int64.to_int |> Char.chr)

  let digest_bytes ?off ?len input = get (feed_bytes empty ?off ?len input)
  let digest_string ?off ?len input = get (feed_string empty ?off ?len input)

  let of_raw_string raw =
    if String.length raw = digest_size then Some raw else None

  let to_raw_string digest = digest
  let equal = String.equal
  let compare = String.compare
end

module Consumer (Hash : Yeokcham_hash.S) = struct
  let digest_chunks chunks =
    List.fold_left
      (fun context chunk -> Hash.feed_string context chunk)
      Hash.empty chunks
    |> Hash.get
end

module Fake_consumer = Consumer (Fake_hash)

let metadata_and_conversion () =
  Alcotest.(check bool)
    "algorithm non-empty" false
    (String.is_empty Fake_hash.algorithm);
  let digest = Fake_hash.digest_string "yeokcham" in
  let raw = Fake_hash.to_raw_string digest in
  Alcotest.(check int) "digest size" Fake_hash.digest_size (String.length raw);
  let decoded = Fake_hash.of_raw_string raw in
  Alcotest.(check bool)
    "raw round trip" true
    (match decoded with
    | None -> false
    | Some value -> Fake_hash.equal digest value);
  Alcotest.(check bool)
    "reject wrong size" true
    (Option.is_none (Fake_hash.of_raw_string "short"))

let slices_and_persistence () =
  let expected = Fake_hash.digest_string "abc" in
  let from_string = Fake_hash.digest_string ~off:2 ~len:3 "xxabcxx" in
  let from_bytes =
    Fake_hash.digest_bytes ~off:2 ~len:3 (Bytes.of_string "xxabcxx")
  in
  Alcotest.(check bool)
    "string slice" true
    (Fake_hash.equal expected from_string);
  Alcotest.(check bool) "bytes slice" true (Fake_hash.equal expected from_bytes);
  let prefix = Fake_hash.feed_string Fake_hash.empty "prefix" in
  let left = Fake_hash.get (Fake_hash.feed_string prefix "-left") in
  let right = Fake_hash.get (Fake_hash.feed_string prefix "-right") in
  Alcotest.(check bool)
    "left branch" true
    (Fake_hash.equal left (Fake_hash.digest_string "prefix-left"));
  Alcotest.(check bool)
    "right branch" true
    (Fake_hash.equal right (Fake_hash.digest_string "prefix-right"))

let arbitrary_bytes_and_split =
  QCheck2.Gen.(string_size (0 -- 4096) >>= fun raw -> pair (return raw) nat)

let chunk_property =
  QCheck2.Test.make ~count:500
    ~name:"one-shot, sliced, byte, and chunked digests agree"
    arbitrary_bytes_and_split (fun (raw, candidate) ->
      let split = candidate mod (String.length raw + 1) in
      let whole = Fake_hash.digest_string raw in
      let bytes = Fake_hash.digest_bytes (Bytes.of_string raw) in
      let sliced =
        Fake_hash.feed_string Fake_hash.empty ~off:0 ~len:split raw
        |> fun context ->
        Fake_hash.feed_string context ~off:split
          ~len:(String.length raw - split)
          raw
        |> Fake_hash.get
      in
      let chunks =
        [
          String.sub raw 0 split;
          String.sub raw split (String.length raw - split);
        ]
        |> Fake_consumer.digest_chunks
      in
      Fake_hash.equal whole bytes
      && Fake_hash.equal whole sliced
      && Fake_hash.equal whole chunks
      && Fake_hash.compare whole chunks = 0)

let () =
  Alcotest.run "hash abstraction"
    [
      ( "contract",
        [
          Alcotest.test_case "metadata and conversion" `Quick
            metadata_and_conversion;
          Alcotest.test_case "slices and persistent contexts" `Quick
            slices_and_persistence;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick chunk_property;
        ] );
    ]
