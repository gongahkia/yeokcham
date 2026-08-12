module Address = Yeokcham_v2_address
module Authority = Yeokcham_v2_authority
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_v2_model
module Recovery = Yeokcham_v2_recovery
module Recovery_store = Yeokcham_v2_recovery_store
module Store = Yeokcham_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let repository =
  Model.Repository_id.of_bytes (String.make 32 'r')
  |> require_ok Model.identity_error_to_string

let device =
  Model.Device_id.of_bytes (String.make 32 'd')
  |> require_ok Model.identity_error_to_string

let handle =
  Bootstrap.Key_handle.of_bytes (String.make 32 'h')
  |> require_ok Model.identity_error_to_string

let secret byte =
  Recovery.recovery_secret_of_bytes (String.make 32 byte)
  |> require_ok Recovery.error_to_string

let package_id =
  Model.Recovery_package_id.of_bytes (String.make 32 'p')
  |> require_ok Model.identity_error_to_string

let nonce =
  Envelope.nonce_of_bytes (String.make 12 'n')
  |> require_ok Envelope.error_to_string

let root =
  Authority.root_signing_capability_of_private_key (String.make 32 'r')
  |> require_ok Authority.error_to_string

let authority =
  Authority.make_repository_authority ~repository_id:repository ~root
    ~mandatory_features:0L
  |> require_ok Authority.error_to_string

let capability () =
  let encryption_key =
    Envelope.key_of_bytes (String.make 32 'e')
    |> require_ok Envelope.error_to_string
  in
  let address_key =
    Address.key_of_bytes (String.make 32 'a')
    |> require_ok Address.error_to_string
  in
  let signing_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets (String.make 32 's')
    |> require_ok (fun error ->
        Format.asprintf "%a" Mirage_crypto_ec.pp_error error)
  in
  Bootstrap.make_capability ~encryption_key ~address_key ~signing_key
  |> require_ok Bootstrap.error_to_string

let package () =
  Recovery.make ~secret:(secret 'k') ~package_id ~nonce ~authority ~root
    ~mandatory_features:0L
  |> require_ok Recovery.error_to_string

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

let with_root run =
  let root = Filename.temp_file "yeokcham-v2-recovery-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let local_bootstrap () =
  Bootstrap.make ~repository_id:repository ~device_id:device ~key_handle:handle
    ~capability:(capability ()) ~mandatory_features:0L
  |> require_ok Bootstrap.error_to_string

let read_golden name =
  Golden.read_lower_hex_file (Filename.concat "golden" name)
  |> require_ok Fun.id

let has_error expected = function
  | Ok _ -> false
  | Error error ->
      String.equal
        (Recovery.error_to_string expected)
        (Recovery.error_to_string error)

let contains ~needle haystack =
  let needle_length = String.length needle in
  let rec search offset =
    offset + needle_length <= String.length haystack
    &&
    if String.equal (String.sub haystack offset needle_length) needle then true
    else search (offset + 1)
  in
  search 0

let canonical_recovery_and_replacement_certificate () =
  let package = package () in
  let encoded = Recovery.encode package in
  Alcotest.(check string)
    "canonical encrypted recovery package vector"
    (read_golden "v2-recovery-package-v1.cbor.hex")
    encoded;
  Alcotest.(check bool)
    "package does not persist the recovery secret" false
    (contains ~needle:(String.make 32 'k') encoded);
  let decoded =
    Recovery.decode encoded |> require_ok Recovery.error_to_string
  in
  Alcotest.(check string)
    "canonical package re-encodes exactly" encoded (Recovery.encode decoded);
  let phrase = Recovery.verification_phrase (secret 'k') in
  let recovered =
    Recovery.recover ~secret:(secret 'k') ~verification_phrase:phrase
      ~package:decoded
    |> require_ok Recovery.error_to_string
  in
  let certificate =
    Recovery.make_replacement_device_certificate ~recovered ~device_id:device
      ~key_handle:handle ~capability:(capability ())
    |> require_ok Recovery.error_to_string
  in
  Alcotest.(check string)
    "replacement certificate binds new device"
    (Model.Device_id.to_bytes device)
    (Model.Device_id.to_bytes
       (Authority.device_certificate_device_id certificate))

let recovery_refuses_phrase_secret_and_ciphertext_failures () =
  let package = package () in
  Alcotest.(check bool)
    "wrong phrase refuses before decrypt" true
    (has_error Recovery.Verification_phrase_mismatch
       (Recovery.recover ~secret:(secret 'k')
          ~verification_phrase:"wrong-phrase" ~package));
  Alcotest.(check bool)
    "wrong secret with matching phrase fails authentication" true
    (Result.is_error
       (Recovery.recover ~secret:(secret 'x')
          ~verification_phrase:(Recovery.verification_phrase (secret 'x'))
          ~package));
  let bytes = Bytes.of_string (Recovery.encode package) in
  Bytes.set bytes
    (Bytes.length bytes - 2)
    (Char.chr (Char.code (Bytes.get bytes (Bytes.length bytes - 2)) lxor 1));
  Alcotest.(check bool)
    "tampered package refuses canonical decode" true
    (Result.is_error (Recovery.decode (Bytes.unsafe_to_string bytes)));
  Alcotest.(check bool)
    "loss is explicit when package is absent" true
    (Result.is_error (Recovery.recovery_secret_of_hex "lost"))

