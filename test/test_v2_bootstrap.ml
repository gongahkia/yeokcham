module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_v2_model
module Store = Yeokcham_store
module Golden = Yeokcham_testkit.Golden_fixture

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let private_key byte =
  Mirage_crypto_ec.Ed25519.priv_of_octets (String.make 32 byte)
  |> require_ok (fun error ->
      Format.asprintf "%a" Mirage_crypto_ec.pp_error error)

let capability ?(encryption = 'e') ?(address = 'a') ?(signing = 's') () =
  let encryption_key =
    Envelope.key_of_bytes (String.make 32 encryption)
    |> require_ok Envelope.error_to_string
  in
  let address_key =
    Address.key_of_bytes (String.make 32 address)
    |> require_ok Address.error_to_string
  in
  Bootstrap.make_capability ~encryption_key ~address_key
    ~signing_key:(private_key signing)
  |> require_ok Bootstrap.error_to_string

let repository byte =
  Model.Repository_id.of_bytes (String.make 32 byte)
  |> require_ok Model.identity_error_to_string

let device byte =
  Model.Device_id.of_bytes (String.make 32 byte)
  |> require_ok Model.identity_error_to_string

let key_handle byte =
  Bootstrap.Key_handle.of_bytes (String.make 32 byte)
  |> require_ok Model.identity_error_to_string

let bootstrap ?(repository_byte = 'r') ?(device_byte = 'd')
    ?(key_handle_byte = 'h') capability =
  Bootstrap.make
    ~repository_id:(repository repository_byte)
    ~device_id:(device device_byte)
    ~key_handle:(key_handle key_handle_byte)
    ~capability ~mandatory_features:0L
  |> require_ok Bootstrap.error_to_string

let read_golden name =
  Golden.read_lower_hex_file (Filename.concat "golden" name)
  |> require_ok Fun.id

let canonical_fixture_round_trips () =
  let value = bootstrap (capability ()) in
  let encoded = Bootstrap.encode value in
  Alcotest.(check string)
    "canonical bootstrap bytes"
    (read_golden "v2-local-bootstrap-v2.cbor.hex")
    encoded;
  let decoded =
    Bootstrap.decode encoded |> require_ok Bootstrap.error_to_string
  in
  Alcotest.(check string)
    "repository ID survives canonical decode"
    (Model.Repository_id.to_bytes (repository 'r'))
    (Model.Repository_id.to_bytes (Bootstrap.repository_id decoded));
  Alcotest.(check string)
    "device ID survives canonical decode"
    (Model.Device_id.to_bytes (device 'd'))
    (Model.Device_id.to_bytes (Bootstrap.device_id decoded));
  Alcotest.(check string)
    "key handle survives canonical decode"
    (Bootstrap.Key_handle.to_bytes (key_handle 'h'))
    (Bootstrap.Key_handle.to_bytes (Bootstrap.key_handle decoded));
  Alcotest.(check string)
    "canonical re-encoding is exact" encoded (Bootstrap.encode decoded)

let reused_role_key_material_rejects () =
  let shared =
    String.make 32 'k' |> Envelope.key_of_bytes
    |> require_ok Envelope.error_to_string
  in
  let address =
    String.make 32 'k' |> Address.key_of_bytes
    |> require_ok Address.error_to_string
  in
  Alcotest.(check bool)
    "reused envelope/address bytes reject" true
    (Result.is_error
       (Bootstrap.make_capability ~encryption_key:shared ~address_key:address
          ~signing_key:(private_key 's')));
  let encryption =
    String.make 32 's' |> Envelope.key_of_bytes
    |> require_ok Envelope.error_to_string
  in
  let address =
    String.make 32 'a' |> Address.key_of_bytes
    |> require_ok Address.error_to_string
  in
  Alcotest.(check bool)
    "reused envelope/signing bytes reject" true
    (Result.is_error
       (Bootstrap.make_capability ~encryption_key:encryption
          ~address_key:address ~signing_key:(private_key 's')))

