module Device = Yeokcham_device
module Device_store = Yeokcham_device_store
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Event = Yeokcham_ref_event
module Exchange = Yeokcham_exchange
module Exchange_store = Yeokcham_exchange_store
module Golden = Yeokcham_testkit.Golden_fixture
module Store = Yeokcham_store

type signer = {
  identity : Device.t;
  private_key : Mirage_crypto_ec.Ed25519.priv;
}

let require format = function
  | Ok value -> value
  | Error error -> Alcotest.fail (format error)

let require_device result = require Device.error_to_string result
let require_device_store result = require Device_store.error_to_string result
let require_event result = require Event.error_to_string result
let require_envelope result = require Envelope.creation_error_to_string result
let require_exchange result = require Exchange_store.error_to_string result
let require_store result = require Store.error_to_string result

let device_id seed =
  String.init 32 (fun index -> Char.chr ((seed + index) land 255))
  |> Device.device_id_of_bytes |> require_device

let private_key seed =
  String.init 32 (fun index -> Char.chr ((seed + index + 1) land 255))
  |> Mirage_crypto_ec.Ed25519.priv_of_octets
  |> require (fun error -> Format.asprintf "%a" Mirage_crypto_ec.pp_error error)

let signer ?private_seed seed =
  let private_key = private_key (Option.value private_seed ~default:seed) in
  let generated =
    Device.make_generated ~device_id:(device_id seed) ~private_key
      ~mandatory_features:0L
    |> require_device
  in
  { identity = Device.generated_identity generated; private_key }

let signer_a = signer 32

let signed_event signer =
  let observed =
    Event.make_ref_state ~generation:0L ~target:None |> require_event
  in
  let target =
    Store.Stored_object_id.of_raw_bytes (String.make 32 '\001') |> Option.get
  in
  let proposed =
    Event.make_ref_state ~generation:1L ~target:(Some target) |> require_event
  in
  let unsigned =
    Event.make_unsigned ~repository_format:Store.repository_format
      ~ref_name:"scratch-head"
      ~signer_key_id:(Device.signer_key_id signer.identity)
      ~signer_sequence:0L ~previous:None ~observed ~proposed
      ~mandatory_features:0L
    |> require_event
  in
  let signature =
    Event.signing_bytes unsigned
    |> require_event
    |> Mirage_crypto_ec.Ed25519.sign ~key:signer.private_key
  in
  Event.make ~unsigned ~algorithm:Event.algorithm ~signature |> require_event

let verified_event signer =
  let trusted_keys =
    [
      {
        Event.key_id = Device.signer_key_id signer.identity;
        public_key = Device.public_key signer.identity;
      };
    ]
  in
  match
    Event.verify_for_device ~repository_format:Store.repository_format
      ~trusted_keys (signed_event signer)
    |> require_event
  with
  | Some verified -> verified
  | None -> Alcotest.fail "expected trusted event"

let require_golden name =
  Golden.read_lower_hex_file (Filename.concat "golden" name) |> require Fun.id

let refreshed_golden name actual =
  Golden.refresh_lower_hex_file (Filename.concat "golden" name) actual
  |> require Fun.id

let canonical_identity_golden () =
  let envelope = Device.identity_envelope signer_a.identity |> require_device in
  let actual = Envelope.encode envelope in
  let expected = refreshed_golden "device-identity-v1.yeok.hex" actual in
  Alcotest.(check string) "identity envelope golden" expected actual;
  let decoded_envelope =
    Envelope.decode expected |> require Envelope.decode_error_to_string
  in
  Alcotest.(check bool)
    "identity type" true
    (Envelope.object_type decoded_envelope = Envelope.Device_identity);
  let decoded =
    Device.decode_identity_payload (Envelope.payload decoded_envelope)
    |> require_device
  in
  Alcotest.(check bool)
    "identity payload is canonical" true
    (Device.identity_payload decoded
    |> require_device
    |> Encoding.equal (Envelope.payload decoded_envelope));
  Alcotest.(check bool)
    "device ID survives decoding" true
    (Device.Device_id.equal
       (Device.device_id signer_a.identity)
       (Device.device_id decoded))

let rejects_invalid_inputs () =
  Alcotest.(check bool)
    "malformed payload rejects" true
    (Result.is_error (Device.decode_identity_payload Encoding.null));
  let invalid_algorithm =
    match Device.identity_payload signer_a.identity |> require_device with
    | Encoding.Array [ version; device; key_id; _; public_key; features ] ->
        let algorithm =
          Encoding.text "not-ed25519"
          |> require (fun error -> Encoding.construction_error_to_string error)
        in
        Encoding.array
          [ version; device; key_id; algorithm; public_key; features ]
        |> require (fun error -> Encoding.construction_error_to_string error)
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
        Alcotest.fail "identity payload is not six fields"
  in
  Alcotest.(check bool)
    "unknown algorithm rejects" true
    (Result.is_error (Device.decode_identity_payload invalid_algorithm));
  let unsupported_feature =
    match Device.identity_payload signer_a.identity |> require_device with
    | Encoding.Array [ version; device; key_id; algorithm; public_key; _ ] ->
        Encoding.array
          [
            version; device; key_id; algorithm; public_key; Encoding.integer 1L;
          ]
        |> require (fun error -> Encoding.construction_error_to_string error)
    | Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
    | Encoding.Bool _ | Encoding.Null | Encoding.Array _ ->
        Alcotest.fail "identity payload is not six fields"
  in
  Alcotest.(check bool)
    "unknown feature rejects" true
    (Result.is_error (Device.decode_identity_payload unsupported_feature));
  let envelope = Device.identity_envelope signer_a.identity |> require_device in
  let object_id = Store.id_of_envelope envelope in
  let invalid_object_id =
    Store.Stored_object_id.of_raw_bytes (String.make 32 '\255') |> Option.get
  in
  Alcotest.(check bool)
    "wrong object ID rejects" true
    (Result.is_error
       (Device.registry_entry ~identity:signer_a.identity
          ~object_id:invalid_object_id));
  let entry =
    Device.registry_entry ~identity:signer_a.identity ~object_id
    |> require_device
  in
  Alcotest.(check bool)
    "registry bound rejects" true
    (Result.is_error (Device.make_registry (List.init 257 (fun _ -> entry))));
  let private_bytes =
    Mirage_crypto_ec.Ed25519.priv_to_octets signer_a.private_key
  in
  Alcotest.(check bool)
    "private key is not public key" true
    (not (String.equal private_bytes (Device.public_key signer_a.identity)))