let recovery_rejects_feature_root_and_header_payload_mismatches () =
  Alcotest.(check bool)
    "unknown mandatory features reject" true
    (has_error (Recovery.Unsupported_mandatory_features 1L)
       (Recovery.make ~secret:(secret 'k') ~package_id ~nonce ~authority ~root
          ~mandatory_features:1L));
  let other_root =
    Authority.root_signing_capability_of_private_key (String.make 32 'x')
    |> require_ok Authority.error_to_string
  in
  Alcotest.(check bool)
    "authority and root mismatch rejects" true
    (has_error Recovery.Authority_root_mismatch
       (Recovery.make ~secret:(secret 'k') ~package_id ~nonce ~authority
          ~root:other_root ~mandatory_features:0L));
  let encoded = Bytes.of_string (Recovery.encode (package ())) in
  Bytes.set encoded 38 'x';
  let changed =
    Recovery.decode (Bytes.unsafe_to_string encoded)
    |> require_ok Recovery.error_to_string
  in
  Alcotest.(check bool)
    "encrypted payload cannot satisfy changed public header" true
    (has_error (Recovery.Package_binding_mismatch "repository ID")
       (Recovery.recover ~secret:(secret 'k')
          ~verification_phrase:(Recovery.verification_phrase (secret 'k'))
          ~package:changed))

let durable_package_is_create_only_and_staging_is_non_authoritative () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      Alcotest.(check bool)
        "missing recovery package is explicit" true
        (Result.is_error (Recovery_store.read_package ~root));
      let bootstrap = local_bootstrap () in
      ignore
        (Bootstrap_store.initialize ~root bootstrap
        |> require_ok Bootstrap_store.error_to_string);
      let value = package () in
      Alcotest.(check bool)
        "first durable package publication initializes" true
        (Recovery_store.initialize ~root value = Ok Recovery_store.Initialized);
      Alcotest.(check bool)
        "identical package retry is idempotent" true
        (Recovery_store.initialize ~root value
        = Ok Recovery_store.Already_initialized);
      let reopened =
        Recovery_store.read_package ~root
        |> require_ok Recovery_store.error_to_string
      in
      Alcotest.(check string)
        "durable bytes stay canonical" (Recovery.encode value)
        (Recovery.encode reopened);
      let directory = Filename.dirname (Recovery_store.recovery_path ~root) in
      let stale =
        Filename.concat directory
          (Printf.sprintf ".%s.recovery-42-0" Recovery_store.filename)
      in
      let descriptor =
        Unix.openfile stale [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      in
      Unix.close descriptor;
      Alcotest.(check bool)
        "stale staging is never recovered" true
        (Result.is_ok (Recovery_store.read_package ~root));
      let replacement =
        let replacement_root =
          Authority.root_signing_capability_of_private_key (String.make 32 'r')
          |> require_ok Authority.error_to_string
        in
        Recovery.make ~secret:(secret 'x') ~package_id ~nonce ~authority
          ~root:replacement_root ~mandatory_features:0L
        |> require_ok Recovery.error_to_string
      in
      Alcotest.(check bool)
        "different package cannot overwrite recovery copy" true
        (Result.is_error (Recovery_store.initialize ~root replacement));
      let unexpected = Filename.concat directory "unexpected" in
      let descriptor =
        Unix.openfile unexpected
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ]
          0o600
      in
      Unix.close descriptor;
      Alcotest.(check bool)
        "unknown recovery entry fails closed" true
        (Result.is_error (Recovery_store.read_package ~root));
      Alcotest.(check string)
        "bootstrap remains public-only"
        (Bootstrap.encode bootstrap)
        (Bootstrap_store.read_bootstrap ~root
        |> require_ok Bootstrap_store.error_to_string
        |> Bootstrap.encode))

let generated_ceremony_recovers_and_corrupt_persistence_refuses () =
  let ceremony =
    Recovery.create ~authority ~root |> require_ok Recovery.error_to_string
  in
  Alcotest.(check int)
    "CSPRNG secret is 256 bits" 64
    (String.length (Recovery.recovery_secret_to_hex ceremony.Recovery.secret));
  Recovery.verify_phrase ceremony.Recovery.secret
    ceremony.Recovery.verification_phrase
  |> require_ok Recovery.error_to_string;
  Recovery.recover ~secret:ceremony.Recovery.secret
    ~verification_phrase:ceremony.Recovery.verification_phrase
    ~package:ceremony.Recovery.package
  |> require_ok Recovery.error_to_string
  |> ignore;
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      ignore
        (Recovery_store.initialize ~root ceremony.Recovery.package
        |> require_ok Recovery_store.error_to_string);
      let path = Recovery_store.recovery_path ~root in
      let descriptor =
        Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600
      in
      Fun.protect
        ~finally:(fun () -> Unix.close descriptor)
        (fun () ->
          ignore (Unix.write descriptor (Bytes.of_string "corrupt") 0 7));
      Alcotest.(check bool)
        "corrupt durable package refuses" true
        (Result.is_error (Recovery_store.read_package ~root));
      Alcotest.(check bool)
        "corrupt package is never overwritten on retry" true
        (Result.is_error
           (Recovery_store.initialize ~root ceremony.Recovery.package)))

let () =
  Alcotest.run "V2 offline recovery"
    [
      ( "unit",
        [
          Alcotest.test_case
            "canonical package recovers proposed replacement device" `Quick
            canonical_recovery_and_replacement_certificate;
          Alcotest.test_case "phrase secret ciphertext and loss failures refuse"
            `Quick recovery_refuses_phrase_secret_and_ciphertext_failures;
          Alcotest.test_case "feature root and header mismatches refuse" `Quick
            recovery_rejects_feature_root_and_header_payload_mismatches;
          Alcotest.test_case
            "durable package is create-only and interrupted staging is inert"
            `Quick
            durable_package_is_create_only_and_staging_is_non_authoritative;
          Alcotest.test_case "generated ceremony and corrupt storage failures"
            `Quick generated_ceremony_recovers_and_corrupt_persistence_refuses;
        ] );
    ]
