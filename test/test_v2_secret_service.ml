module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_v2_model
module Secret_service = Yeokcham_v2_secret_service
module Store = Yeokcham_store

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
  Secret_service.key_handle_of_bytes (String.make 32 byte)
  |> require_ok Model.identity_error_to_string

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
  let root = Filename.temp_file "yeokcham-v2-secret-service-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

type availability = Available | Locked | Unavailable

type backend = {
  availability : availability;
  mutable stored : string option;
  mutable commands : Secret_service.command list;
}

let backend ?(stored = None) availability =
  { availability; stored; commands = [] }

let command_result exit_code stdout : Secret_service.command_result =
  { Secret_service.exit_code; stdout }

let runner backend
    ({ Secret_service.program; arguments; stdin } : Secret_service.command) =
  let command = { Secret_service.program; arguments; stdin } in
  backend.commands <- command :: backend.commands;
  match backend.availability with
  | Unavailable -> Error Secret_service.Spawn_failed
  | Locked ->
      if String.equal program "busctl" then Ok (command_result 0 "b true\n")
      else Alcotest.fail "locked service was used after preflight"
  | Available -> (
      match arguments with
      | "--user" :: "get-property" :: _ -> Ok (command_result 0 "b false\n")
      | "lookup" :: _ -> (
          match backend.stored with
          | None -> Ok (command_result 1 "")
          | Some stored -> Ok (command_result 0 (stored ^ "\n")))
      | "store" :: _ ->
          backend.stored <- Some stdin;
          Ok (command_result 0 "")
      | _ -> Alcotest.fail "unexpected Secret Service command")

let service backend =
  Secret_service.service ~runner:(runner backend) ~secret_tool:"secret-tool"
    ~busctl:"busctl"

let contains ~needle haystack =
  let length = String.length needle in
  let rec search offset =
    offset + length <= String.length haystack
    && (String.equal (String.sub haystack offset length) needle
       || search (offset + 1))
  in
  length > 0 && search 0

let has_error expected = function
  | Ok _ -> false
  | Error error ->
      String.equal
        (Secret_service.error_to_string expected)
        (Secret_service.error_to_string error)

let service_enrollment_stores_no_secret_in_repository_or_arguments () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let backend = backend Available in
      let authority = capability () in
      let enrolled =
        Secret_service.enroll ~service:(service backend) ~root
          ~repository_id:(repository 'r') ~device_id:(device 'd')
          ~key_handle:(key_handle 'h') ~capability:authority
        |> require_ok Secret_service.error_to_string
      in
      let { Secret_service.initialization; repository = _ } = enrolled in
      Alcotest.(check bool)
        "first key custody enrollment initializes" true
        (initialization = Secret_service.Initialized);
      let bootstrap_bytes =
        In_channel.with_open_bin
          (Filename.concat root ".yeokcham/bootstrap/local-bootstrap-v2.cbor")
          In_channel.input_all
      in
      let encryption_key, address_key, signing_key =
        Bootstrap.secret_material authority
      in
      List.iter
        (fun secret ->
          Alcotest.(check bool)
            "raw private material is absent from repository bytes" false
            (contains ~needle:secret bootstrap_bytes))
        [ encryption_key; address_key; signing_key ];
      let stored = Option.get backend.stored in
      List.iter
        (fun ({ Secret_service.arguments; stdin; _ } : Secret_service.command)
           ->
          Alcotest.(check bool)
            "private capability serialization is absent from command arguments"
            false
            (List.exists (contains ~needle:stored) arguments);
          if List.hd arguments = "store" then
            Alcotest.(check string)
              "only the store command receives capability material on stdin"
              stored stdin
          else
            Alcotest.(check string) "non-store command stdin is empty" "" stdin)
        backend.commands;
      let reopened =
        Secret_service.open_repository ~service:(service backend) ~root
        |> require_ok Secret_service.error_to_string
      in
      Alcotest.(check string)
        "reopened bootstrap retains the enrolled signer"
        (Bootstrap.capability_signer_public_key authority)
        (Bootstrap.signer_public_key
           (Yeokcham_v2_bootstrap_store.bootstrap reopened)))

