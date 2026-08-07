module Address = Yeokcham_v2_address
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_v2_model
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
let () = Printf.printf "v2 address property base seed: %d\n%!" base_seed

let require_ok error_to_string = function
  | Ok value -> value
  | Error error -> Alcotest.fail (error_to_string error)

let repository character =
  Model.Repository_id.of_bytes (String.make 32 character)
  |> require_ok Model.identity_error_to_string

let address_key character =
  Address.key_of_bytes (String.make 32 character)
  |> require_ok Address.error_to_string

let encryption_key =
  Envelope.key_of_bytes (String.init 32 (fun index -> Char.chr index))
  |> require_ok Envelope.error_to_string

let nonce =
  Envelope.nonce_of_bytes (String.init 12 (fun index -> Char.chr (index + 64)))
  |> require_ok Envelope.error_to_string

let envelope plaintext =
  Envelope.seal ~key:encryption_key ~nonce ~mandatory_features:0L plaintext
  |> require_ok Envelope.error_to_string

let read_golden name =
  Golden.read_lower_hex_file (Filename.concat "golden" name)
  |> require_ok Fun.id

let deterministic_golden_and_repository_isolation () =
  let object_envelope = envelope "same plaintext" in
  let first =
    Address.derive ~repository_id:(repository 'r') ~key:(address_key 'a')
      ~envelope:object_envelope
  in
  let second =
    Address.derive ~repository_id:(repository 'r') ~key:(address_key 'a')
      ~envelope:object_envelope
  in
  Alcotest.(check string)
    "canonical address fixture"
    (read_golden "v2-opaque-object-address-v1.hex")
    (Model.Opaque_object_ref.to_bytes first);
  Alcotest.(check bool)
    "derivation is deterministic" true
    (Model.Opaque_object_ref.equal first second);
  let different_key =
    Address.derive ~repository_id:(repository 'r') ~key:(address_key 'b')
      ~envelope:object_envelope
  in
  let different_repository =
    Address.derive ~repository_id:(repository 's') ~key:(address_key 'a')
      ~envelope:object_envelope
  in
  Alcotest.(check bool)
    "different repository key has distinct address" false
    (Model.Opaque_object_ref.equal first different_key);
  Alcotest.(check bool)
    "different repository identity has distinct address" false
    (Model.Opaque_object_ref.equal first different_repository)

let wrong_key_repository_and_replay_reject () =
  let object_envelope = envelope "same plaintext" in
  let address =
    Address.derive ~repository_id:(repository 'r') ~key:(address_key 'a')
      ~envelope:object_envelope
  in
  Alcotest.(check bool)
    "correct address verifies" true
    (Result.is_ok
       (Address.verify ~repository_id:(repository 'r') ~key:(address_key 'a')
          ~address ~envelope:object_envelope));
  Alcotest.(check bool)
    "wrong key rejects" true
    (Result.is_error
       (Address.verify ~repository_id:(repository 'r') ~key:(address_key 'b')
          ~address ~envelope:object_envelope));
  Alcotest.(check bool)
    "wrong repository rejects" true
    (Result.is_error
       (Address.verify ~repository_id:(repository 's') ~key:(address_key 'a')
          ~address ~envelope:object_envelope));
  let replayed_envelope = envelope "different plaintext" in
  Alcotest.(check bool)
    "replayed address rejects" true
    (Result.is_error
       (Address.verify ~repository_id:(repository 'r') ~key:(address_key 'a')
          ~address ~envelope:replayed_envelope))

let plaintext_generator = QCheck2.Gen.(string_size (0 -- 4096))

let deterministic_and_key_separated_property =
  QCheck2.Test.make ~count:150
    ~name:"opaque object addresses are deterministic and key-separated"
    plaintext_generator (fun plaintext ->
      let object_envelope = envelope plaintext in
      let first =
        Address.derive ~repository_id:(repository 'r') ~key:(address_key 'a')
          ~envelope:object_envelope
      in
      let second =
        Address.derive ~repository_id:(repository 'r') ~key:(address_key 'a')
          ~envelope:object_envelope
      in
      let distinct_key =
        Address.derive ~repository_id:(repository 'r') ~key:(address_key 'b')
          ~envelope:object_envelope
      in
      Model.Opaque_object_ref.equal first second
      && not (Model.Opaque_object_ref.equal first distinct_key))

let () =
  Alcotest.run "v2 client-side opaque object addressing"
    [
      ( "unit",
        [
          Alcotest.test_case "deterministic golden and repository isolation"
            `Quick deterministic_golden_and_repository_isolation;
          Alcotest.test_case "wrong key, repository, and replay reject" `Quick
            wrong_key_repository_and_replay_reject;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "deterministic-and-key-separated")
            deterministic_and_key_separated_property;
        ] );
    ]