let entry signer =
  Device.registry_entry ~identity:signer.identity
    ~object_id:(Device.stored_object_id signer.identity |> require_device)
  |> require_device

let sorted_entries signers =
  signers
  |> List.sort (fun left right ->
      let device =
        Device.Device_id.compare
          (Device.device_id left.identity)
          (Device.device_id right.identity)
      in
      if device <> 0 then device
      else
        Store.Stored_object_id.compare
          (Device.stored_object_id left.identity |> require_device)
          (Device.stored_object_id right.identity |> require_device))
  |> List.map entry

let registry_resolution_is_explicit () =
  let verified = verified_event signer_a in
  let empty = Device.make_registry [] |> require_device in
  Alcotest.(check string)
    "missing declaration is unmapped"
    ("device-unmapped:"
    ^ Device.signer_key_id_to_hex (Device.signer_key_id signer_a.identity))
    (Device.resolve_verified empty verified |> Device.resolution_to_string);
  let duplicate_key = signer ~private_seed:32 96 in
  let registry =
    Device.make_registry (sorted_entries [ signer_a; duplicate_key ])
    |> require_device
  in
  Alcotest.(check bool)
    "duplicate signer is ambiguous" true
    (String.starts_with ~prefix:"device-ambiguous:"
       (Device.resolve_verified registry verified |> Device.resolution_to_string));
  let competing_key = signer ~private_seed:128 32 in
  let registry =
    Device.make_registry (sorted_entries [ signer_a; competing_key ])
    |> require_device
  in
  Alcotest.(check bool)
    "competing declaration for device is ambiguous" true
    (String.starts_with ~prefix:"device-ambiguous:"
       (Device.resolve_verified registry verified |> Device.resolution_to_string))

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

let with_repositories run =
  let root = Filename.temp_file "yeokcham-device-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let source_root = Filename.concat root "source" in
  let destination_root = Filename.concat root "destination" in
  Unix.mkdir source_root 0o700;
  Unix.mkdir destination_root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let source = Store.init ~root:source_root |> require_store in
      let destination = Store.init ~root:destination_root |> require_store in
      run source destination)

let content bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require_envelope

let local_transfer_preserves_ref () =
  with_repositories (fun source destination ->
      let device_object =
        Device_store.store_identity source signer_a.identity
        |> require_device_store
      in
      let local_object =
        Store.put destination (content "destination") |> require_store
      in
      let reference =
        Store.compare_and_swap_ref destination ~name:"scratch-head"
          ~expected:None ~target:(Some local_object)
        |> require_store
      in
      let session =
        Exchange.session_id_of_bytes "device-id-test01"
        |> require Exchange.error_to_string
      in
      Exchange_store.transfer ~source ~destination ~session_id:session
        ~object_ids:[ device_object ] ()
      |> require_exchange |> ignore;
      let destination =
        Store.open_repository ~root:(Store.root destination) |> require_store
      in
      let registry =
        Device_store.registry_of_objects destination [ device_object ]
        |> require_device_store
      in
      Alcotest.(check string)
        "transferred identity resolves"
        ("device-resolved:"
        ^ Device.Device_id.to_hex (Device.device_id signer_a.identity)
        ^ ":"
        ^ Store.Stored_object_id.to_hex device_object)
        (Device.resolve_verified registry (verified_event signer_a)
        |> Device.resolution_to_string);
      let actual =
        Store.read_ref destination ~name:"scratch-head" |> require_store
      in
      Alcotest.(check bool)
        "transfer and resolution left ref unchanged" true
        (Option.exists (Store.Mutable_ref.equal reference) actual))

let entropy_generation_is_distinct () =
  let first =
    Device.generate () |> require_device |> Device.generated_identity
  in
  let second =
    Device.generate () |> require_device |> Device.generated_identity
  in
  Alcotest.(check bool)
    "OS CSPRNG device IDs differ" true
    (not
       (Device.Device_id.equal (Device.device_id first)
          (Device.device_id second)))

let () =
  Alcotest.run "local device identities"
    [
      ( "core",
        [
          Alcotest.test_case "canonical public identity golden" `Quick
            canonical_identity_golden;
          Alcotest.test_case "invalid identity inputs are structured" `Quick
            rejects_invalid_inputs;
          Alcotest.test_case "registry resolution stays explicit" `Quick
            registry_resolution_is_explicit;
          Alcotest.test_case "OS entropy generates distinct device IDs" `Quick
            entropy_generation_is_distinct;
        ] );
      ( "local store",
        [
          Alcotest.test_case "two local devices preserve refs" `Quick
            local_transfer_preserves_ref;
        ] );
    ]
