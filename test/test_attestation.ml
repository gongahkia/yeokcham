module Encoding = Paengi_encoding
module Envelope = Paengi_envelope
module Golden = Paengi_testkit.Golden_fixture
module Id = Paengi_id
module Release = Paengi_release
module Store = Paengi_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let release_id seed = Id.Release_id.of_bytes (raw_id seed) |> Result.get_ok

let with_root run =
  let root = Filename.temp_file "paengi-attestation-test-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> Unix.rmdir root) (fun () -> run root)

let golden name =
  let paths = [ Filename.concat "golden" name; Filename.concat "test/golden" name ] in
  match List.find_opt Sys.file_exists paths with
  | Some path -> Golden.read_lower_hex_file path |> require_ok Fun.id
  | None -> Alcotest.fail ("missing golden fixture: " ^ name)

let hex bytes =
  let alphabet = "0123456789abcdef" in
  let output = Bytes.create (String.length bytes * 2) in
  String.iteri
    (fun index character ->
      let value = Char.code character in
      Bytes.set output (index * 2) alphabet.[value lsr 4];
      Bytes.set output ((index * 2) + 1) alphabet.[value land 0x0f])
    bytes;
  Bytes.unsafe_to_string output

let fixture () =
  Release.create_attestation ~release:(release_id 1) ~signer_identity:"example-key"
    ~algorithm:"example-signature-v1" ~signature:"signature bytes" ~signed_at:9L
  |> require_ok Release.error_to_string

let canonical_golden_and_inverse_decoder () =
  let attestation = fixture () in
  let payload =
    Release.attestation_payload attestation |> require_ok Release.error_to_string
  in
  let bytes =
    Envelope.create ~object_type:Envelope.Release_attestation
      ~object_format_version:1 ~mandatory_features:0L ~payload ()
    |> require_ok Envelope.creation_error_to_string
    |> Envelope.encode
  in
  Alcotest.(check string)
    "attestation golden"
    (golden "release-attestation-v1.peng.hex") bytes;
  let envelope = Envelope.decode bytes |> require_ok Envelope.decode_error_to_string in
  let decoded =
    Release.decode_attestation_payload (Envelope.payload envelope)
    |> require_ok Release.error_to_string
  in
  let recoded =
    Release.attestation_payload decoded |> require_ok Release.error_to_string
  in
  Alcotest.(check bool)
    "attestation inverse decoder" true
    (Encoding.equal payload recoded)

let storage_reopen_and_test_signer () =
  with_root (fun root ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let release = release_id 10 in
      let attestation =
        Release.attest ~signer:(module Release.Deterministic_test_signer)
          ~release ~signed_at:12L
        |> require_ok Release.error_to_string
      in
      let object_id =
        Release.store_attestation store attestation |> require_ok Release.error_to_string
      in
      let reopened = Store.open_repository ~root |> require_ok Store.error_to_string in
      let loaded =
        Release.load_attestation reopened object_id |> require_ok Release.error_to_string
      in
      Alcotest.(check bool)
        "attestation does not change release identity" true
        (Id.Release_id.equal release (Release.attestation_release loaded));
      Alcotest.(check string)
        "test signer is explicitly non-cryptographic"
        "paengi-test-only-not-cryptographic-v1"
        (Release.attestation_algorithm loaded))

let () =
  match Sys.getenv_opt "PAENGI_PRINT_ATTESTATION_GOLDEN" with
  | Some "1" ->
      let payload =
        Release.attestation_payload (fixture ()) |> require_ok Release.error_to_string
      in
      Envelope.create ~object_type:Envelope.Release_attestation
        ~object_format_version:1 ~mandatory_features:0L ~payload ()
      |> require_ok Envelope.creation_error_to_string
      |> Envelope.encode |> hex |> print_endline
  | None | Some _ ->
      Alcotest.run "paengi_attestation"
        [
          ( "attestation",
            [
              Alcotest.test_case "canonical golden and inverse decoder" `Quick
                canonical_golden_and_inverse_decoder;
              Alcotest.test_case "storage reopen and test signer" `Quick
                storage_reopen_and_test_signer;
            ] );
        ]
