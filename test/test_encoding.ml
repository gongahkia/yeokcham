module Encoding = Paengi_encoding

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

let require_construction = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Encoding.construction_error_to_string error)

let require_limits = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Encoding.limit_error_to_string error)

let require_decode input =
  match Encoding.decode input with
  | Ok value -> value
  | Error error -> Alcotest.fail (Encoding.decode_error_to_string error)

let require_error input =
  match Encoding.decode input with
  | Error error -> error
  | Ok _ -> Alcotest.fail "decoder unexpectedly accepted input"

let construction_result result =
  result
  |> Result.map (fun _ -> ())
  |> Result.map_error Encoding.construction_error_to_string

let text value = require_construction (Encoding.text value)
let array values = require_construction (Encoding.array values)
let map entries = require_construction (Encoding.map entries)

let rfc_vectors =
  [
    ("zero", Encoding.integer 0L, "00");
    ("twenty-three", Encoding.integer 23L, "17");
    ("twenty-four", Encoding.integer 24L, "1818");
    ("two-hundred-fifty-five", Encoding.integer 255L, "18ff");
    ("two-hundred-fifty-six", Encoding.integer 256L, "190100");
    ( "sixty-five-thousand-five-hundred-thirty-five",
      Encoding.integer 65_535L,
      "19ffff" );
    ( "sixty-five-thousand-five-hundred-thirty-six",
      Encoding.integer 65_536L,
      "1a00010000" );
    ("uint32 maximum", Encoding.integer 4_294_967_295L, "1affffffff");
    ("uint32 plus one", Encoding.integer 4_294_967_296L, "1b0000000100000000");
    ("int64 maximum", Encoding.integer Int64.max_int, "1b7fffffffffffffff");
    ("negative one", Encoding.integer (-1L), "20");
    ("negative twenty-four", Encoding.integer (-24L), "37");
    ("negative twenty-five", Encoding.integer (-25L), "3818");
    ("negative two-hundred-fifty-six", Encoding.integer (-256L), "38ff");
    ("negative two-hundred-fifty-seven", Encoding.integer (-257L), "390100");
    ("negative uint32", Encoding.integer (-4_294_967_296L), "3affffffff");
    ( "negative uint32 minus one",
      Encoding.integer (-4_294_967_297L),
      "3b0000000100000000" );
    ("int64 minimum", Encoding.integer Int64.min_int, "3b7fffffffffffffff");
    ("empty bytes", Encoding.bytes "", "40");
    ("bytes", Encoding.bytes (raw_of_hex "010203ff"), "44010203ff");
    ("empty text", text "", "60");
    ("UTF-8 text", text (raw_of_hex "c3bc"), "62c3bc");
    ("empty array", array [], "80");
    ( "array",
      array [ Encoding.integer 1L; Encoding.integer 2L; Encoding.integer 3L ],
      "83010203" );
    ( "map",
      map [ (1L, Encoding.integer 2L); (3L, Encoding.integer 4L) ],
      "a201020304" );
    ("false", Encoding.bool false, "f4");
    ("true", Encoding.bool true, "f5");
    ("null", Encoding.null, "f6");
  ]

let published_vectors () =
  List.iter
    (fun (name, value, expected) ->
      let expected = raw_of_hex expected in
      Alcotest.(check string)
        (name ^ " encode") expected (Encoding.encode value);
      let decoded = require_decode expected in
      Alcotest.(check bool)
        (name ^ " decode") true
        (Encoding.equal value decoded))
    rfc_vectors

let constructor_invariants () =
  Alcotest.(check (result unit string))
    "invalid text rejected" (Error "invalid UTF-8 at byte 0")
    (construction_result (Encoding.text "\255"));
  Alcotest.(check (result unit string))
    "negative map key rejected" (Error "map key is negative: -1")
    (construction_result (Encoding.map [ (-1L, Encoding.null) ]));
  Alcotest.(check (result unit string))
    "duplicate map key rejected" (Error "duplicate map key: 1")
    (construction_result
       (Encoding.map [ (1L, Encoding.null); (1L, Encoding.bool true) ]));
  let first =
    map
      [
        (256L, Encoding.integer 3L);
        (1L, Encoding.integer 1L);
        (24L, Encoding.integer 2L);
      ]
  in
  let second =
    map
      [
        (24L, Encoding.integer 2L);
        (256L, Encoding.integer 3L);
        (1L, Encoding.integer 1L);
      ]
  in
  Alcotest.(check bool)
    "map input order is irrelevant" true
    (Encoding.equal first second);
  Alcotest.(check string)
    "map byte order is deterministic"
    (raw_of_hex "a3010118180219010003")
    (Encoding.encode first)

