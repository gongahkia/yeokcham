module Ipc = Yeokcham_v2_secure_ipc
module Golden = Yeokcham_testkit.Golden_fixture

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let session byte =
  Ipc.Session_id.of_bytes (String.make 32 byte)
  |> require_ok Ipc.Model.identity_error_to_string

let hello ?(required = [ Ipc.Mls ]) ?(optional = [ Ipc.Mesh ])
    ?(session_id = session 's') () =
  Ipc.make_hello ~session_id ~supported_versions:[ 1L; 2L ]
    ~required_capabilities:required ~optional_capabilities:optional
    ~mandatory_features:0L
  |> require_ok Ipc.error_to_string

let make_server ?(capabilities = [ Ipc.Mls; Ipc.Mesh ]) () =
  Ipc.make_server ~supported_versions:[ 1L ] ~capabilities
  |> require_ok Ipc.error_to_string

let negotiate server hello =
  let server, acknowledgement =
    Ipc.accept_hello server hello |> require_ok Ipc.error_to_string
  in
  let negotiated =
    Ipc.validate_hello_ack ~hello acknowledgement
    |> require_ok Ipc.error_to_string
  in
  (server, negotiated, acknowledgement)

let read_golden name =
  Golden.read_lower_hex_file (Filename.concat "golden" name)
  |> require_ok Fun.id

let protocol_vectors_and_dispatch_are_canonical () =
  let hello = hello () in
  let server, negotiated, acknowledgement = negotiate (make_server ()) hello in
  let request =
    Ipc.make_request ~negotiated ~sequence:0L ~operation:Ipc.Mls_operation
      ~payload:"opaque\000request" ~mandatory_features:0L
    |> require_ok Ipc.error_to_string
  in
  let response =
    Ipc.make_response ~request ~result:Ipc.Completed
      ~payload:"opaque\000response" ~mandatory_features:0L
    |> require_ok Ipc.error_to_string
  in
  let messages =
    [
      ("hello", Ipc.Hello hello);
      ("acknowledgement", Ipc.Hello_ack acknowledgement);
      ("request", Ipc.Request request);
      ("response", Ipc.Response response);
    ]
  in
  List.iter
    (fun (name, message) ->
      let encoded = Ipc.encode message in
      Alcotest.(check string)
        (name ^ " canonical golden")
        (read_golden ("v2-secure-ipc-" ^ name ^ "-v1.cbor.hex"))
        encoded;
      let decoded = Ipc.decode encoded |> require_ok Ipc.error_to_string in
      Alcotest.(check string)
        (name ^ " canonical re-encode")
        encoded (Ipc.encode decoded))
    messages;
  Ipc.accept_request server request |> require_ok Ipc.error_to_string |> ignore;
  Ipc.validate_response ~request response |> require_ok Ipc.error_to_string

let negotiation_and_adversarial_refusals () =
  let incompatible = hello ~required:[ Ipc.Device_crypto ] ~optional:[] () in
  Alcotest.(check bool)
    "missing required capability refuses" true
    (Result.is_error (Ipc.accept_hello (make_server ()) incompatible));
  let initial_hello = hello () in
  let server, initial_negotiated, _ =
    negotiate (make_server ()) initial_hello
  in
  let request =
    Ipc.make_request ~negotiated:initial_negotiated ~sequence:0L
      ~operation:Ipc.Mls_operation ~payload:"payload" ~mandatory_features:0L
    |> require_ok Ipc.error_to_string
  in
  let server =
    Ipc.accept_request server request |> require_ok Ipc.error_to_string
  in
  Alcotest.(check bool)
    "duplicate sequence refuses" true
    (Result.is_error (Ipc.accept_request server request));
  let gap =
    Ipc.make_request ~negotiated:initial_negotiated ~sequence:2L
      ~operation:Ipc.Mls_operation ~payload:"payload" ~mandatory_features:0L
    |> require_ok Ipc.error_to_string
  in
  Alcotest.(check bool)
    "gapped sequence refuses" true
    (Result.is_error (Ipc.accept_request server gap));
  let oversized = String.make (Ipc.max_payload_bytes + 1) 'x' in
  Alcotest.(check bool)
    "oversized payload refuses" true
    (Result.is_error
       (Ipc.make_request ~negotiated:initial_negotiated ~sequence:1L
          ~operation:Ipc.Mls_operation ~payload:oversized ~mandatory_features:0L));
  Alcotest.(check bool)
    "unknown mandatory feature refuses" true
    (Result.is_error
       (Ipc.make_hello ~session_id:(session 'f') ~supported_versions:[ 1L ]
          ~required_capabilities:[ Ipc.Mls ] ~optional_capabilities:[]
          ~mandatory_features:1L));
  Alcotest.(check bool)
    "malformed bytes refuse" true
    (Result.is_error (Ipc.decode "not-cbor"));
  let corrupted = Bytes.of_string (Ipc.encode (Ipc.Request request)) in
  Bytes.set corrupted 0 (Char.chr 0x9f);
  Alcotest.(check bool)
    "noncanonical bytes refuse" true
    (Result.is_error (Ipc.decode (Bytes.unsafe_to_string corrupted)));
  let unknown_feature = Bytes.of_string (Ipc.encode (Ipc.Request request)) in
  Bytes.set unknown_feature (Bytes.length unknown_feature - 1) '\001';
  Alcotest.(check bool)
    "unknown wire feature refuses" true
    (Result.is_error (Ipc.decode (Bytes.unsafe_to_string unknown_feature)));
  let other_hello = hello ~session_id:(session 'o') () in
  let _, other_negotiated, _ = negotiate (make_server ()) other_hello in
  let other_request =
    Ipc.make_request ~negotiated:other_negotiated ~sequence:0L
      ~operation:Ipc.Mls_operation ~payload:"other" ~mandatory_features:0L
    |> require_ok Ipc.error_to_string
  in
  let other_response =
    Ipc.make_response ~request:other_request ~result:Ipc.Completed
      ~payload:"other" ~mandatory_features:0L
    |> require_ok Ipc.error_to_string
  in
  Alcotest.(check bool)
    "mismatched response refuses" true
    (Result.is_error (Ipc.validate_response ~request other_response))

