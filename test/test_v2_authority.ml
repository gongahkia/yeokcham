module Authority = Yeokcham_v2_authority
module Address = Yeokcham_v2_address
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_v2_envelope
module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_v2_model
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store
module Store = Yeokcham_store

let default_seed = 20_260_813

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let state_for name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  Random.State.make [| !value |]

let () = Printf.printf "v2 authority property base seed: %d\n%!" base_seed

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let require_some message = function
  | Some value -> value
  | None -> Alcotest.fail message

let refreshed_golden name actual =
  Golden.refresh_lower_hex_file (Filename.concat "golden" name) actual
  |> require_ok Fun.id

let private_key seed =
  String.init 32 (fun index -> Char.chr ((seed + index) land 255))

let root seed =
  Authority.root_signing_capability_of_private_key (private_key seed)
  |> require_ok Authority.error_to_string

let signer_public_key seed =
  Mirage_crypto_ec.Ed25519.priv_of_octets (private_key seed)
  |> require_ok (fun error ->
      Format.asprintf "%a" Mirage_crypto_ec.pp_error error)
  |> Mirage_crypto_ec.Ed25519.pub_of_priv
  |> Mirage_crypto_ec.Ed25519.pub_to_octets

let repository character =
  Model.Repository_id.of_bytes (String.make 32 character)
  |> require_ok Model.identity_error_to_string

let device character =
  Model.Device_id.of_bytes (String.make 32 character)
  |> require_ok Model.identity_error_to_string

let address_key =
  Address.key_of_bytes (String.make 32 'a')
  |> require_ok Address.error_to_string

let encryption_key =
  Envelope.key_of_bytes (String.make 32 'e')
  |> require_ok Envelope.error_to_string

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

let with_v2_repository repository_id run =
  let root = Filename.temp_file "yeokcham-v2-authority-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let repository =
        Object_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key
        |> require_ok Object_store.error_to_string
      in
      run root repository)

let envelope nonce_offset object_ =
  let nonce =
    Envelope.nonce_of_bytes
      (String.init 12 (fun index -> Char.chr ((nonce_offset + index) land 255)))
    |> require_ok Envelope.error_to_string
  in
  Envelope.seal ~key:encryption_key ~nonce ~mandatory_features:0L
    (Object.encode object_)
  |> require_ok Envelope.error_to_string

type values = {
  authority : Authority.repository_authority;
  certificate : Authority.device_certificate;
  revocation : Authority.device_revocation;
}

let values ?(repository_id = repository 'r') ?(device_id = device 'd') () =
  let root = root 1 in
  let authority =
    Authority.make_repository_authority ~repository_id ~root
      ~mandatory_features:0L
    |> require_ok Authority.error_to_string
  in
  let certificate =
    Authority.make_device_certificate ~authority ~root ~device_id
      ~signer_public_key:(signer_public_key 67)
      ~envelope_key_commitment:(String.make 32 'e')
      ~address_key_commitment:(String.make 32 'a')
      ~key_handle:(String.make 32 'h') ~mandatory_features:0L
    |> require_ok Authority.error_to_string
  in
  let revocation =
    Authority.make_device_revocation ~authority ~root ~certificate
      ~mandatory_features:0L
    |> require_ok Authority.error_to_string
  in
  { authority; certificate; revocation }

let replace_field encoded index replacement =
  match Encoding.decode encoded with
  | Ok (Encoding.Array values) ->
      let rec replace offset = function
        | [] -> Alcotest.fail "authority field is absent"
        | _ :: rest when offset = index -> replacement :: rest
        | value :: rest -> value :: replace (offset + 1) rest
      in
      Encoding.array (replace 0 values)
      |> require_ok Encoding.construction_error_to_string
      |> Encoding.encode
  | Ok
      ( Encoding.Integer _ | Encoding.Bytes _ | Encoding.Text _ | Encoding.Map _
      | Encoding.Bool _ | Encoding.Null ) ->
      Alcotest.fail "authority record is not an array"
  | Error error -> Alcotest.fail (Encoding.decode_error_to_string error)