let utf8_boundaries () =
  let cases =
    [
      "\x7f";
      "\xc2\x80";
      "\xdf\xbf";
      "\xe0\xa0\x80";
      "\xed\x9f\xbf";
      "\xee\x80\x80";
      "\xef\xbf\xbf";
      "\xf0\x90\x80\x80";
      "\xf4\x8f\xbf\xbf";
    ]
  in
  List.iter
    (fun input ->
      let value = text input in
      Alcotest.(check bool)
        "UTF-8 boundary round trip" true
        (match Encoding.decode (Encoding.encode value) with
        | Ok decoded -> Encoding.equal value decoded
        | Error _ -> false))
    cases

let limit_invariants () =
  let invalid_depth =
    Encoding.make_limits ~max_depth:(Encoding.max_nesting + 1) ()
    |> Result.map (fun _ -> false)
  in
  Alcotest.(check bool)
    "depth limit cannot exceed profile" true
    (invalid_depth = Error (Encoding.Invalid_max_depth 65));
  let invalid_items =
    Encoding.make_limits ~max_items:(-1) () |> Result.map (fun _ -> false)
  in
  Alcotest.(check bool)
    "negative item limit rejected" true
    (invalid_items = Error (Encoding.Invalid_max_items (-1)))

let nesting_invariants () =
  let rec nest count value =
    if count = 0 then value else nest (count - 1) (array [ value ])
  in
  let accepted = nest Encoding.max_nesting Encoding.null in
  Alcotest.(check bool)
    "maximum nesting encodes" true
    (match Encoding.decode (Encoding.encode accepted) with
    | Ok decoded -> Encoding.equal accepted decoded
    | Error _ -> false);
  let rejected = Encoding.array [ accepted ] in
  Alcotest.(check (result unit string))
    "nesting above profile limit rejected" (Error "nesting limit exceeded: 65")
    (construction_result rejected)

let expect_kind name expected input =
  let actual = (require_error input).Encoding.kind in
  Alcotest.(check bool) name true (actual = expected)

let rejection_cases () =
  expect_kind "empty" Encoding.Empty_input "";
  List.iter
    (fun encoded ->
      expect_kind ("non-minimal " ^ encoded) (Encoding.Non_minimal_argument 0L)
        (raw_of_hex encoded))
    [ "1800"; "5800"; "9800"; "b800" ];
  List.iter
    (fun encoded ->
      expect_kind ("indefinite " ^ encoded) Encoding.Indefinite_length
        (raw_of_hex encoded))
    [ "5f"; "7f"; "9f"; "bf" ];
  expect_kind "tag" (Encoding.Unsupported_major_type 6) (raw_of_hex "c0");
  expect_kind "undefined" (Encoding.Unsupported_simple_value 23)
    (raw_of_hex "f7");
  expect_kind "float" (Encoding.Unsupported_simple_value 25)
    (raw_of_hex "f90000");
  expect_kind "reserved additional information"
    (Encoding.Reserved_additional_information 28) (raw_of_hex "1c");
  List.iter
    (fun encoded ->
      expect_kind
        ("invalid UTF-8 " ^ encoded)
        Encoding.Invalid_utf8_text (raw_of_hex encoded))
    [ "61ff"; "62c0af"; "63eda080"; "64f4908080" ];
  expect_kind "duplicate map key" (Encoding.Duplicate_decoded_map_key 1L)
    (raw_of_hex "a201000100");
  expect_kind "unordered map key"
    (Encoding.Non_increasing_map_key { previous = 2L; current = 1L })
    (raw_of_hex "a202000100");
  expect_kind "negative map key" (Encoding.Negative_decoded_map_key (-1L))
    (raw_of_hex "a12000");
  expect_kind "text map key" Encoding.Non_integer_map_key
    (raw_of_hex "a1616100");
  expect_kind "trailing byte" (Encoding.Trailing_bytes 1) (raw_of_hex "00ff");
  expect_kind "unsigned integer outside profile" Encoding.Argument_out_of_range
    (raw_of_hex "1b8000000000000000");
  expect_kind "negative integer outside profile" Encoding.Argument_out_of_range
    (raw_of_hex "3b8000000000000000");
  expect_kind "impossible byte string length"
    (Encoding.Declared_length_exceeds_input 65_536L) (raw_of_hex "5a00010000");
  expect_kind "impossible array count" (Encoding.Declared_items_exceed_input 1L)
    (raw_of_hex "81");
  expect_kind "impossible map count" (Encoding.Declared_items_exceed_input 1L)
    (raw_of_hex "a1");
  let over_depth = String.make 65 (Char.chr 0x81) ^ "\xf6" in
  expect_kind "depth 65" (Encoding.Depth_limit_exceeded 65) over_depth;
  let limits = require_limits (Encoding.make_limits ~max_items:1 ()) in
  let actual =
    match Encoding.decode ~limits (raw_of_hex "820001") with
    | Error error -> error.Encoding.kind
    | Ok _ -> Alcotest.fail "work-limited decoder unexpectedly succeeded"
  in
  Alcotest.(check bool)
    "explicit work limit" true
    (actual = Encoding.Work_limit_exceeded)

