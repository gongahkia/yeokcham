module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Exchange = Yeokcham_exchange
module Http = Yeokcham_http_exchange
module Store = Yeokcham_store

let require format = function
  | Ok value -> value
  | Error error -> Alcotest.fail (format error)

let require_http result = require Http.error_to_string result
let require_store result = require Store.error_to_string result
let require_envelope result = require Envelope.creation_error_to_string result

let session =
  Exchange.session_id_of_bytes "http-session-001"
  |> require Exchange.error_to_string

let content bytes =
  Envelope.create ~object_type:Envelope.Content
    ~object_format_version:Envelope.current_object_format_version
    ~mandatory_features:Envelope.supported_mandatory_features
    ~payload:(Encoding.bytes bytes) ()
  |> require_envelope

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
  let root = Filename.temp_file "yeokcham-http-exchange-" "" in
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

let sorted ids = List.sort Store.Stored_object_id.compare ids

let in_process_http_is_bounded () =
  with_repositories (fun source destination ->
      let objects =
        [
          Store.put source (content "one") |> require_store;
          Store.put source (content "two") |> require_store;
        ]
        |> sorted
      in
      let server = ref (Http.create_server destination |> require_http) in
      let send request =
        match Http.handle !server request with
        | Ok (next, response) ->
            server := next;
            Ok response
        | Error error -> Error error
      in
      let outcome =
        Http.transfer_with ~source ~send ~session_id:session ~object_ids:objects
          ()
        |> require_http
      in
      Alcotest.(check int) "all offered" 2 outcome.Http.offered;
      Alcotest.(check int)
        "all transferred" 2
        (List.length outcome.Http.transferred);
      List.iter
        (fun object_id ->
          ignore (Store.get destination object_id |> require_store))
        objects;
      Alcotest.(check bool)
        "bad HTTP method is structured" true
        (Result.is_error
           (Http.handle !server
              "GET /v1/exchange HTTP/1.1\r\nContent-Length: 0\r\n\r\n")))

let serve_connections destination listener count =
  let rec loop server remaining =
    if remaining = 0 then ()
    else
      let connection, _ = Unix.accept listener in
      let next =
        Fun.protect
          ~finally:(fun () -> Unix.close connection)
          (fun () -> Http.serve_once server connection |> require_http)
      in
      loop next (remaining - 1)
  in
  Http.create_server destination |> require_http |> fun server ->
  loop server count

let start_server destination connections =
  let listener = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt listener Unix.SO_REUSEADDR true;
  Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen listener 8;
  let port =
    match Unix.getsockname listener with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> Alcotest.fail "TCP listener has Unix address"
  in
  match Unix.fork () with
  | 0 -> (
      try
        serve_connections destination listener connections;
        Unix.close listener;
        exit 0
      with _ ->
        Unix.close listener;
        exit 1)
  | child ->
      Unix.close listener;
      ( child,
        Http.endpoint ~address:Unix.inet_addr_loopback ~port |> require_http )

let wait_success child =
  match Unix.waitpid [] child with
  | _, Unix.WEXITED 0 -> ()
  | _, Unix.WEXITED status -> Alcotest.failf "HTTP server exited %d" status
  | _, Unix.WSIGNALED signal -> Alcotest.failf "HTTP server signalled %d" signal
  | _, Unix.WSTOPPED signal -> Alcotest.failf "HTTP server stopped %d" signal

let local_tcp_restart_preserves_ref () =
  with_repositories (fun source destination ->
      let objects =
        [
          Store.put source (content "one") |> require_store;
          Store.put source (content "two") |> require_store;
        ]
        |> sorted
      in
      let local =
        Store.put destination (content "destination") |> require_store
      in
      let reference =
        Store.compare_and_swap_ref destination ~name:"scratch-head"
          ~expected:None ~target:(Some local)
        |> require_store
      in
      let child, endpoint = start_server destination 3 in
      Alcotest.(check bool)
        "interruption is explicit" true
        (Result.is_error
           (Http.transfer ~interrupt_after:1 ~source ~endpoint
              ~session_id:session ~object_ids:objects ()));
      wait_success child;
      let child, endpoint = start_server destination 4 in
      let outcome =
        Http.transfer ~source ~endpoint ~session_id:session ~object_ids:objects
          ()
        |> require_http
      in
      wait_success child;
      Alcotest.(check int)
        "restart transfers remaining object" 1
        (List.length outcome.Http.transferred);
      let destination =
        Store.open_repository ~root:(Store.root destination) |> require_store
      in
      List.iter
        (fun object_id ->
          ignore (Store.get destination object_id |> require_store))
        objects;
      let actual =
        Store.read_ref destination ~name:"scratch-head" |> require_store
      in
      Alcotest.(check bool)
        "HTTP transfer preserves ref" true
        (Option.exists (Store.Mutable_ref.equal reference) actual))

let () =
  Alcotest.run "bounded local HTTP exchange"
    [
      ( "protocol",
        [
          Alcotest.test_case "in-process HTTP validates and transfers" `Quick
            in_process_http_is_bounded;
        ] );
      ( "local TCP",
        [
          Alcotest.test_case "restart reoffers objects and preserves refs" `Slow
            local_tcp_restart_preserves_ref;
        ] );
    ]