let tampered_or_mismatched_capabilities_reject () =
  let original = capability () in
  let value = bootstrap original in
  let encoded = Bytes.of_string (Bootstrap.encode value) in
  Bytes.set encoded
    (Bytes.length encoded - 1)
    (Char.chr (Char.code (Bytes.get encoded (Bytes.length encoded - 1)) lxor 1));
  Alcotest.(check bool)
    "signature tampering rejects" true
    (Result.is_error (Bootstrap.decode (Bytes.unsafe_to_string encoded)));
  let wrong_encryption = capability ~encryption:'x' () in
  Alcotest.(check bool)
    "wrong encryption capability rejects" true
    (Result.is_error
       (Bootstrap.validate_capability ~capability:wrong_encryption value));
  let wrong_address = capability ~address:'x' () in
  Alcotest.(check bool)
    "wrong address capability rejects" true
    (Result.is_error
       (Bootstrap.validate_capability ~capability:wrong_address value));
  let wrong_signer = capability ~signing:'x' () in
  Alcotest.(check bool)
    "wrong signing capability rejects" true
    (Result.is_error
       (Bootstrap.validate_capability ~capability:wrong_signer value))

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
  let root = Filename.temp_file "yeokcham-v2-bootstrap-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let create_only_persistence_and_opening () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let authority = capability () in
      let value = bootstrap authority in
      Alcotest.(check bool)
        "unbootstrapped V2 root rejects opening" true
        (Result.is_error
           (Bootstrap_store.open_repository ~root ~capability:authority));
      Alcotest.(check bool)
        "first bootstrap publication initializes" true
        (Bootstrap_store.initialize ~root value = Ok Bootstrap_store.Initialized);
      Alcotest.(check bool)
        "identical bootstrap retry is idempotent" true
        (Bootstrap_store.initialize ~root value
        = Ok Bootstrap_store.Already_initialized);
      let opened =
        Bootstrap_store.open_repository ~root ~capability:authority
        |> require_ok Bootstrap_store.error_to_string
      in
      Alcotest.(check string)
        "opened public signer matches injected capability"
        (Bootstrap.capability_signer_public_key authority)
        (Bootstrap.signer_public_key (Bootstrap_store.bootstrap opened));
      let incompatible = bootstrap ~repository_byte:'x' authority in
      Alcotest.(check bool)
        "different bootstrap cannot overwrite canonical bytes" true
        (Result.is_error (Bootstrap_store.initialize ~root incompatible)))

let stale_staging_is_non_authoritative_and_unknown_entries_reject () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let authority = capability () in
      let value = bootstrap authority in
      let directory = Filename.dirname (Bootstrap_store.bootstrap_path ~root) in
      let stale =
        Filename.concat directory
          (Printf.sprintf ".%s.bootstrap-42-0" Bootstrap_store.filename)
      in
      let descriptor =
        Unix.openfile stale [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      in
      Unix.close descriptor;
      Alcotest.(check bool)
        "stale strictly named staging file does not block publication" true
        (Result.is_ok (Bootstrap_store.initialize ~root value));
      Alcotest.(check bool)
        "stale staging file does not become authority" true
        (Result.is_ok
           (Bootstrap_store.open_repository ~root ~capability:authority)));
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let authority = capability () in
      let value = bootstrap authority in
      let directory = Filename.dirname (Bootstrap_store.bootstrap_path ~root) in
      let unexpected = Filename.concat directory "unexpected" in
      let descriptor =
        Unix.openfile unexpected
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ]
          0o600
      in
      Unix.close descriptor;
      Alcotest.(check bool)
        "unknown bootstrap entry rejects before publication" true
        (Result.is_error (Bootstrap_store.initialize ~root value));
      Alcotest.(check bool)
        "unknown entry leaves canonical bootstrap absent" false
        (Sys.file_exists (Bootstrap_store.bootstrap_path ~root)))

let () =
  Alcotest.run "V2 local bootstrap"
    [
      ( "unit",
        [
          Alcotest.test_case "canonical fixture and decode" `Quick
            canonical_fixture_round_trips;
          Alcotest.test_case "role separation rejects reused bytes" `Quick
            reused_role_key_material_rejects;
          Alcotest.test_case "tampering and mismatched capabilities reject"
            `Quick tampered_or_mismatched_capabilities_reject;
          Alcotest.test_case "create-only persistence and opening" `Quick
            create_only_persistence_and_opening;
          Alcotest.test_case "staging and unknown-entry persistence failures"
            `Quick stale_staging_is_non_authoritative_and_unknown_entries_reject;
        ] );
    ]
