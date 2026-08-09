module Encoding = Yeokcham_encoding
module Ledger = Yeokcham_v2_ledger
module Model = Yeokcham_v2_model

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
let () = Printf.printf "v2 ledger property base seed: %d\n%!" base_seed

type signer = {
  private_key : Mirage_crypto_ec.Ed25519.priv;
  public_key : string;
  key_id : Ledger.Signer_key_id.t;
}

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let raw_of_hex encoded =
  let nibble = function
    | '0' .. '9' as character -> Char.code character - Char.code '0'
    | 'a' .. 'f' as character -> Char.code character - Char.code 'a' + 10
    | character -> Alcotest.failf "invalid hex character %C" character
  in
  if String.length encoded mod 2 <> 0 then Alcotest.fail "odd hexadecimal input";
  Bytes.init
    (String.length encoded / 2)
    (fun index ->
      Char.chr
        ((nibble encoded.[index * 2] lsl 4) lor nibble encoded.[(index * 2) + 1]))
  |> Bytes.unsafe_to_string

let signer seed =
  let private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets
      (String.init 32 (fun index -> Char.chr ((seed + index) land 255)))
    |> require_ok (fun error ->
        Format.asprintf "%a" Mirage_crypto_ec.pp_error error)
  in
  let public_key =
    Mirage_crypto_ec.Ed25519.pub_of_priv private_key
    |> Mirage_crypto_ec.Ed25519.pub_to_octets
  in
  let key_id =
    Ledger.signer_key_id_of_public_key public_key
    |> require_ok Ledger.error_to_string
  in
  { private_key; public_key; key_id }

let signer_a = signer 1
let signer_b = signer 33

let repository =
  Model.Repository_id.of_bytes (String.make 32 'r')
  |> require_ok Model.identity_error_to_string

let other_repository =
  Model.Repository_id.of_bytes (String.make 32 's')
  |> require_ok Model.identity_error_to_string

let ref_name = Ledger.Ref_name.of_string "main" |> require_ok Fun.id
let other_ref_name = Ledger.Ref_name.of_string "other" |> require_ok Fun.id

let target character =
  Model.Opaque_object_ref.of_bytes (String.make 32 character)
  |> require_ok Model.identity_error_to_string
  |> Ledger.Ref_target.of_opaque_object_ref

let registry signers =
  signers
  |> List.map (fun signer -> (signer.key_id, signer.public_key))
  |> List.sort (fun (left, _) (right, _) ->
      Ledger.Signer_key_id.compare left right)
  |> Ledger.make_public_key_registry
  |> require_ok Ledger.error_to_string

let signed_event ?predecessor ?(repository_id = repository)
    ?(ref_name = ref_name) ?target_value signer =
  let unsigned =
    Ledger.make_unsigned ~repository_id ~ref_name ~signer_key_id:signer.key_id
      ~predecessor ~target:target_value ~mandatory_features:0L
    |> require_ok Ledger.error_to_string
  in
  let signature =
    Ledger.signing_bytes unsigned
    |> Mirage_crypto_ec.Ed25519.sign ~key:signer.private_key
  in
  Ledger.make ~unsigned ~algorithm:Ledger.algorithm ~signature
  |> require_ok Ledger.error_to_string

let verified registry event =
  match
    Ledger.verify ~public_keys:registry event
    |> require_ok Ledger.error_to_string
  with
  | Ledger.Cryptographically_valid event -> event
  | Ledger.Unknown_signer _ ->
      Alcotest.fail "test signer is absent from registry"

let replace_field encoded index replacement =
  match Encoding.decode encoded with
  | Ok (Encoding.Array values) ->
      let rec replace offset = function
        | [] -> Alcotest.fail "ledger field is absent"
        | _ :: rest when offset = index -> replacement :: rest
        | value :: rest -> value :: replace (offset + 1) rest
      in
      Encoding.array (replace 0 values)
      |> require_ok Encoding.construction_error_to_string
      |> Encoding.encode
  | Ok
      ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
      | Encoding.Bool _ | Encoding.Null ) ->
      Alcotest.fail "ledger record is not an array"
  | Error error -> Alcotest.fail (Encoding.decode_error_to_string error)

