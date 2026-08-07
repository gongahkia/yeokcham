module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_v2_envelope
module Golden = Yeokcham_testkit.Golden_fixture

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
let () = Printf.printf "v2 envelope property base seed: %d\n%!" base_seed

let require_ok error_to_string = function
  | Ok value -> value
  | Error error -> Alcotest.fail (error_to_string error)

let key =
  Envelope.key_of_bytes (String.init 32 (fun index -> Char.chr index))
  |> require_ok Envelope.error_to_string

let nonce =
  Envelope.nonce_of_bytes (String.init 12 (fun index -> Char.chr (index + 64)))
  |> require_ok Envelope.error_to_string

let plaintext = "v2\000canonical\255envelope"

let seal () =
  Envelope.seal ~key ~nonce ~mandatory_features:0L plaintext
  |> require_ok Envelope.error_to_string

let read_golden name =
  Golden.read_lower_hex_file (Filename.concat "golden" name)
  |> require_ok Fun.id

let exact_golden_round_trip () =
  let envelope = seal () in
  let encoded = Envelope.encode envelope in
  Alcotest.(check string)
    "canonical ciphertext envelope"
    (read_golden "v2-ciphertext-envelope-v1.cbor.hex")
    encoded;
  let decoded =
    Envelope.decode encoded |> require_ok Envelope.error_to_string
  in
  Alcotest.(check string)
    "decode preserves canonical bytes" encoded (Envelope.encode decoded);
  Alcotest.(check string)
    "authenticated open preserves plaintext" plaintext
    (Envelope.open_envelope ~key decoded |> require_ok Envelope.error_to_string)

let alter_last_byte bytes =
  let altered = Bytes.of_string bytes in
  let index = Bytes.length altered - 1 in
  Bytes.set altered index
    (Char.chr (Char.code (Bytes.get altered index) lxor 1));
  Bytes.unsafe_to_string altered

let replace_field encoded index replacement =
  (match Encoding.decode encoded with
  | Ok (Encoding.Array values) ->
      let rec replace offset = function
        | [] -> Alcotest.fail "v2 envelope field is absent"
        | _ :: rest when offset = index -> replacement :: rest
        | value :: rest -> value :: replace (offset + 1) rest
      in
      Encoding.array (replace 0 values)
      |> require_ok Encoding.construction_error_to_string
      |> Encoding.encode
  | Ok _ -> Alcotest.fail "v2 envelope is not an array"
  | Error error -> Alcotest.fail (Encoding.decode_error_to_string error))
  [@warning "-4"]

let failures_are_typed_and_prepublication_safe () =
  let envelope = seal () in
  let encoded = Envelope.encode envelope in
  Alcotest.(check bool)
    "truncated input rejects" true
    (Result.is_error
       (Envelope.decode (String.sub encoded 0 (String.length encoded - 1))));
  Alcotest.(check bool)
    "trailing noncanonical input rejects" true
    (Result.is_error (Envelope.decode (encoded ^ "\000")));
  let unsupported_feature = replace_field encoded 4 (Encoding.integer 1L) in
  Alcotest.(check bool)
    "unsupported mandatory feature rejects" true
    (Result.is_error (Envelope.decode unsupported_feature));
  let tampered_ciphertext =
    (match Encoding.decode encoded with
    | Ok (Encoding.Array [ _; _; _; Encoding.Bytes ciphertext; _ ]) ->
        replace_field encoded 3 (Encoding.bytes (alter_last_byte ciphertext))
    | Ok _ -> Alcotest.fail "v2 envelope ciphertext is absent"
    | Error error -> Alcotest.fail (Encoding.decode_error_to_string error))
    [@warning "-4"]
  in
  let tampered =
    Envelope.decode tampered_ciphertext |> require_ok Envelope.error_to_string
  in
  Alcotest.(check bool)
    "authentication failure rejects" true
    (Result.is_error (Envelope.open_envelope ~key tampered));
  let tampered_header =
    replace_field encoded 2
      (Encoding.bytes (alter_last_byte (Envelope.nonce_to_bytes nonce)))
    |> Envelope.decode
    |> require_ok Envelope.error_to_string
  in
  Alcotest.(check bool)
    "authenticated nonce tampering rejects" true
    (Result.is_error (Envelope.open_envelope ~key tampered_header));
  Alcotest.(check bool)
    "wrong key rejects" true
    (Result.is_error
       (Envelope.open_envelope
          ~key:
            (Envelope.key_of_bytes (String.make 32 'k')
            |> require_ok Envelope.error_to_string)
          envelope))

let arbitrary_plaintext = QCheck2.Gen.(string_size (0 -- 4096))

let envelope_round_trip_property =
  QCheck2.Test.make ~count:150
    ~name:"v2 ciphertext envelope round-trips arbitrary bounded plaintext"
    arbitrary_plaintext (fun plaintext ->
      match Envelope.seal ~key ~nonce ~mandatory_features:0L plaintext with
      | Error _ -> false
      | Ok envelope -> (
          match Envelope.decode (Envelope.encode envelope) with
          | Error _ -> false
          | Ok decoded -> (
              match Envelope.open_envelope ~key decoded with
              | Error _ -> false
              | Ok actual -> String.equal plaintext actual)))

let truncation_property =
  QCheck2.Test.make ~count:100
    ~name:"every proper truncation of a v2 ciphertext envelope rejects"
    (QCheck2.Gen.int_range 0 (String.length (Envelope.encode (seal ())) - 1))
    (fun length ->
      let encoded = Envelope.encode (seal ()) in
      Result.is_error (Envelope.decode (String.sub encoded 0 length)))

let () =
  Alcotest.run "v2 canonical ciphertext envelope"
    [
      ( "unit",
        [
          Alcotest.test_case "canonical golden round trip" `Quick
            exact_golden_round_trip;
          Alcotest.test_case "failures are typed and safe" `Quick
            failures_are_typed_and_prepublication_safe;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "round-trip") envelope_round_trip_property;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "truncation") truncation_property;
        ] );
    ]
