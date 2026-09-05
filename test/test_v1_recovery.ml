module Mnemonic = Yeokcham_v1_mnemonic
module Recovery = Yeokcham_v1_recovery
module Trust = Yeokcham_v1_trust
module Golden = Yeokcham_testkit.Golden_fixture

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let golden_path name =
  let local = Filename.concat "golden" name in
  if Sys.file_exists local then local else Filename.concat "test/golden" name

let read_golden name =
  Golden.read_lower_hex_file (golden_path name) |> require_ok Fun.id

let capability byte =
  String.make 32 byte |> Trust.signing_capability_of_private_key
  |> require_ok Trust.error_to_string

let device_from_capability capability =
  capability |> Trust.signing_public_key |> Trust.device_of_public_key
  |> require_ok Trust.error_to_string

let repository =
  Trust.Repository_id.of_string
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  |> Result.get_ok

let recovery_authority () =
  let root_capability = capability 'a' in
  let root_device = device_from_capability root_capability in
  let root_certificate =
    Trust.root_certificate ~repository ~device:root_device root_capability
    |> require_ok Trust.error_to_string
  in
  let membership =
    Trust.verify_membership ~repository [ root_certificate ]
    |> require_ok Trust.error_to_string
  in
  let recovery_capability = capability 'r' in
  let recovery_device = device_from_capability recovery_capability in
  let root_epoch =
    Trust.root_epoch ~membership
      ~root_certificate:(Trust.certificate_id root_certificate)
      ~recovery_device root_capability
    |> require_ok Trust.error_to_string
  in
  let authority =
    Trust.verify_authority ~membership [ root_epoch ]
    |> require_ok Trust.error_to_string
  in
  (root_certificate, recovery_capability, authority)

let bip39_vectors_are_canonical () =
  let twelve_entropy = String.make 16 '\000' in
  let twelve =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon \
     abandon abandon about"
  in
  Alcotest.(check string)
    "known 12-word BIP-39 vector" twelve
    (Mnemonic.encode twelve_entropy |> require_ok Mnemonic.error_to_string);
  Alcotest.(check string)
    "12-word phrase decodes exactly" twelve_entropy
    (Mnemonic.decode twelve |> require_ok Mnemonic.error_to_string);
  let twenty_four_entropy = String.make 32 '\000' in
  let twenty_four =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon \
     abandon abandon abandon abandon abandon abandon abandon abandon abandon \
     abandon abandon abandon abandon abandon art"
  in
  Alcotest.(check string)
    "known 24-word BIP-39 vector" twenty_four
    (Mnemonic.encode twenty_four_entropy |> require_ok Mnemonic.error_to_string);
  Alcotest.(check string)
    "24-word phrase decodes exactly" twenty_four_entropy
    (Mnemonic.decode twenty_four |> require_ok Mnemonic.error_to_string)

let encrypted_recovery_package_restores_only_with_the_mnemonic () =
  let root_certificate, recovery_capability, authority =
    recovery_authority ()
  in
  let phrase =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon \
     abandon abandon abandon abandon abandon abandon abandon abandon abandon \
     abandon abandon abandon abandon abandon art"
  in
  let secret =
    Recovery.secret_of_mnemonic phrase |> require_ok Recovery.error_to_string
  in
  let package =
    Recovery.make ~secret ~nonce:(String.make 12 '\000') ~authority
      ~recovery_capability
    |> require_ok Recovery.error_to_string
  in
  let encoded = Recovery.encode package in
  Alcotest.(check string)
    "recovery package retains its golden encoding"
    (Golden.refresh_lower_hex_file
       (golden_path "v1/recovery-package-v1.cbor.hex")
       encoded
    |> require_ok Fun.id)
    encoded;
  let decoded =
    Recovery.decode encoded |> require_ok Recovery.error_to_string
  in
  let recovered =
    Recovery.recover ~mnemonic:phrase ~package:decoded
    |> require_ok Recovery.error_to_string
  in
  Alcotest.(check (list string))
    "the complete authority closure is recovered"
    (Trust.authority_heads authority)
    (Trust.authority_heads (Recovery.recovered_authority recovered));
  Alcotest.(check bool)
    "recovered private capability matches the public authority" true
    (String.equal
       (Trust.signing_public_key (Recovery.recovered_capability recovered))
       (Trust.device_public_key (Recovery.recovery_device decoded)));
  Alcotest.(check int)
    "root verification phrase has twelve words" 12
    (List.length
       (String.split_on_char ' '
          (Recovery.verification_phrase root_certificate)));
  let wrong_phrase =
    Mnemonic.encode (String.make 32 '\001')
    |> require_ok Mnemonic.error_to_string
  in
  (match Recovery.recover ~mnemonic:wrong_phrase ~package:decoded with
  | Error error ->
      Alcotest.(check string)
        "another valid BIP-39 phrase cannot decrypt"
        "V1 recovery package cannot be decrypted"
        (Recovery.error_to_string error)
  | Ok _ -> Alcotest.fail "recovery accepted another valid BIP-39 phrase");
  let refreshed =
    Recovery.refresh ~secret ~authority ~recovery_capability
    |> require_ok Recovery.error_to_string
  in
  let refreshed_recovered =
    Recovery.recover ~mnemonic:phrase ~package:refreshed
    |> require_ok Recovery.error_to_string
  in
  Alcotest.(check (list string))
    "a refreshed copy preserves the complete authority closure"
    (Trust.authority_heads authority)
    (Trust.authority_heads (Recovery.recovered_authority refreshed_recovered))

let () =
  Alcotest.run "V1 recovery"
    [
      ( "recovery",
        [
          Alcotest.test_case "BIP-39 vectors are canonical" `Quick
            bip39_vectors_are_canonical;
          Alcotest.test_case "encrypted package restores only with mnemonic"
            `Quick encrypted_recovery_package_restores_only_with_the_mnemonic;
        ] );
    ]