let rfc8032_test_vector_verifies () =
  let private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets
      (raw_of_hex
         "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
    |> require_ok (fun error ->
        Format.asprintf "%a" Mirage_crypto_ec.pp_error error)
  in
  let public_key =
    raw_of_hex
      "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
  in
  let expected_signature =
    raw_of_hex
      "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
  in
  let actual = Mirage_crypto_ec.Ed25519.sign ~key:private_key "" in
  Alcotest.(check string) "RFC 8032 test 1 signature" expected_signature actual;
  let public_key =
    Mirage_crypto_ec.Ed25519.pub_of_octets public_key
    |> require_ok (fun error ->
        Format.asprintf "%a" Mirage_crypto_ec.pp_error error)
  in
  Alcotest.(check bool)
    "RFC 8032 test 1 verifies" true
    (Mirage_crypto_ec.Ed25519.verify ~key:public_key expected_signature ~msg:"")

let canonical_records_and_explicit_verification () =
  let key_registry = registry [ signer_a ] in
  let event = signed_event ~target_value:(target 't') signer_a in
  let encoded = Ledger.encode event in
  let decoded = Ledger.decode encoded |> require_ok Ledger.error_to_string in
  Alcotest.(check string)
    "canonical decode re-encodes exactly" encoded (Ledger.encode decoded);
  Alcotest.(check bool)
    "event ID is stable" true
    (Ledger.Event_id.equal (Ledger.event_id event) (Ledger.event_id decoded));
  (match
     Ledger.verify ~public_keys:key_registry decoded
     |> require_ok Ledger.error_to_string
   with
  | Ledger.Cryptographically_valid _ -> ()
  | Ledger.Unknown_signer _ -> Alcotest.fail "known signer became unknown");
  match
    Ledger.verify ~public_keys:(registry []) decoded
    |> require_ok Ledger.error_to_string
  with
  | Ledger.Unknown_signer key ->
      Alcotest.(check bool)
        "missing key is explicit, not authority" true
        (Ledger.Signer_key_id.equal key signer_a.key_id)
  | Ledger.Cryptographically_valid _ -> Alcotest.fail "absent signer verified"

let malformed_features_and_signatures_reject () =
  let event = signed_event signer_a in
  Alcotest.(check bool)
    "trailing bytes reject" true
    (Result.is_error (Ledger.decode (Ledger.encode event ^ "\000")));
  Alcotest.(check bool)
    "unsupported mandatory feature rejects" true
    (Result.is_error
       (Ledger.make_unsigned ~repository_id:repository ~ref_name
          ~signer_key_id:signer_a.key_id ~predecessor:None ~target:None
          ~mandatory_features:1L));
  Alcotest.(check bool)
    "encoded unsupported mandatory feature rejects" true
    (Result.is_error
       (Ledger.decode
          (replace_field (Ledger.encode event) 6 (Encoding.integer 1L))));
  Alcotest.(check bool)
    "unsafe ref name rejects" true
    (Result.is_error (Ledger.Ref_name.of_string "refs/main"));
  let signature = Bytes.of_string (Ledger.event_signature event) in
  Bytes.set signature 0 (Char.chr (Char.code (Bytes.get signature 0) lxor 1));
  let tampered =
    Ledger.make
      ~unsigned:(Ledger.event_unsigned event)
      ~algorithm:Ledger.algorithm
      ~signature:(Bytes.unsafe_to_string signature)
    |> require_ok Ledger.error_to_string
  in
  Alcotest.(check bool)
    "tampered signature rejects" true
    (Result.is_error
       (Ledger.verify ~public_keys:(registry [ signer_a ]) tampered));
  let unsorted =
    [
      (signer_b.key_id, signer_b.public_key);
      (signer_a.key_id, signer_a.public_key);
    ]
    |> List.sort (fun (left, _) (right, _) ->
        Ledger.Signer_key_id.compare right left)
  in
  Alcotest.(check bool)
    "noncanonical key registry rejects" true
    (Result.is_error (Ledger.make_public_key_registry unsorted))

let causal_heads_and_divergence_are_explicit () =
  let registry = registry [ signer_a; signer_b ] in
  let root = signed_event ~target_value:(target '0') signer_a in
  let root_id = Ledger.event_id root in
  let left =
    signed_event ~predecessor:root_id ~target_value:(target '1') signer_a
  in
  let right =
    signed_event ~predecessor:root_id ~target_value:(target '2') signer_b
  in
  let result =
    Ledger.evaluate ~repository_id:repository ~ref_name
      [
        verified registry right; verified registry root; verified registry left;
      ]
    |> require_ok Ledger.error_to_string
  in
  Alcotest.(check int)
    "two concurrent heads" 2
    (List.length (Ledger.heads result));
  Alcotest.(check int)
    "one explicit divergence" 1
    (List.length (Ledger.divergences result));
  let divergence = List.hd (Ledger.divergences result) in
  Alcotest.(check bool)
    "divergence retains its predecessor" true
    (Option.exists
       (Ledger.Event_id.equal root_id)
       (Ledger.divergence_predecessor divergence));
  Alcotest.(check int)
    "divergence is ordered by two child IDs" 2
    (List.length (Ledger.divergence_children divergence));
  let missing =
    signed_event
      ~predecessor:
        (Model.Ref_event_id.of_bytes (String.make 32 'm')
        |> require_ok Model.identity_error_to_string)
      signer_a
  in
  Alcotest.(check bool)
    "missing predecessor rejects" true
    (Result.is_error
       (Ledger.evaluate ~repository_id:repository ~ref_name
          [ verified registry missing ]));
  let other = signed_event ~ref_name:other_ref_name signer_a in
  let cross = signed_event ~predecessor:(Ledger.event_id other) signer_a in
  Alcotest.(check bool)
    "cross-ref predecessor rejects" true
    (Result.is_error
       (Ledger.evaluate ~repository_id:repository ~ref_name
          [ verified registry cross; verified registry other ]));
  let other_repository_event =
    signed_event ~repository_id:other_repository signer_b
  in
  let cross_repository =
    signed_event ~predecessor:(Ledger.event_id other_repository_event) signer_a
  in
  Alcotest.(check bool)
    "cross-repository predecessor rejects" true
    (Result.is_error
       (Ledger.evaluate ~repository_id:repository ~ref_name
          [
            verified registry cross_repository;
            verified registry other_repository_event;
          ]));
  Alcotest.(check bool)
    "duplicate event rejects" true
    (Result.is_error
       (Ledger.evaluate ~repository_id:repository ~ref_name
          [ verified registry root; verified registry root ]))

let chain_lengths = QCheck2.Gen.(1 -- 32)

let generated_chains_have_one_deterministic_head =
  QCheck2.Test.make ~count:100
    ~name:"generated signed V2 ledger chains have one deterministic head"
    chain_lengths (fun length ->
      let registry = registry [ signer_a ] in
      let rec make previous index result =
        if index = length then List.rev result
        else
          let event =
            signed_event ?predecessor:previous
              ~target_value:(target (Char.chr (index + 1)))
              signer_a
          in
          make (Some (Ledger.event_id event)) (index + 1) (event :: result)
      in
      let events = make None 0 [] in
      match
        Ledger.evaluate ~repository_id:repository ~ref_name
          (List.rev_map (verified registry) events)
      with
      | Error _ -> false
      | Ok result ->
          List.length (Ledger.heads result) = 1
          && List.length (Ledger.divergences result) = 0)

let () =
  Alcotest.run "V2 encrypted causal ref ledger"
    [
      ( "unit",
        [
          Alcotest.test_case "RFC 8032 Ed25519 vector" `Quick
            rfc8032_test_vector_verifies;
          Alcotest.test_case "canonical records and explicit verification"
            `Quick canonical_records_and_explicit_verification;
          Alcotest.test_case "malformed features and signatures reject" `Quick
            malformed_features_and_signatures_reject;
          Alcotest.test_case "causal heads and divergence are explicit" `Quick
            causal_heads_and_divergence_are_explicit;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "generated-chains")
            generated_chains_have_one_deterministic_head;
        ] );
    ]
