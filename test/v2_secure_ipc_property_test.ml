module Ipc = Yeokcham_v2_secure_ipc

let require = function Ok value -> value | Error _ -> assert false

let seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:17
  | None -> 17

let session_bytes = QCheck2.Gen.string_size (QCheck2.Gen.return 32)
let payload = QCheck2.Gen.string_size (QCheck2.Gen.int_range 0 512)

let operation =
  QCheck2.Gen.oneof_list
    [ Ipc.Mls_operation; Ipc.Device_crypto_operation; Ipc.Mesh_operation ]

let property =
  QCheck2.Test.make ~count:120
    ~name:"bounded negotiated secure IPC requests round-trip and sequence once"
    (QCheck2.Gen.triple session_bytes payload operation)
    (fun (session_bytes, payload, operation) ->
      match Ipc.Session_id.of_bytes session_bytes with
      | Error _ -> false
      | Ok session_id -> (
          let capability = Ipc.operation_capability operation in
          let hello =
            Ipc.make_hello ~session_id ~supported_versions:[ 1L ]
              ~required_capabilities:[ capability ] ~optional_capabilities:[]
              ~mandatory_features:0L
            |> require
          in
          let server =
            Ipc.make_server ~supported_versions:[ 1L ]
              ~capabilities:[ capability ]
            |> require
          in
          match Ipc.accept_hello server hello with
          | Error _ -> false
          | Ok (server, acknowledgement) -> (
              match Ipc.validate_hello_ack ~hello acknowledgement with
              | Error _ -> false
              | Ok negotiated -> (
                  match
                    Ipc.make_request ~negotiated ~sequence:0L ~operation
                      ~payload ~mandatory_features:0L
                  with
                  | Error _ -> false
                  | Ok request -> (
                      Result.is_ok
                        (Ipc.decode (Ipc.encode (Ipc.Request request)))
                      &&
                      match Ipc.accept_request server request with
                      | Error _ -> false
                      | Ok advanced ->
                          Result.is_error (Ipc.accept_request advanced request))
                  ))))

let () =
  Alcotest.run "V2 secure runtime IPC properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(Random.State.make [| seed |])
            property;
        ] );
    ]