let canonical_records_round_trip () =
  let values = values () in
  let authority_bytes =
    Authority.encode_repository_authority values.authority
  in
  let certificate_bytes =
    Authority.encode_device_certificate values.certificate
  in
  let revocation_bytes = Authority.encode_device_revocation values.revocation in
  Alcotest.(check string)
    "repository authority golden"
    (refreshed_golden "v2-repository-authority-v1.cbor.hex" authority_bytes)
    authority_bytes;
  Alcotest.(check string)
    "device certificate golden"
    (refreshed_golden "v2-device-certificate-v1.cbor.hex" certificate_bytes)
    certificate_bytes;
  Alcotest.(check string)
    "device revocation golden"
    (refreshed_golden "v2-device-revocation-v1.cbor.hex" revocation_bytes)
    revocation_bytes;
  let decoded_authority =
    Authority.decode_repository_authority authority_bytes
    |> require_ok Authority.error_to_string
  in
  let decoded_certificate =
    Authority.decode_device_certificate ~authority:decoded_authority
      certificate_bytes
    |> require_ok Authority.error_to_string
  in
  let decoded_revocation =
    Authority.decode_device_revocation ~authority:decoded_authority
      revocation_bytes
    |> require_ok Authority.error_to_string
  in
  Alcotest.(check string)
    "repository authority canonical round trip" authority_bytes
    (Authority.encode_repository_authority decoded_authority);
  Alcotest.(check string)
    "device certificate canonical round trip" certificate_bytes
    (Authority.encode_device_certificate decoded_certificate);
  Alcotest.(check string)
    "device revocation canonical round trip" revocation_bytes
    (Authority.encode_device_revocation decoded_revocation);
  let check_frame name golden expected frame =
    let encoded = Object.encode frame in
    let decoded = Object.decode encoded |> require_ok Object.error_to_string in
    Alcotest.(check bool) (name ^ " kind") true (Object.kind decoded = expected);
    Alcotest.(check string)
      (name ^ " golden bytes")
      (refreshed_golden golden encoded)
      encoded
  in
  check_frame "repository authority has a typed object frame"
    "v2-object-repository-authority-frame-v1.cbor.hex"
    Object.Repository_authority
    (Object.repository_authority values.authority);
  check_frame "device certificate has a typed object frame"
    "v2-object-device-certificate-frame-v1.cbor.hex" Object.Device_certificate
    (Object.device_certificate values.certificate);
  check_frame "device revocation has a typed object frame"
    "v2-object-device-revocation-frame-v1.cbor.hex" Object.Device_revocation
    (Object.device_revocation values.revocation)

let evaluator_marks_exact_certificate_revoked () =
  let values = values () in
  let state =
    Authority.evaluate ~authority:values.authority
      ~certificates:[ values.certificate ] ~revocations:[ values.revocation ]
    |> require_ok Authority.error_to_string
  in
  match
    Authority.device_status state
      (Authority.device_certificate_device_id values.certificate)
  with
  | Some (Authority.Revoked revocation) ->
      Alcotest.(check string)
        "revocation matches certificate"
        (Model.Device_revocation_id.to_hex
           (Authority.device_revocation_id values.revocation))
        (Model.Device_revocation_id.to_hex
           (Authority.device_revocation_id revocation))
  | Some Authority.Active -> Alcotest.fail "revoked certificate remained active"
  | None -> Alcotest.fail "certificate disappeared from authority state"