let locked_and_unavailable_services_fail_closed () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let authority = capability () in
      let enroll backend =
        Secret_service.enroll ~service:(service backend) ~root
          ~repository_id:(repository 'r') ~device_id:(device 'd')
          ~key_handle:(key_handle 'h') ~capability:authority
      in
      Alcotest.(check bool)
        "locked collection rejects enrollment" true
        (has_error Secret_service.Secret_service_locked
           (enroll (backend Locked)));
      Alcotest.(check bool)
        "unavailable service rejects enrollment" true
        (has_error Secret_service.Secret_service_unavailable
           (enroll (backend Unavailable))))

let malformed_or_mismatched_secret_material_refuses_opening () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let backend = backend Available in
      let authority = capability () in
      ignore
        (Secret_service.enroll ~service:(service backend) ~root
           ~repository_id:(repository 'r') ~device_id:(device 'd')
           ~key_handle:(key_handle 'h') ~capability:authority
        |> require_ok Secret_service.error_to_string);
      backend.stored <- Some "not a Yeokcham capability";
      Alcotest.(check bool)
        "malformed capability refuses opening" true
        (Result.is_error
           (Secret_service.open_repository ~service:(service backend) ~root));
      let other = capability ~encryption:'x' ~address:'y' ~signing:'z' () in
      let encryption_key, address_key, signing_key =
        Bootstrap.secret_material other
      in
      let hex bytes =
        let digits = "0123456789abcdef" in
        let encoded = Bytes.create (String.length bytes * 2) in
        String.iteri
          (fun index character ->
            let value = Char.code character in
            Bytes.set encoded (index * 2) digits.[value lsr 4];
            Bytes.set encoded ((index * 2) + 1) digits.[value land 0x0f])
          bytes;
        Bytes.unsafe_to_string encoded
      in
      backend.stored <-
        Some
          (String.concat ":"
             [
               "yeokcham-v2-local-capability-v1:" ^ hex encryption_key;
               hex address_key;
               hex signing_key;
             ]);
      Alcotest.(check bool)
        "mismatched capability refuses opening" true
        (Result.is_error
           (Secret_service.open_repository ~service:(service backend) ~root)))

let duplicate_handle_does_not_overwrite_secret_service_item () =
  with_root (fun root ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      let backend =
        backend ~stored:(Some "another enrolled capability") Available
      in
      let result =
        Secret_service.enroll ~service:(service backend) ~root
          ~repository_id:(repository 'r') ~device_id:(device 'd')
          ~key_handle:(key_handle 'h') ~capability:(capability ())
      in
      Alcotest.(check bool)
        "different existing item rejects" true
        (has_error Secret_service.Secret_handle_in_use result);
      Alcotest.(check bool)
        "store is never invoked for occupied handle" false
        (List.exists
           (fun ({ Secret_service.arguments; _ } : Secret_service.command) ->
             List.hd arguments = "store")
           backend.commands))

let () =
  Alcotest.run "V2 Linux Secret Service custody"
    [
      ( "unit",
        [
          Alcotest.test_case
            "enrollment uses stdin-only secret custody and reopens" `Quick
            service_enrollment_stores_no_secret_in_repository_or_arguments;
          Alcotest.test_case "locked and unavailable services fail closed"
            `Quick locked_and_unavailable_services_fail_closed;
          Alcotest.test_case "malformed and mismatched materials refuse opening"
            `Quick malformed_or_mismatched_secret_material_refuses_opening;
          Alcotest.test_case "occupied handle does not overwrite service item"
            `Quick duplicate_handle_does_not_overwrite_secret_service_item;
        ] );
    ]