let restart_invalidates_old_session () =
  let initial_hello = hello () in
  let first_server, initial_negotiated, _ =
    negotiate (make_server ()) initial_hello
  in
  let request =
    Ipc.make_request ~negotiated:initial_negotiated ~sequence:0L
      ~operation:Ipc.Mls_operation ~payload:"before-restart"
      ~mandatory_features:0L
    |> require_ok Ipc.error_to_string
  in
  Ipc.accept_request first_server request
  |> require_ok Ipc.error_to_string
  |> ignore;
  Alcotest.(check bool)
    "old request is stale after runtime restart" true
    (Result.is_error (Ipc.accept_request (make_server ()) request));
  let next_hello = hello ~session_id:(session 'n') () in
  let restarted, next_negotiated, _ = negotiate (make_server ()) next_hello in
  let next_request =
    Ipc.make_request ~negotiated:next_negotiated ~sequence:0L
      ~operation:Ipc.Mls_operation ~payload:"after-restart"
      ~mandatory_features:0L
    |> require_ok Ipc.error_to_string
  in
  Ipc.accept_request restarted next_request
  |> require_ok Ipc.error_to_string
  |> ignore

let transport_framing_rejects_truncation_and_size () =
  let left, right = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close left;
      Unix.close right)
    (fun () ->
      let hello = Ipc.Hello (hello ()) in
      Ipc.Transport.write left hello |> require_ok Ipc.Transport.error_to_string;
      let received =
        Ipc.Transport.read right |> require_ok Ipc.Transport.error_to_string
      in
      Alcotest.(check string)
        "socketpair preserves exact frame" (Ipc.encode hello)
        (Ipc.encode received));
  let left, right = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close left;
      Unix.close right)
    (fun () ->
      ignore (Unix.write left (Bytes.of_string "\000\000\000\005") 0 4);
      Unix.shutdown left Unix.SHUTDOWN_SEND;
      Alcotest.(check bool)
        "truncated payload refuses" true
        (Result.is_error (Ipc.Transport.read right)));
  let left, right = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close left;
      Unix.close right)
    (fun () ->
      let size = Ipc.max_frame_bytes + 1 in
      let header =
        Bytes.init 4 (fun shift ->
            Char.chr ((size lsr ((3 - shift) * 8)) land 0xff))
      in
      ignore (Unix.write left header 0 4);
      Alcotest.(check bool)
        "oversized framing refuses before allocation" true
        (Result.is_error (Ipc.Transport.read right)))

let () =
  Alcotest.run "V2 secure runtime IPC"
    [
      ( "unit",
        [
          Alcotest.test_case "canonical vectors and dispatch" `Quick
            protocol_vectors_and_dispatch_are_canonical;
          Alcotest.test_case "negotiation and adversarial refusals" `Quick
            negotiation_and_adversarial_refusals;
          Alcotest.test_case "restart invalidates old session" `Quick
            restart_invalidates_old_session;
          Alcotest.test_case "bounded socket framing failures" `Quick
            transport_framing_rejects_truncation_and_size;
        ] );
    ]