let invalid_records_fail_closed () =
  let values = values () in
  let certificate_bytes =
    Authority.encode_device_certificate values.certificate
  in
  let tampered_identity =
    replace_field certificate_bytes 4 (Encoding.bytes (String.make 32 'z'))
  in
  ((match
      Authority.decode_device_certificate ~authority:values.authority
        tampered_identity
    with
  | Error (Authority.Invalid_identity _) -> ()
  | Error error -> Alcotest.fail (Authority.error_to_string error)
  | Ok _ -> Alcotest.fail "tampered certificate identity was accepted")
  [@warning "-4"]);
  let unsupported_features =
    replace_field certificate_bytes 10 (Encoding.integer 1L)
  in
  ((match
      Authority.decode_device_certificate ~authority:values.authority
        unsupported_features
    with
  | Error (Authority.Unsupported_mandatory_features 1L) -> ()
  | Error error -> Alcotest.fail (Authority.error_to_string error)
  | Ok _ -> Alcotest.fail "unknown certificate feature was accepted")
  [@warning "-4"]);
  let another_root = root 201 in
  let foreign_authority =
    Authority.make_repository_authority
      ~repository_id:
        (Authority.repository_authority_repository_id values.authority)
      ~root:another_root ~mandatory_features:0L
    |> require_ok Authority.error_to_string
  in
  ((match
      Authority.decode_device_certificate ~authority:foreign_authority
        certificate_bytes
    with
  | Error (Authority.Authority_mismatch _) -> ()
  | Error error -> Alcotest.fail (Authority.error_to_string error)
  | Ok _ -> Alcotest.fail "cross-root certificate was accepted")
  [@warning "-4"]);
  let root = root 1 in
  (match
     Authority.make_device_certificate ~authority:values.authority ~root
       ~device_id:(Authority.device_certificate_device_id values.certificate)
       ~signer_public_key:(Authority.root_public_key root)
       ~envelope_key_commitment:(String.make 32 'e')
       ~address_key_commitment:(String.make 32 'a')
       ~key_handle:(String.make 32 'q') ~mandatory_features:0L
   with
  | Error Authority.Reused_root_as_device_signer -> ()
  | Error error -> Alcotest.fail (Authority.error_to_string error)
  | Ok _ -> Alcotest.fail "root key was accepted as a device signer")
  [@warning "-4"]

let duplicate_devices_are_rejected () =
  let values = values () in
  let root = root 1 in
  let replacement =
    Authority.make_device_certificate ~authority:values.authority ~root
      ~device_id:(Authority.device_certificate_device_id values.certificate)
      ~signer_public_key:(signer_public_key 97)
      ~envelope_key_commitment:(String.make 32 'x')
      ~address_key_commitment:(String.make 32 'y')
      ~key_handle:(String.make 32 'z') ~mandatory_features:0L
    |> require_ok Authority.error_to_string
  in
  (match
     Authority.evaluate ~authority:values.authority
       ~certificates:[ values.certificate; replacement ]
       ~revocations:[]
   with
  | Error (Authority.Duplicate_device _) -> ()
  | Error error -> Alcotest.fail (Authority.error_to_string error)
  | Ok _ -> Alcotest.fail "two certificates bound the same device")
  [@warning "-4"]

let public_records_publish_create_only_and_reopen () =
  let values = values () in
  let repository_id =
    Authority.repository_authority_repository_id values.authority
  in
  with_v2_repository repository_id (fun root repository ->
      let publish offset object_ =
        match
          Object_store.publish repository ~envelope:(envelope offset object_)
        with
        | Ok (Object_store.Published object_ref) -> object_ref
        | Ok (Object_store.Already_published _) ->
            Alcotest.fail "first authority record publication already existed"
        | Error error -> Alcotest.fail (Object_store.error_to_string error)
      in
      let authority_ref =
        publish 1 (Object.repository_authority values.authority)
      in
      let certificate_ref =
        publish 21 (Object.device_certificate values.certificate)
      in
      let revocation_ref =
        publish 41 (Object.device_revocation values.revocation)
      in
      let reopened =
        Object_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key
        |> require_ok Object_store.error_to_string
      in
      let authority =
        Object_store.load reopened ~object_ref:authority_ref
        |> require_ok Object_store.error_to_string
        |> Object.repository_authority_record
        |> require_some "authority reopened with wrong kind"
      in
      let certificate_payload =
        Object_store.load reopened ~object_ref:certificate_ref
        |> require_ok Object_store.error_to_string
        |> Object.device_certificate_payload
        |> require_some "certificate reopened with wrong kind"
      in
      let revocation_payload =
        Object_store.load reopened ~object_ref:revocation_ref
        |> require_ok Object_store.error_to_string
        |> Object.device_revocation_payload
        |> require_some "revocation reopened with wrong kind"
      in
      let certificate =
        Authority.decode_device_certificate ~authority certificate_payload
        |> require_ok Authority.error_to_string
      in
      let revocation =
        Authority.decode_device_revocation ~authority revocation_payload
        |> require_ok Authority.error_to_string
      in
      Alcotest.(check string)
        "reopened certificate identity"
        (Model.Device_certificate_id.to_hex
           (Authority.device_certificate_id values.certificate))
        (Model.Device_certificate_id.to_hex
           (Authority.device_certificate_id certificate));
      Alcotest.(check string)
        "reopened revocation identity"
        (Model.Device_revocation_id.to_hex
           (Authority.device_revocation_id values.revocation))
        (Model.Device_revocation_id.to_hex
           (Authority.device_revocation_id revocation));
      match
        Object_store.publish reopened
          ~envelope:(envelope 21 (Object.device_certificate values.certificate))
      with
      | Ok (Object_store.Already_published repeated) ->
          Alcotest.(check bool)
            "exact retry preserves certificate address" true
            (Model.Opaque_object_ref.equal certificate_ref repeated)
      | Ok (Object_store.Published _) ->
          Alcotest.fail "certificate retry published a second object"
      | Error error -> Alcotest.fail (Object_store.error_to_string error))