let truncation_cases () =
  let input = raw_of_hex "a201826161011818f5" in
  for length = 0 to String.length input - 1 do
    let prefix = String.sub input 0 length in
    match Encoding.decode prefix with
    | Error _ -> ()
    | Ok _ -> Alcotest.failf "truncated prefix accepted at length %d" length
  done

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
        QCheck2.Gen.map (fun value -> text value) ascii_generator;
        QCheck2.Gen.map Encoding.bool QCheck2.Gen.bool;
        QCheck2.Gen.return Encoding.null;
      ]
  in
  if depth = 0 then scalar
  else
    let child = value_generator (depth - 1) in
    let arrays =
      QCheck2.Gen.map
        (fun values -> array values)
        (QCheck2.Gen.list_size (QCheck2.Gen.int_range 0 4) child)
    in
    let maps =
      QCheck2.Gen.map
        (fun values ->
          let keys = [ 0L; 24L; 256L; 65_536L ] in
          let entries =
            List.mapi (fun index value -> (List.nth keys index, value)) values
          in
          map entries)
        (QCheck2.Gen.list_size (QCheck2.Gen.int_range 0 4) child)
    in
    QCheck2.Gen.oneof_weighted [ (6, scalar); (2, arrays); (2, maps) ]

let round_trip_property =
  QCheck2.Test.make ~count:500 ~name:"Profile 1 values round-trip and re-encode"
    (value_generator 4) (fun value ->
      let encoded = Encoding.encode value in
      match Encoding.decode encoded with
      | Error _ -> false
      | Ok decoded ->
          Encoding.equal value decoded
          && String.equal encoded (Encoding.encode decoded))

let map_permutation_property =
  QCheck2.Test.make ~count:300 ~name:"map permutations encode identically"
    (QCheck2.Gen.list_size (QCheck2.Gen.int_range 0 4) (value_generator 3))
    (fun values ->
      let keys = [ 0L; 24L; 256L; 65_536L ] in
      let entries =
        List.mapi (fun index value -> (List.nth keys index, value)) values
      in
      let forward = map entries in
      let reverse = map (List.rev entries) in
      String.equal (Encoding.encode forward) (Encoding.encode reverse))

let random_bytes_property =
  QCheck2.Test.make ~count:2_000
    ~name:"arbitrary bytes either reject or are already canonical" raw_generator
    (fun input ->
      match Encoding.decode input with
      | Error _ -> true
      | Ok value -> String.equal input (Encoding.encode value))

let () =
  Alcotest.run "deterministic CBOR"
    [
      ( "vectors",
        [
          Alcotest.test_case "RFC 8949 supported values" `Quick
            published_vectors;
        ] );
      ( "constructors",
        [
          Alcotest.test_case "enforce profile invariants" `Quick
            constructor_invariants;
          Alcotest.test_case "accept UTF-8 boundaries" `Quick utf8_boundaries;
          Alcotest.test_case "validate decoder limits" `Quick limit_invariants;
          Alcotest.test_case "enforce nesting bound" `Quick nesting_invariants;
        ] );
      ( "decoder rejections",
        [
          Alcotest.test_case "reject malformed and unsupported input" `Quick
            rejection_cases;
          Alcotest.test_case "reject every truncated prefix" `Quick
            truncation_cases;
        ] );
      ( "properties",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick round_trip_property;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            map_permutation_property;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick random_bytes_property;
        ] );
    ]