let malformed_authority_payload_does_not_publish () =
  let values = values () in
  let repository_id =
    Authority.repository_authority_repository_id values.authority
  in
  with_v2_repository repository_id (fun _ repository ->
      let valid_payload =
        Authority.encode_device_certificate values.certificate
      in
      let malformed_payload =
        String.sub valid_payload 0 (String.length valid_payload - 1)
      in
      let plaintext =
        Encoding.array
          [
            Encoding.integer Object.current_schema_version;
            Encoding.integer 14L;
            Encoding.bytes malformed_payload;
            Encoding.integer 0L;
          ]
        |> require_ok Encoding.construction_error_to_string
        |> Encoding.encode
      in
      let nonce =
        Envelope.nonce_of_bytes (String.make 12 'm')
        |> require_ok Envelope.error_to_string
      in
      let candidate =
        Envelope.seal ~key:encryption_key ~nonce ~mandatory_features:0L
          plaintext
        |> require_ok Envelope.error_to_string
      in
      let object_ref =
        Address.derive ~repository_id ~key:address_key ~envelope:candidate
      in
      Alcotest.(check bool)
        "invalid authority payload rejects before publication" true
        (Result.is_error (Object_store.publish repository ~envelope:candidate));
      Alcotest.(check bool)
        "rejected authority payload leaves no object" false
        (Sys.file_exists (Object_store.object_path repository object_ref)))

let generated_canonical_round_trip =
  QCheck2.Test.make ~count:64
    ~name:"V2 authority records round trip for generated public bindings"
    QCheck2.Gen.(pair char char)
    (fun (first, second) ->
      let values =
        values ~repository_id:(repository first) ~device_id:(device second) ()
      in
      match
        Authority.decode_repository_authority
          (Authority.encode_repository_authority values.authority)
      with
      | Error _ -> false
      | Ok authority ->
          Authority.decode_device_certificate ~authority
            (Authority.encode_device_certificate values.certificate)
          |> Result.is_ok)

let () =
  Alcotest.run "V2 authority records"
    [
      ( "unit",
        [
          Alcotest.test_case "canonical root-signed records round trip" `Quick
            canonical_records_round_trip;
          Alcotest.test_case "revocation changes exact device state" `Quick
            evaluator_marks_exact_certificate_revoked;
          Alcotest.test_case "invalid authority records fail closed" `Quick
            invalid_records_fail_closed;
          Alcotest.test_case "duplicate device certificates are refused" `Quick
            duplicate_devices_are_rejected;
          Alcotest.test_case "public records publish and reopen create-only"
            `Quick public_records_publish_create_only_and_reopen;
          Alcotest.test_case "malformed authority payload does not publish"
            `Quick malformed_authority_payload_does_not_publish;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "authority-records")
            generated_canonical_round_trip;
        ] );
    ]
