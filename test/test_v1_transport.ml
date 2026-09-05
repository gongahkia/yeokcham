module Golden = Yeokcham_testkit.Golden_fixture
module Encoding = Yeokcham_encoding
module Envelope = Yeokcham_envelope
module Model = Yeokcham_v1_model
module Trust = Yeokcham_v1_trust
module Transport = Yeokcham_v1_transport
module Relay = Yeokcham_v1_relay
module Relay_access = Yeokcham_v1_relay_access
module Relay_config = Yeokcham_v1_relay_config
module Relay_http = Yeokcham_v1_relay_http
module Transport_http = Yeokcham_v1_transport_http
module Transport_http_v2 = Yeokcham_v1_transport_http.V2
module Transport_config = Yeokcham_v1_transport_config
module Service = Yeokcham_v1_local_service
module Package = Yeokcham_v1_package
module Store = Yeokcham_v1_store
module Object_store = Yeokcham_store

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

let device capability =
  Trust.signing_public_key capability
  |> Trust.device_of_public_key
  |> require_ok Trust.error_to_string

let repository () =
  Trust.Repository_id.of_string
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  |> Result.get_ok

let relay_test_token () =
  match Sys.getenv_opt "YEOKCHAM_V1_TEST_TRANSPORT_TOKEN" with
  | Some token -> token
  | None -> Alcotest.fail "relay access test token is unavailable"

let authority () =
  let repository = repository () in
  let root_capability = capability 'a' in
  let publisher = device root_capability in
  let certificate =
    Trust.root_certificate ~repository ~device:publisher root_capability
    |> require_ok Trust.error_to_string
  in
  let membership =
    Trust.verify_membership ~repository [ certificate ]
    |> require_ok Trust.error_to_string
  in
  let recovery = device (capability 'r') in
  let epoch =
    Trust.root_epoch ~membership
      ~root_certificate:(Trust.certificate_id certificate)
      ~recovery_device:recovery root_capability
    |> require_ok Trust.error_to_string
  in
  let authority =
    Trust.verify_authority ~membership [ epoch ]
    |> require_ok Trust.error_to_string
  in
  (repository, root_capability, publisher, certificate, authority)

let publication_round_trip () =
  let repository, capability, publisher, certificate, authority =
    authority ()
  in
  let manifest = Transport.sha256 "manifest" in
  let publication =
    Transport.create_publication ~repository ~publisher
      ~certificate:(Trust.certificate_id certificate)
      ~parents:[] ~manifest ~signing_capability:capability
    |> require_ok Transport.error_to_string
  in
  let encoded = Transport.encode_publication publication in
  Alcotest.(check string)
    "publication bytes retain their golden encoding"
    (read_golden "v1/transport-publication-v1.cbor.hex")
    encoded;
  let decoded =
    Transport.decode_publication encoded |> require_ok Transport.error_to_string
  in
  Alcotest.(check string)
    "publication identity is bytes-derived" (Transport.sha256 encoded)
    (Transport.publication_id decoded);
  Transport.verify_publication ~authority decoded
  |> require_ok Transport.error_to_string;
  Transport.validate_feed ~known:[] [ decoded ]
  |> require_ok Transport.error_to_string

let feed_rejects_missing_parent () =
  let repository, capability, publisher, certificate, _ = authority () in
  let parent = Transport.sha256 "missing parent" in
  let publication =
    Transport.create_publication ~repository ~publisher
      ~certificate:(Trust.certificate_id certificate)
      ~parents:[ parent ]
      ~manifest:(Transport.sha256 "manifest")
      ~signing_capability:capability
    |> require_ok Transport.error_to_string
  in
  match Transport.validate_feed ~known:[] [ publication ] with
  | Error error ->
      Alcotest.(check string)
        "missing parent ID"
        ("V1 transport publication is missing feed parent: " ^ parent)
        (Transport.error_to_string error)
  | Ok () -> Alcotest.fail "missing feed parent was accepted"

let feed_preserves_same_publisher_forks () =
  let repository, capability, publisher, certificate, _ = authority () in
  let publication manifest parents =
    Transport.create_publication ~repository ~publisher
      ~certificate:(Trust.certificate_id certificate)
      ~parents
      ~manifest:(Transport.sha256 manifest)
      ~signing_capability:capability
    |> require_ok Transport.error_to_string
  in
  let parent = publication "fork-parent" [] in
  let parent_id = Transport.publication_id parent in
  let left = publication "fork-left" [ parent_id ] in
  let right = publication "fork-right" [ parent_id ] in
  Transport.validate_feed ~known:[] [ parent; left; right ]
  |> require_ok Transport.error_to_string;
  let ids =
    [ parent; left; right ]
    |> List.map Transport.publication_id
    |> List.sort_uniq String.compare
  in
  Alcotest.(check int) "every fork publication is retained" 3 (List.length ids);
  Alcotest.(check (list string))
    "both children name the same explicit parent" [ parent_id ]
    (Transport.publication_parents left);
  Alcotest.(check (list string))
    "the other child remains a peer, not a head" [ parent_id ]
    (Transport.publication_parents right)

let local_state_round_trip () =
  let repository, capability, publisher, certificate, _ = authority () in
  let publication =
    Transport.create_publication ~repository ~publisher
      ~certificate:(Trust.certificate_id certificate)
      ~parents:[]
      ~manifest:(Transport.sha256 "manifest")
      ~signing_capability:capability
    |> require_ok Transport.error_to_string
  in
  let revision = Model.Revision_id.of_string "revision-one" |> Result.get_ok in
  let remote =
    Transport.remote_state ~name:"team" ~cursor:(Some "opaque-cursor")
      ~known:[ Transport.publication_reference publication ]
      ~announced_manifests:[ Transport.publication_manifest publication ]
      ~announced_revisions:[ revision ]
      ~review_inbox:[ Transport.publication_id publication ]
    |> require_ok Transport.error_to_string
  in
  let state =
    Transport.with_remote Transport.empty_local_state remote
    |> require_ok Transport.error_to_string
  in
  let encoded =
    Transport.encode_local_state state |> require_ok Transport.error_to_string
  in
  Alcotest.(check string)
    "local transport state retains its golden encoding"
    (read_golden "v1/transport-local-state-v1.cbor.hex")
    encoded;
  let decoded =
    Transport.decode_local_state encoded |> require_ok Transport.error_to_string
  in
  Alcotest.(check int)
    "one local remote" 1
    (List.length (Transport.remotes decoded));
  Alcotest.(check string)
    "canonical local transport state" encoded
    (Transport.encode_local_state decoded
    |> require_ok Transport.error_to_string)

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

let with_directory prefix run =
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let close_noerr descriptor =
  try Unix.close descriptor with Unix.Unix_error _ -> ()

let command_succeeds executable arguments =
  let null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  Fun.protect
    ~finally:(fun () -> close_noerr null)
    (fun () ->
      let process =
        Unix.create_process executable
          (Array.of_list (executable :: arguments))
          Unix.stdin null null
      in
      match Unix.waitpid [] process with
      | _, Unix.WEXITED 0 -> ()
      | _, Unix.WEXITED code -> Alcotest.failf "%s exited %d" executable code
      | _, Unix.WSIGNALED signal ->
          Alcotest.failf "%s was terminated by signal %d" executable signal
      | _, Unix.WSTOPPED signal ->
          Alcotest.failf "%s was stopped by signal %d" executable signal)

let required_tool environment fallback =
  match Sys.getenv_opt environment with
  | Some path when Sys.file_exists path -> path
  | Some path ->
      Alcotest.failf "%s names an unavailable executable: %s" environment path
  | None ->
      let path = Filename.concat "/usr/bin" fallback in
      if Sys.file_exists path then path
      else
        Alcotest.failf
          "%s is unavailable; set %s to its absolute executable path" fallback
          environment

let available_loopback_port () =
  let listener = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> close_noerr listener)
    (fun () ->
      Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname listener with
      | Unix.ADDR_INET (_, port) -> port
      | Unix.ADDR_UNIX _ -> Alcotest.fail "expected an IPv4 loopback port")

let terminate process =
  (try Unix.kill process Sys.sigterm with Unix.Unix_error _ -> ());
  try ignore (Unix.waitpid [] process) with Unix.Unix_error _ -> ()

let write_all descriptor bytes =
  let rec loop offset =
    if offset = String.length bytes then ()
    else
      let count =
        Unix.write_substring descriptor bytes offset
          (String.length bytes - offset)
      in
      if count = 0 then Alcotest.fail "socket write returned zero"
      else loop (offset + count)
  in
  loop 0

let read_all descriptor =
  let buffer = Buffer.create 256 in
  let scratch = Bytes.create 4096 in
  let rec loop () =
    match Unix.read descriptor scratch 0 (Bytes.length scratch) with
    | 0 -> Buffer.contents buffer
    | count ->
        Buffer.add_subbytes buffer scratch 0 count;
        loop ()
  in
  loop ()

let raw_http ~port request =
  let descriptor = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> close_noerr descriptor)
    (fun () ->
      Unix.connect descriptor (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
      write_all descriptor request;
      Unix.shutdown descriptor Unix.SHUTDOWN_SEND;
      read_all descriptor)

let response_status response =
  match String.split_on_char ' ' response with
  | _http :: status :: _ -> (
      match int_of_string_opt status with
      | Some status -> status
      | None -> Alcotest.fail "relay response did not contain a status")
  | _ -> Alcotest.fail "relay response did not contain a status line"

let has_substring output needle =
  let needle_length = String.length needle in
  let rec find index =
    if index + needle_length > String.length output then false
    else if String.equal (String.sub output index needle_length) needle then
      true
    else find (index + 1)
  in
  needle_length > 0 && find 0

let raw_request ?(token = "wrong-relay-access-secret") ?(body = "") method_ path
    =
  method_ ^ " " ^ path
  ^ " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer " ^ token
  ^ "\r\nContent-Length: "
  ^ string_of_int (String.length body)
  ^ "\r\n\r\n" ^ body

let with_http_relay run =
  with_directory "yeokcham-v1-http-relay-" (fun root ->
      let relay_root = Filename.concat root "relay" in
      let project = Trust.Repository_id.to_string (repository ()) in
      let now = Int64.of_float (Unix.gettimeofday ()) in
      let grant =
        Relay_access.update ~root:relay_root (fun registry ->
            Relay_access.issue ~now ~repository:project
              ~scopes:[ Relay_access.Read; Relay_access.Write ]
              ~expires_in:Relay_access.default_lifetime_seconds registry)
        |> require_ok Relay_access.error_to_string
      in
      let port = available_loopback_port () in
      let relay =
        match Unix.fork () with
        | 0 -> (
            match
              Relay_http.serve ~root:relay_root
                ~listen:("127.0.0.1:" ^ string_of_int port)
            with
            | Ok () -> exit 0
            | Error _ -> exit 1)
        | process -> process
      in
      Fun.protect
        ~finally:(fun () -> terminate relay)
        (fun () ->
          let rec ready attempts =
            try
              ignore
                (raw_http ~port
                   (raw_request ~token:"wrong" "GET" "/not-a-route"));
              ()
            with
            | Unix.Unix_error _ when attempts > 0 ->
                ignore (Unix.select [] [] [] 0.02);
                ready (attempts - 1)
            | Unix.Unix_error _ -> Alcotest.fail "HTTP relay did not start"
          in
          ready 100;
          run ~relay_root ~port ~token:grant.Relay_access.grant_secret))

let configured_relay_refuses_session_expiry_above_operator_limit () =
  with_directory "yeokcham-v1-configured-relay-" (fun root ->
      let relay_root = Filename.concat root "relay" in
      let registry_root = Filename.concat root "registry" in
      let project = Trust.Repository_id.to_string (repository ()) in
      let now = Int64.of_float (Unix.gettimeofday ()) in
      let grant =
        Relay_access.update ~root:registry_root (fun registry ->
            Relay_access.issue ~now ~repository:project
              ~scopes:[ Relay_access.Read; Relay_access.Write ]
              ~expires_in:Relay_access.default_lifetime_seconds registry)
        |> require_ok Relay_access.error_to_string
      in
      let port = available_loopback_port () in
      let rec distinct_port used =
        let candidate = available_loopback_port () in
        if List.mem candidate used then distinct_port used else candidate
      in
      let health_port = distinct_port [ port ] in
      let metrics_port = distinct_port [ port; health_port ] in
      let config =
        Relay_config.create ~storage_root:relay_root
          ~credential_registry_root:registry_root
          ~listen:("127.0.0.1:" ^ string_of_int port)
          ~health_listen:("127.0.0.1:" ^ string_of_int health_port)
          ~metrics_listen:("127.0.0.1:" ^ string_of_int metrics_port)
          ~project_quota_bytes:1 ~session_expiry_seconds:1
          ~log_level:Relay_config.Info
        |> require_ok Relay_config.error_to_string
      in
      let relay =
        match Unix.fork () with
        | 0 -> (
            match Relay_http.serve_with_config config with
            | Ok () -> exit 0
            | Error _ -> exit 1)
        | process -> process
      in
      Fun.protect
        ~finally:(fun () -> terminate relay)
        (fun () ->
          let rec ready attempts =
            try
              ignore
                (raw_http ~port
                   (raw_request ~token:"wrong" "GET" "/not-a-route"))
            with
            | Unix.Unix_error _ when attempts > 0 ->
                ignore (Unix.select [] [] [] 0.02);
                ready (attempts - 1)
            | Unix.Unix_error _ ->
                Alcotest.fail "configured HTTP relay did not start"
          in
          ready 100;
          Alcotest.(check int)
            "configured health listener is live" 200
            (response_status
               (raw_http ~port:health_port (raw_request "GET" "/healthz")));
          Alcotest.(check int)
            "configured health listener is ready" 200
            (response_status
               (raw_http ~port:health_port (raw_request "GET" "/readyz")));
          Alcotest.(check bool)
            "readiness leaves no probe in relay storage" false
            (Sys.readdir relay_root
            |> Array.exists
                 (String.starts_with ~prefix:".yeokcham-relay-readiness-"));
          let body ~raw_size ~expiry =
            Encoding.array
              [
                Encoding.text (Transport.sha256 "config-limited-object")
                |> Result.get_ok;
                Encoding.integer raw_size;
                Encoding.integer expiry;
              ]
            |> Result.get_ok |> Encoding.encode
          in
          Alcotest.(check int)
            "operator session-expiry limit rejects a larger client request" 400
            (response_status
               (raw_http ~port
                  (raw_request ~token:grant.Relay_access.grant_secret
                     ~body:(body ~raw_size:1L ~expiry:2L)
                     "POST"
                     ("/v2/repositories/" ^ project ^ "/uploads"))));
          Alcotest.(check int)
            "operator temporary-byte quota rejects a larger object" 400
            (response_status
               (raw_http ~port
                  (raw_request ~token:grant.Relay_access.grant_secret
                     ~body:(body ~raw_size:2L ~expiry:1L)
                     "POST"
                     ("/v2/repositories/" ^ project ^ "/uploads"))));
          let metrics =
            raw_http ~port:metrics_port (raw_request "GET" "/metrics")
          in
          Alcotest.(check int)
            "metrics listener responds" 200 (response_status metrics);
          Alcotest.(check bool)
            "metrics report quota refusals" true
            (has_substring metrics "yeokcham_relay_quota_refusals_total 1");
          Alcotest.(check bool)
            "metrics redact bearer secret" false
            (has_substring metrics grant.Relay_access.grant_secret);
          let moved_registry = Filename.concat root "registry-offline" in
          Unix.rename registry_root moved_registry;
          let descriptor =
            Unix.openfile registry_root [ Unix.O_WRONLY; Unix.O_CREAT ] 0o600
          in
          Unix.close descriptor;
          Alcotest.(check int)
            "liveness survives readiness failure" 200
            (response_status
               (raw_http ~port:health_port (raw_request "GET" "/healthz")));
          Alcotest.(check int)
            "readiness exposes failed credential registry" 503
            (response_status
               (raw_http ~port:health_port (raw_request "GET" "/readyz")))))

let configured_relay_refuses_nonwritable_storage () =
  with_directory "yeokcham-v1-readonly-relay-" (fun root ->
      let relay_root = Filename.concat root "relay" in
      let registry_root = Filename.concat root "registry" in
      Unix.mkdir relay_root 0o500;
      let project = Trust.Repository_id.to_string (repository ()) in
      let now = Int64.of_float (Unix.gettimeofday ()) in
      Relay_access.update ~root:registry_root (fun registry ->
          Relay_access.issue ~now ~repository:project
            ~scopes:[ Relay_access.Read ]
            ~expires_in:Relay_access.default_lifetime_seconds registry
          |> Result.map (fun grant -> (registry, grant)))
      |> require_ok Relay_access.error_to_string
      |> ignore;
      let config =
        Relay_config.create ~storage_root:relay_root
          ~credential_registry_root:registry_root ~listen:"127.0.0.1:41080"
          ~health_listen:"127.0.0.1:41081" ~metrics_listen:"127.0.0.1:41082"
          ~project_quota_bytes:1 ~session_expiry_seconds:1
          ~log_level:Relay_config.Info
        |> require_ok Relay_config.error_to_string
      in
      match Relay_http.serve_with_config config with
      | Error error ->
          Alcotest.(check string)
            "nonwritable relay storage is refused before serving"
            "V1 relay operator storage or credential registry is not ready"
            (Relay_http.error_to_string error)
      | Ok () -> Alcotest.fail "nonwritable relay storage started serving")

let http_listener_rejects_untrusted_requests_and_preserves_immutability () =
  with_http_relay (fun ~relay_root ~port ~token ->
      let project = Trust.Repository_id.to_string (repository ()) in
      let path kind id =
        "/v1/repositories/" ^ project ^ "/" ^ kind ^ "/" ^ id
      in
      let unauthorized =
        raw_http ~port
          (raw_request ~token:"wrong" "GET"
             (path "manifests" (Transport.sha256 "untrusted")))
      in
      Alcotest.(check int)
        "wrong bearer token is rejected" 401
        (response_status unauthorized);
      let oversized =
        "PUT "
        ^ path "manifests" (Transport.sha256 "oversized")
        ^ " HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer " ^ token
        ^ "\r\nContent-Length: "
        ^ string_of_int (Relay.max_body_bytes + 1)
        ^ "\r\n\r\n"
      in
      Alcotest.(check int)
        "oversized body is rejected" 413
        (response_status (raw_http ~port oversized));
      Alcotest.(check int)
        "malformed digest route is rejected" 400
        (response_status
           (raw_http ~port
              (raw_request ~token "GET" (path "manifests" "not-a-digest"))));
      Alcotest.(check int)
        "invalid page limit is rejected" 400
        (response_status
           (raw_http ~port
              (raw_request ~token "GET"
                 ("/v1/repositories/" ^ project ^ "/publications?limit=0"))));
      let bytes = "listener manifest" in
      let id = Transport.sha256 bytes in
      let put = raw_request ~token ~body:bytes "PUT" (path "manifests" id) in
      Alcotest.(check int)
        "first immutable create succeeds" 201
        (response_status (raw_http ~port put));
      Alcotest.(check int)
        "identical immutable create is idempotent" 201
        (response_status (raw_http ~port put));
      Alcotest.(check int)
        "a different body cannot overwrite" 400
        (response_status
           (raw_http ~port
              (raw_request ~token ~body:"different" "PUT" (path "manifests" id))));
      let fetched =
        raw_http ~port (raw_request ~token "GET" (path "manifests" id))
      in
      Alcotest.(check int)
        "stored immutable bytes remain readable" 200 (response_status fetched);
      Alcotest.(check bool)
        "stored bytes were not overwritten" true
        (String.ends_with ~suffix:bytes fetched);
      let relay =
        Relay.open_repository ~root:relay_root
        |> require_ok Relay.error_to_string
      in
      let pages, _ =
        Relay.list_publications relay ~project ~cursor:None
          ~limit:Relay.max_page_size
        |> require_ok Relay.error_to_string
      in
      Alcotest.(check int)
        "rejected requests created no publications" 0 (List.length pages))

let rec wait_for_https_relay client project attempts =
  match
    Transport_http.list_publications client ~project ~cursor:None ~limit:1
  with
  | Ok _ -> ()
  | Error _ when attempts > 0 ->
      ignore (Unix.select [] [] [] 0.05);
      wait_for_https_relay client project (attempts - 1)
  | Error error ->
      Alcotest.fail
        ("HTTPS reverse proxy never became ready: "
        ^ Transport_http.error_to_string error)

let with_https_relay run =
  let openssl = required_tool "YEOKCHAM_V1_TEST_OPENSSL" "openssl" in
  let socat = required_tool "YEOKCHAM_V1_TEST_SOCAT" "socat" in
  with_directory "yeokcham-v1-https-relay-" (fun root ->
      let certificate = Filename.concat root "relay.crt" in
      let private_key = Filename.concat root "relay.key" in
      command_succeeds openssl
        [
          "req";
          "-x509";
          "-newkey";
          "rsa:2048";
          "-nodes";
          "-keyout";
          private_key;
          "-out";
          certificate;
          "-days";
          "1";
          "-subj";
          "/CN=127.0.0.1";
          "-addext";
          "subjectAltName=IP:127.0.0.1";
        ];
      let relay_root = Filename.concat root "relay" in
      let project = Trust.Repository_id.to_string (repository ()) in
      let now = Int64.of_float (Unix.gettimeofday ()) in
      let grant =
        Relay_access.update ~root:relay_root (fun registry ->
            Relay_access.issue ~now ~repository:project
              ~scopes:[ Relay_access.Read; Relay_access.Write ]
              ~expires_in:Relay_access.default_lifetime_seconds registry)
        |> require_ok Relay_access.error_to_string
      in
      let backend_port = available_loopback_port () in
      let proxy_port = available_loopback_port () in
      let backend =
        match Unix.fork () with
        | 0 -> (
            match
              Relay_http.serve ~root:relay_root
                ~listen:("127.0.0.1:" ^ string_of_int backend_port)
            with
            | Ok () -> exit 0
            | Error _ -> exit 1)
        | process -> process
      in
      let proxy =
        Unix.create_process socat
          [|
            socat;
            "OPENSSL-LISTEN:" ^ string_of_int proxy_port ^ ",cert="
            ^ certificate ^ ",key=" ^ private_key ^ ",verify=0,reuseaddr,fork";
            "TCP:127.0.0.1:" ^ string_of_int backend_port;
          |]
          Unix.stdin Unix.stdout Unix.stderr
      in
      let saved_environment =
        [
          "YEOKCHAM_V1_TEST_TRANSPORT";
          "YEOKCHAM_V1_TEST_TRANSPORT_CA_BUNDLE";
          "YEOKCHAM_V1_TEST_TRANSPORT_TOKEN";
          "YEOKCHAM_V1_TEST_TRANSPORT_FAIL_PUT";
        ]
        |> List.map (fun name -> (name, Sys.getenv_opt name))
      in
      Fun.protect
        ~finally:(fun () ->
          terminate proxy;
          terminate backend;
          List.iter
            (fun (name, value) ->
              Unix.putenv name (Option.value ~default:"" value))
            saved_environment)
        (fun () ->
          Unix.putenv "YEOKCHAM_V1_TEST_TRANSPORT" "1";
          Unix.putenv "YEOKCHAM_V1_TEST_TRANSPORT_CA_BUNDLE" certificate;
          Unix.putenv "YEOKCHAM_V1_TEST_TRANSPORT_TOKEN"
            grant.Relay_access.grant_secret;
          let client =
            Transport_http.create
              ~url:("https://127.0.0.1:" ^ string_of_int proxy_port)
              ~token:grant.Relay_access.grant_secret
            |> require_ok Transport_http.error_to_string
          in
          wait_for_https_relay client project 100;
          run client project ("https://127.0.0.1:" ^ string_of_int proxy_port)))

let header_is_complete bytes =
  let rec loop index =
    if index + 3 >= String.length bytes then false
    else if String.sub bytes index 4 = "\r\n\r\n" then true
    else loop (index + 1)
  in
  loop 0

let read_http_headers descriptor =
  let buffer = Buffer.create 1024 in
  let scratch = Bytes.create 1024 in
  let rec loop () =
    if Buffer.length buffer > 16 * 1024 then None
    else
      match Unix.read descriptor scratch 0 (Bytes.length scratch) with
      | 0 -> None
      | count ->
          Buffer.add_subbytes buffer scratch 0 count;
          let bytes = Buffer.contents buffer in
          if header_is_complete bytes then Some bytes else loop ()
  in
  loop ()

let request_target request =
  match String.split_on_char '\n' request with
  | line :: _ -> (
      match String.trim line |> String.split_on_char ' ' with
      | _method :: target :: _ -> target
      | _ -> "")
  | [] -> ""

let write_http_response descriptor status body =
  let reason = if status = 200 then "OK" else "Not Found" in
  write_all descriptor
    (Printf.sprintf
       "HTTP/1.1 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
       status reason (String.length body));
  write_all descriptor body

let append_request path target =
  let descriptor =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o600
  in
  Fun.protect
    ~finally:(fun () -> close_noerr descriptor)
    (fun () -> write_all descriptor (target ^ "\n"))

let serve_malicious_backend ~port ~requests respond =
  let listener = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> close_noerr listener)
    (fun () ->
      Unix.setsockopt listener Unix.SO_REUSEADDR true;
      Unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
      Unix.listen listener 16;
      let rec loop remaining =
        if remaining = 0 then ()
        else
          let descriptor, _ = Unix.accept listener in
          Fun.protect
            ~finally:(fun () -> close_noerr descriptor)
            (fun () ->
              match read_http_headers descriptor with
              | None -> ()
              | Some request ->
                  let target = request_target request in
                  append_request requests target;
                  let status, body = respond target in
                  write_http_response descriptor status body);
          loop (remaining - 1)
      in
      loop max_int)

let with_malicious_https_server ~respond run =
  let openssl = required_tool "YEOKCHAM_V1_TEST_OPENSSL" "openssl" in
  let socat = required_tool "YEOKCHAM_V1_TEST_SOCAT" "socat" in
  with_directory "yeokcham-v1-malicious-https-" (fun root ->
      let certificate = Filename.concat root "relay.crt" in
      let private_key = Filename.concat root "relay.key" in
      command_succeeds openssl
        [
          "req";
          "-x509";
          "-newkey";
          "rsa:2048";
          "-nodes";
          "-keyout";
          private_key;
          "-out";
          certificate;
          "-days";
          "1";
          "-subj";
          "/CN=127.0.0.1";
          "-addext";
          "subjectAltName=IP:127.0.0.1";
        ];
      let backend_port = available_loopback_port () in
      let proxy_port = available_loopback_port () in
      let requests = Filename.concat root "requests" in
      let backend =
        match Unix.fork () with
        | 0 ->
            serve_malicious_backend ~port:backend_port ~requests respond;
            exit 0
        | process -> process
      in
      let proxy =
        Unix.create_process socat
          [|
            socat;
            "OPENSSL-LISTEN:" ^ string_of_int proxy_port ^ ",cert="
            ^ certificate ^ ",key=" ^ private_key ^ ",verify=0,reuseaddr,fork";
            "TCP:127.0.0.1:" ^ string_of_int backend_port;
          |]
          Unix.stdin Unix.stdout Unix.stderr
      in
      let saved_environment =
        [
          "YEOKCHAM_V1_TEST_TRANSPORT";
          "YEOKCHAM_V1_TEST_TRANSPORT_CA_BUNDLE";
          "YEOKCHAM_V1_TEST_TRANSPORT_TOKEN";
          "YEOKCHAM_V1_TEST_TRANSPORT_FAIL_PUT";
        ]
        |> List.map (fun name -> (name, Sys.getenv_opt name))
      in
      Fun.protect
        ~finally:(fun () ->
          terminate proxy;
          terminate backend;
          List.iter
            (fun (name, value) ->
              Unix.putenv name (Option.value ~default:"" value))
            saved_environment)
        (fun () ->
          Unix.putenv "YEOKCHAM_V1_TEST_TRANSPORT" "1";
          Unix.putenv "YEOKCHAM_V1_TEST_TRANSPORT_CA_BUNDLE" certificate;
          Unix.putenv "YEOKCHAM_V1_TEST_TRANSPORT_TOKEN" "test-relay-token";
          let client =
            Transport_http.create
              ~url:("https://127.0.0.1:" ^ string_of_int proxy_port)
              ~token:"test-relay-token"
            |> require_ok Transport_http.error_to_string
          in
          let project = Trust.Repository_id.to_string (repository ()) in
          wait_for_https_relay client project 100;
          run ~requests ("https://127.0.0.1:" ^ string_of_int proxy_port)))

let https_client_reaches_relay_through_tls_reverse_proxy () =
  with_https_relay (fun client project _url ->
      let manifest_bytes = "TLS reverse proxy manifest" in
      let manifest_id = Transport.sha256 manifest_bytes in
      Transport_http.put client ~project ~kind:Transport_http.Manifest
        ~id:manifest_id ~bytes:manifest_bytes
      |> require_ok Transport_http.error_to_string;
      let retrieved =
        Transport_http.get client ~project ~kind:Transport_http.Manifest
          ~id:manifest_id
        |> require_ok Transport_http.error_to_string
      in
      Alcotest.(check string)
        "the TLS proxy preserves relay manifest bytes" manifest_bytes retrieved;
      let publication = "TLS reverse proxy publication" in
      let publication_id = Transport.sha256 publication in
      Transport_http.put client ~project ~kind:Transport_http.Publication
        ~id:publication_id ~bytes:publication
      |> require_ok Transport_http.error_to_string;
      let publications, cursor =
        Transport_http.list_publications client ~project ~cursor:None ~limit:1
        |> require_ok Transport_http.error_to_string
      in
      Alcotest.(check (list string))
        "publication discovery crosses the TLS proxy" [ publication_id ]
        publications;
      Alcotest.(check (option string))
        "one publication has no next page" None cursor)

let v2_capability missing =
  Transport.V2.capability
    ~versions:[ Transport.V2.protocol_version ]
    ~zstd:true ~max_segment_bytes:Transport.V2.segment_bytes ~max_in_flight:4
    ~missing
  |> require_ok Transport.V2.error_to_string

let large_v2_object ?(fill = 'x') () =
  let payload =
    Encoding.bytes (String.make (Transport.V2.segment_bytes + 41) fill)
  in
  let envelope =
    Envelope.create ~object_type:Envelope.Content
      ~object_format_version:Envelope.current_object_format_version
      ~mandatory_features:Envelope.supported_mandatory_features ~payload ()
    |> Result.get_ok
  in
  let bytes = Envelope.encode envelope in
  let id =
    Object_store.id_of_envelope envelope |> Object_store.Stored_object_id.to_hex
  in
  (bytes, id)

let https_v2_upload_resume_download_and_v1_fallback () =
  with_directory "yeokcham-v1-v2-source-boundary-" (fun source_root ->
      let source_file = Filename.concat source_root "ordinary-source.txt" in
      Out_channel.with_open_bin source_file (fun channel ->
          Out_channel.output_string channel
            "ordinary source is not relay data\n");
      with_https_relay (fun client project url ->
          let bytes, object_id = large_v2_object () in
          let receiver =
            Transport_http_v2.negotiate_upload client ~project
              ~sender:(v2_capability []) ~offered:[ object_id ]
            |> require_ok Transport_http_v2.error_to_string
          in
          let negotiated =
            Transport.V2.intersect_capability ~sender:(v2_capability [])
              ~receiver
            |> require_ok Transport.V2.error_to_string
          in
          Alcotest.(check (list string))
            "relay reports exactly the offered missing object" [ object_id ]
            (Transport.V2.missing_ids (Transport.V2.missing_objects negotiated));
          let session =
            Transport_http_v2.start_upload client ~project ~object_id
              ~raw_size:(String.length bytes) ~expires_in:60
            |> require_ok Transport_http_v2.error_to_string
          in
          let ranges =
            Transport.V2.partition (Transport.V2.session_offer session)
            |> require_ok Transport.V2.error_to_string
          in
          let first = List.hd ranges in
          let first_bytes =
            String.sub bytes
              (Transport.V2.range_offset first)
              (Transport.V2.range_length first)
          in
          let session_id = Transport.V2.session_id session in
          Transport_http_v2.put_segment client ~project ~session_id
            ~offset:(Transport.V2.range_offset first)
            ~raw:first_bytes
          |> require_ok Transport_http_v2.error_to_string;
          Alcotest.(check bool)
            "incomplete V2 session cannot publish" true
            (Result.is_error
               (Transport_http_v2.complete_upload client ~project ~session_id));
          let restarted =
            Transport_http.create ~url ~token:(relay_test_token ())
            |> require_ok Transport_http.error_to_string
          in
          let resumed =
            Transport_http_v2.resume_upload restarted ~project ~session_id
            |> require_ok Transport_http_v2.error_to_string
          in
          Alcotest.(check int)
            "restart sees accepted first segment" 1
            (List.length
               (Transport.V2.progress_ranges
                  (Transport.V2.session_progress resumed)));
          List.tl ranges
          |> List.iter (fun range ->
              let raw =
                String.sub bytes
                  (Transport.V2.range_offset range)
                  (Transport.V2.range_length range)
              in
              Transport_http_v2.put_segment restarted ~project ~session_id
                ~offset:(Transport.V2.range_offset range)
                ~raw
              |> require_ok Transport_http_v2.error_to_string);
          Transport_http_v2.complete_upload restarted ~project ~session_id
          |> require_ok Transport_http_v2.error_to_string;
          let downloaded =
            Transport_http_v2.download_object restarted ~project ~object_id
              ~raw_size:(String.length bytes)
            |> require_ok Transport_http_v2.error_to_string
          in
          Alcotest.(check string)
            "download reassembles exact canonical bytes before import" bytes
            downloaded;
          let automatic_bytes, automatic_id = large_v2_object ~fill:'y' () in
          Transport_http.put restarted ~project ~kind:Transport_http.Object
            ~id:automatic_id ~bytes:automatic_bytes
          |> require_ok Transport_http.error_to_string;
          let automatic_download =
            Transport_http_v2.download_object restarted ~project
              ~object_id:automatic_id
              ~raw_size:(String.length automatic_bytes)
            |> require_ok Transport_http_v2.error_to_string
          in
          Alcotest.(check string)
            "the default V2 upload transfers and publishes every range"
            automatic_bytes automatic_download;
          let manifest = "V1 remains explicitly available" in
          Transport_http.put restarted ~project ~kind:Transport_http.Manifest
            ~id:(Transport.sha256 manifest)
            ~bytes:manifest
          |> require_ok Transport_http.error_to_string);
      Alcotest.(check string)
        "V2 transfer never writes an ordinary source path"
        "ordinary source is not relay data\n"
        (In_channel.with_open_bin source_file In_channel.input_all))

let explicit_v1_fallback_when_v2_is_unavailable () =
  let empty_publication_page =
    Encoding.array [ Encoding.array [] |> Result.get_ok; Encoding.null ]
    |> Result.get_ok |> Encoding.encode
  in
  with_malicious_https_server
    ~respond:(fun target ->
      if String.starts_with ~prefix:"/v1/repositories/" target then
        if String.contains target '?' then (200, empty_publication_page)
        else (201, "")
      else (404, ""))
    (fun ~requests:_ url ->
      let client =
        Transport_http.create ~url ~token:"test-relay-token"
        |> require_ok Transport_http.error_to_string
      in
      let project = Trust.Repository_id.to_string (repository ()) in
      Alcotest.(check bool)
        "V2 absence is explicit, never implicit success" true
        (Result.is_error
           (Transport_http_v2.negotiate_upload client ~project
              ~sender:(v2_capability [])
              ~offered:[ Transport.sha256 "object" ]));
      let object_bytes, object_id = large_v2_object () in
      Transport_http.put client ~project ~kind:Transport_http.Object
        ~id:object_id ~bytes:object_bytes
      |> require_ok Transport_http.error_to_string;
      let manifest = "V1 fallback bytes" in
      Transport_http.put client ~project ~kind:Transport_http.Manifest
        ~id:(Transport.sha256 manifest)
        ~bytes:manifest
      |> require_ok Transport_http.error_to_string)

let v2_retries_only_transient_server_failures () =
  let empty_publication_page =
    Encoding.array [ Encoding.array [] |> Result.get_ok; Encoding.null ]
    |> Result.get_ok |> Encoding.encode
  in
  let raw = String.make 4096 'r' in
  let compressed =
    Transport.V2_wire.compress raw
    |> require_ok Transport.V2_wire.error_to_string
  in
  let project = Trust.Repository_id.to_string (repository ()) in
  let retry_id = Transport.sha256 raw in
  let authentication_id = Transport.sha256 "authentication is terminal" in
  let retry_path = "/v2/repositories/" ^ project ^ "/objects/" ^ retry_id in
  let authentication_path =
    "/v2/repositories/" ^ project ^ "/objects/" ^ authentication_id
  in
  let retry_attempts = ref 0 in
  with_malicious_https_server
    ~respond:(fun target ->
      if String.starts_with ~prefix:"/v1/repositories/" target then
        if String.contains target '?' then (200, empty_publication_page)
        else (201, "")
      else if String.starts_with ~prefix:retry_path target then (
        incr retry_attempts;
        if !retry_attempts = 1 then (503, "temporary") else (200, compressed))
      else if String.starts_with ~prefix:authentication_path target then
        (401, "denied")
      else (404, ""))
    (fun ~requests url ->
      let client =
        Transport_http.create ~url ~token:"test-relay-token"
        |> require_ok Transport_http.error_to_string
      in
      Transport_http_v2.get_segment client ~project ~object_id:retry_id
        ~offset:0 ~length:(String.length raw)
      |> require_ok Transport_http_v2.error_to_string
      |> Alcotest.(check string) "a transient V2 response is retried" raw;
      Alcotest.(check bool)
        "authentication failure is not retried" true
        (Result.is_error
           (Transport_http_v2.get_segment client ~project
              ~object_id:authentication_id ~offset:0 ~length:(String.length raw)));
      let request_count prefix =
        In_channel.with_open_bin requests In_channel.input_lines
        |> List.filter (String.starts_with ~prefix)
        |> List.length
      in
      Alcotest.(check int)
        "one 5xx causes one bounded retry" 2 (request_count retry_path);
      Alcotest.(check int)
        "authentication is attempted once" 1
        (request_count authentication_path))

let response_body response =
  let rec find offset =
    if offset + 3 >= String.length response then None
    else if String.sub response offset 4 = "\r\n\r\n" then Some (offset + 4)
    else find (offset + 1)
  in
  match find 0 with
  | Some offset -> String.sub response offset (String.length response - offset)
  | None -> Alcotest.fail "HTTP response has no body boundary"

let v2_http_credential_revocation_refuses_resumed_segment () =
  with_http_relay (fun ~relay_root ~port ~token ->
      let project = Trust.Repository_id.to_string (repository ()) in
      let bytes, object_id = large_v2_object () in
      let start =
        Encoding.array
          [
            Encoding.text object_id |> Result.get_ok;
            Encoding.integer (Int64.of_int (String.length bytes));
            Encoding.integer 60L;
          ]
        |> Result.get_ok |> Encoding.encode
      in
      let response =
        raw_http ~port
          (raw_request ~token ~body:start "POST"
             ("/v2/repositories/" ^ project ^ "/uploads"))
      in
      Alcotest.(check int)
        "V2 session starts before revocation" 201 (response_status response);
      let session =
        Transport.V2.decode_session (response_body response)
        |> require_ok Transport.V2.error_to_string
      in
      let credential_id =
        Relay_access.load ~root:relay_root
        |> require_ok Relay_access.error_to_string
        |> Relay_access.credentials |> List.hd |> Relay_access.credential_id
      in
      Relay_access.update ~root:relay_root (fun registry ->
          Relay_access.revoke
            ~now:(Int64.of_float (Unix.gettimeofday ()))
            ~credential_id registry
          |> Result.map (fun registry -> (registry, ())))
      |> require_ok Relay_access.error_to_string;
      let range =
        Transport.V2.partition (Transport.V2.session_offer session)
        |> require_ok Transport.V2.error_to_string
        |> List.hd
      in
      let raw =
        String.sub bytes
          (Transport.V2.range_offset range)
          (Transport.V2.range_length range)
      in
      let compressed = Transport.V2_wire.compress raw |> Result.get_ok in
      let route =
        Printf.sprintf "/v2/repositories/%s/uploads/%s/segments/%d/%d/%s"
          project
          (Transport.V2.session_id session)
          (Transport.V2.range_offset range)
          (Transport.V2.range_length range)
          (Transport.sha256 raw)
      in
      Alcotest.(check int)
        "revoked credential cannot add a V2 segment" 401
        (response_status
           (raw_http ~port (raw_request ~token ~body:compressed "PUT" route)));
      Alcotest.(check bool)
        "revoked V2 session never publishes source bytes" true
        (Result.is_error
           (Relay.get
              (Relay.open_repository ~root:relay_root
              |> require_ok Relay.error_to_string)
              ~project ~kind:Relay.Object ~id:object_id)))

let executable () =
  let from_test_binary =
    Sys.executable_name |> Filename.dirname |> Filename.dirname
    |> fun build_root -> Filename.concat build_root "bin/yeokcham_v1.exe"
  in
  let candidates = [ from_test_binary; "_build/default/bin/yeokcham_v1.exe" ] in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.fail "cannot locate the yeokcham-v1 executable"

let run_cli arguments =
  let command =
    executable () :: arguments |> List.map Filename.quote |> String.concat " "
  in
  let stdout, stdin, stderr =
    Unix.open_process_full command (Unix.environment ())
  in
  close_out_noerr stdin;
  let output = In_channel.input_all stdout in
  let errors = In_channel.input_all stderr in
  let status = Unix.close_process_full (stdout, stdin, stderr) in
  (output, errors, status)

let require_cli_success name stderr = function
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code -> Alcotest.failf "%s exited %d: %s" name code stderr
  | Unix.WSIGNALED signal ->
      Alcotest.failf "%s was terminated by signal %d: %s" name signal stderr
  | Unix.WSTOPPED signal ->
      Alcotest.failf "%s was stopped by signal %d: %s" name signal stderr

let require_cli_failure name = function
  | Unix.WEXITED 0 -> Alcotest.fail (name ^ " unexpectedly succeeded")
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> ()

let contains output needle =
  let needle_length = String.length needle in
  let rec find index =
    if index + needle_length > String.length output then false
    else if String.equal (String.sub output index needle_length) needle then
      true
    else find (index + 1)
  in
  needle_length > 0 && find 0

let expect_output_contains name needle output =
  Alcotest.(check bool) name true (contains output needle)

let with_test_signer run =
  let directory = Filename.temp_file "yeokcham-v1-test-signer-" "" in
  Unix.unlink directory;
  Unix.mkdir directory 0o700;
  Unix.putenv "YEOKCHAM_V1_TEST_SIGNER_DIRECTORY" directory;
  Fun.protect
    ~finally:(fun () -> remove_tree directory)
    (fun () -> run directory)

let store_test_signer directory capability =
  let device =
    Trust.signing_public_key capability
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  let path =
    Filename.concat directory
      (Model.Device_id.to_string (Trust.device_id device))
  in
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel
        (Trust.signing_private_key_bytes capability
        |> require_ok Trust.error_to_string))

let source_and_destination parent =
  let source = Filename.concat parent "source" in
  let destination = Filename.concat parent "destination" in
  Unix.mkdir source 0o700;
  Unix.mkdir destination 0o700;
  Out_channel.with_open_bin (Filename.concat source "main.ml") (fun channel ->
      Out_channel.output_string channel "let version = 1\n");
  Out_channel.with_open_bin (Filename.concat destination "main.ml")
    (fun channel -> Out_channel.output_string channel "let version = 1\n");
  let administrator_capability = capability 'a' in
  let administrator =
    Trust.signing_public_key administrator_capability
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  let recovery_capability = capability 'r' in
  let recovery_device =
    Trust.signing_public_key recovery_capability
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  Service.init_signed_with_recovery ~root:source
    ~username:(Model.Username.of_string "alice" |> Result.get_ok)
    ~initial_draft:(Model.Draft_id.of_string "draft-source" |> Result.get_ok)
    ~title:"source" ~repository:(repository ()) ~device:administrator
    ~signing_capability:administrator_capability ~recovery_device
    ~recovery_capability
  |> require_ok Service.error_to_string
  |> ignore;
  let member_capability = capability 'b' in
  let member =
    Trust.signing_public_key member_capability
    |> Trust.device_of_public_key
    |> require_ok Trust.error_to_string
  in
  Service.enroll_device ~parent:None ~root:source ~subject:member
    ~role:Trust.Member
    ~username:(Model.Username.of_string "bob" |> Result.get_ok)
    ~signing_capability:administrator_capability
  |> require_ok Service.error_to_string
  |> ignore;
  let source_repository =
    Store.open_repository ~root:source |> require_ok Store.error_to_string
  in
  let source_loaded =
    Store.load source_repository |> require_ok Store.error_to_string
  in
  let authority =
    match source_loaded.Store.collaboration with
    | Some collaboration -> (
        match Store.authority collaboration with
        | Some authority -> authority
        | None -> Alcotest.fail "transport source has no authority")
    | None -> Alcotest.fail "transport source lost collaboration"
  in
  let member_certificate =
    Trust.certificates (Trust.authority_membership authority)
    |> List.find (fun certificate ->
        Trust.device_equal (Trust.certificate_subject certificate) member)
    |> Trust.certificate_id
  in
  Service.init_authority_collaboration ~root:destination
    ~username:(Model.Username.of_string "bob" |> Result.get_ok)
    ~initial_draft:
      (Model.Draft_id.of_string "draft-destination" |> Result.get_ok)
    ~title:"destination" ~device:member ~authority
    ~local_certificate:member_certificate
  |> require_ok Service.error_to_string
  |> ignore;
  (source, destination, administrator_capability, member_capability)

let artifact_objects artifact =
  let objects = ref [] in
  Package.iter_artifact_objects artifact ~f:(fun id bytes ->
      objects := (id, bytes) :: !objects;
      Ok ())
  |> require_ok Package.error_to_string;
  List.rev !objects

let upload_artifact client ~project artifact publication =
  artifact_objects artifact
  |> List.iter (fun (id, bytes) ->
      Transport_http.put client ~project ~kind:Transport_http.Object
        ~id:(Object_store.Stored_object_id.to_hex id)
        ~bytes
      |> require_ok Transport_http.error_to_string);
  let manifest = Package.artifact_manifest artifact in
  Transport_http.put client ~project ~kind:Transport_http.Manifest
    ~id:(Transport.sha256 manifest)
    ~bytes:manifest
  |> require_ok Transport_http.error_to_string;
  let bytes = Transport.encode_publication publication in
  Transport_http.put client ~project ~kind:Transport_http.Publication
    ~id:(Transport.publication_id publication)
    ~bytes
  |> require_ok Transport_http.error_to_string

let interrupted_upload_leaves_received_work_durable () =
  with_https_relay (fun client project url ->
      with_directory "yeokcham-v1-interrupted-sync-" (fun parent ->
          with_test_signer (fun signer_directory ->
              let ( source,
                    destination,
                    administrator_capability,
                    member_capability ) =
                source_and_destination parent
              in
              Out_channel.with_open_bin (Filename.concat source "main.ml")
                (fun channel ->
                  Out_channel.output_string channel "let version = 2\n");
              Service.share_signed ~authority_epoch:None ~root:source
                ~change:
                  (Model.Change_id.of_string "change-transport" |> Result.get_ok)
                ~revision:
                  (Model.Revision_id.of_string "revision-transport"
                  |> Result.get_ok)
                ~signing_capability:administrator_capability
              |> require_ok Service.error_to_string
              |> ignore;
              let outbound =
                Service.prepare_transport_outbound ~root:source ~remote:"team"
                  ~signing_capability:administrator_capability
                |> require_ok Service.error_to_string
              in
              let outbound =
                match outbound with
                | Some outbound -> outbound
                | None ->
                    Alcotest.fail "source has no outbound transport package"
              in
              upload_artifact client ~project outbound.Service.outbound_artifact
                outbound.Service.outbound_publication;
              Transport_config.add ~root:destination ~name:"team" ~url
              |> require_ok Transport_config.error_to_string;
              store_test_signer signer_directory member_capability;
              Unix.putenv "YEOKCHAM_V1_TEST_TRANSPORT_TOKEN"
                (relay_test_token ());
              Unix.putenv "YEOKCHAM_V1_TEST_TRANSPORT_FAIL_PUT" "1";
              let output, errors, status =
                run_cli [ "sync"; "--root"; destination; "team" ]
              in
              require_cli_success "interrupted sync" errors status;
              expect_output_contains "sync reports durable receipt"
                "received publications 1" output;
              expect_output_contains "sync reports the interrupted upload"
                "upload pending test-only V1 transport upload interruption"
                output;
              let received =
                Service.status ~root:destination
                |> require_ok Service.error_to_string
              in
              Alcotest.(check int)
                "received revision persists after upload failure" 1
                received.Service.shared_change_count;
              let retry =
                Service.prepare_transport_outbound ~root:destination
                  ~remote:"team" ~signing_capability:member_capability
                |> require_ok Service.error_to_string
              in
              Alcotest.(check bool)
                "failed upload is not marked announced" true
                (Option.is_some retry);
              Unix.putenv "YEOKCHAM_V1_TEST_TRANSPORT_FAIL_PUT" "";
              let output, errors, status =
                run_cli [ "sync"; "--root"; destination; "team" ]
              in
              require_cli_success "retry sync" errors status;
              expect_output_contains "retry uploads the retained work"
                "uploaded artifacts " output;
              let after_retry =
                Service.prepare_transport_outbound ~root:destination
                  ~remote:"team" ~signing_capability:member_capability
                |> require_ok Service.error_to_string
              in
              Alcotest.(check bool)
                "acknowledged retry is marked announced" false
                (Option.is_some after_retry))))

let sync_retains_all_publications_in_a_feed_fork () =
  with_https_relay (fun client project url ->
      with_directory "yeokcham-v1-sync-fork-" (fun parent ->
          with_test_signer (fun signer_directory ->
              let ( source,
                    destination,
                    administrator_capability,
                    member_capability ) =
                source_and_destination parent
              in
              Out_channel.with_open_bin (Filename.concat source "main.ml")
                (fun channel ->
                  Out_channel.output_string channel "let fork = 1\n");
              Service.share_signed ~authority_epoch:None ~root:source
                ~change:
                  (Model.Change_id.of_string "change-fork" |> Result.get_ok)
                ~revision:
                  (Model.Revision_id.of_string "revision-fork" |> Result.get_ok)
                ~signing_capability:administrator_capability
              |> require_ok Service.error_to_string
              |> ignore;
              let outbound =
                Service.prepare_transport_outbound ~root:source ~remote:"team"
                  ~signing_capability:administrator_capability
                |> require_ok Service.error_to_string
              in
              let outbound =
                match outbound with
                | Some outbound -> outbound
                | None -> Alcotest.fail "fork source has no transport package"
              in
              let root_publication = outbound.Service.outbound_publication in
              let identity =
                Service.identity ~root:source
                |> require_ok Service.error_to_string
              in
              let manifest = Transport.publication_manifest root_publication in
              let child manifest =
                Transport.create_publication ~repository:(repository ())
                  ~publisher:identity.Service.device
                  ~certificate:
                    (Transport.publication_certificate root_publication)
                  ~parents:[ Transport.publication_id root_publication ]
                  ~manifest ~signing_capability:administrator_capability
                |> require_ok Transport.error_to_string
              in
              let left = child manifest in
              let source_repository =
                Store.open_repository ~root:source
                |> require_ok Store.error_to_string
              in
              let source_loaded =
                Store.load source_repository |> require_ok Store.error_to_string
              in
              let source_authority =
                match source_loaded.Store.collaboration with
                | Some collaboration -> (
                    match Store.authority collaboration with
                    | Some authority -> authority
                    | None -> Alcotest.fail "fork source has no authority")
                | None -> Alcotest.fail "fork source lost collaboration"
              in
              let empty_package = Filename.concat parent "fork-empty-package" in
              Package.create_with_authority
                ~source:(Store.underlying_store source_repository)
                ~destination:empty_package ~authority:source_authority
                ~revisions:[] ~authorizations:[] ~adoptions:[]
              |> require_ok Package.error_to_string;
              let empty_artifact =
                Package.read_artifact ~package:empty_package
                |> require_ok Package.error_to_string
              in
              let right =
                child
                  (Transport.sha256 (Package.artifact_manifest empty_artifact))
              in
              upload_artifact client ~project outbound.Service.outbound_artifact
                root_publication;
              let left_bytes = Transport.encode_publication left in
              Transport_http.put client ~project
                ~kind:Transport_http.Publication
                ~id:(Transport.publication_id left)
                ~bytes:left_bytes
              |> require_ok Transport_http.error_to_string;
              upload_artifact client ~project empty_artifact right;
              Transport_config.add ~root:destination ~name:"team" ~url
              |> require_ok Transport_config.error_to_string;
              store_test_signer signer_directory member_capability;
              Unix.putenv "YEOKCHAM_V1_TEST_TRANSPORT_TOKEN"
                (relay_test_token ());
              Unix.putenv "YEOKCHAM_V1_TEST_TRANSPORT_FAIL_PUT" "1";
              let output, errors, status =
                run_cli [ "sync"; "--root"; destination; "team" ]
              in
              require_cli_success "fork sync" errors status;
              expect_output_contains "all fork publications are discovered"
                "received publications 3" output;
              let repository =
                Store.open_repository ~root:destination
                |> require_ok Store.error_to_string
              in
              let loaded =
                Store.load repository |> require_ok Store.error_to_string
              in
              let known =
                match loaded.Store.collaboration with
                | Some collaboration -> (
                    match
                      Transport.find_remote
                        (Store.transport collaboration)
                        ~name:"team"
                    with
                    | Some remote -> Transport.remote_known_publications remote
                    | None -> Alcotest.fail "fork sync did not save its remote")
                | None -> Alcotest.fail "fork sync lost collaboration"
              in
              Alcotest.(check int)
                "fork references retain both children and parent" 3
                (List.length known))))

let incomplete_remote_closure_leaves_the_replica_unchanged () =
  with_https_relay (fun client project url ->
      with_directory "yeokcham-v1-incomplete-sync-" (fun parent ->
          with_test_signer (fun signer_directory ->
              let ( source,
                    destination,
                    administrator_capability,
                    member_capability ) =
                source_and_destination parent
              in
              Out_channel.with_open_bin (Filename.concat source "main.ml")
                (fun channel ->
                  Out_channel.output_string channel "let remote = 2\n");
              Service.share_signed ~authority_epoch:None ~root:source
                ~change:
                  (Model.Change_id.of_string "change-incomplete"
                  |> Result.get_ok)
                ~revision:
                  (Model.Revision_id.of_string "revision-incomplete"
                  |> Result.get_ok)
                ~signing_capability:administrator_capability
              |> require_ok Service.error_to_string
              |> ignore;
              let outbound =
                Service.prepare_transport_outbound ~root:source ~remote:"team"
                  ~signing_capability:administrator_capability
                |> require_ok Service.error_to_string
              in
              let outbound =
                match outbound with
                | Some outbound -> outbound
                | None -> Alcotest.fail "incomplete source has no package"
              in
              let manifest =
                Package.artifact_manifest outbound.Service.outbound_artifact
              in
              Transport_http.put client ~project ~kind:Transport_http.Manifest
                ~id:(Transport.sha256 manifest)
                ~bytes:manifest
              |> require_ok Transport_http.error_to_string;
              let publication =
                Transport.encode_publication
                  outbound.Service.outbound_publication
              in
              Transport_http.put client ~project
                ~kind:Transport_http.Publication
                ~id:
                  (Transport.publication_id
                     outbound.Service.outbound_publication)
                ~bytes:publication
              |> require_ok Transport_http.error_to_string;
              Transport_config.add ~root:destination ~name:"team" ~url
              |> require_ok Transport_config.error_to_string;
              store_test_signer signer_directory member_capability;
              Unix.putenv "YEOKCHAM_V1_TEST_TRANSPORT_TOKEN"
                (relay_test_token ());
              let before =
                Service.status ~root:destination
                |> require_ok Service.error_to_string
              in
              let destination_repository =
                Store.open_repository ~root:destination
                |> require_ok Store.error_to_string
              in
              let before_objects =
                Object_store.list_objects
                  (Store.underlying_store destination_repository)
                |> require_ok Object_store.error_to_string
                |> List.length
              in
              let before_cursor =
                Service.transport_cursor ~root:destination ~remote:"team"
                |> require_ok Service.error_to_string
              in
              let _output, _errors, status =
                run_cli [ "sync"; "--root"; destination; "team" ]
              in
              require_cli_failure "incomplete relay sync" status;
              let after =
                Service.status ~root:destination
                |> require_ok Service.error_to_string
              in
              let after_objects =
                Object_store.list_objects
                  (Store.underlying_store destination_repository)
                |> require_ok Object_store.error_to_string
                |> List.length
              in
              let after_cursor =
                Service.transport_cursor ~root:destination ~remote:"team"
                |> require_ok Service.error_to_string
              in
              Alcotest.(check int)
                "incomplete closure changes no shared work"
                before.Service.shared_change_count
                after.Service.shared_change_count;
              Alcotest.(check (option string))
                "incomplete closure changes no cursor" before_cursor
                after_cursor;
              Alcotest.(check int)
                "incomplete closure imports no destination object"
                before_objects after_objects;
              Alcotest.(check string)
                "sync never rewrites the working tree" "let version = 1\n"
                (In_channel.with_open_bin
                   (Filename.concat destination "main.ml")
                   In_channel.input_all))))

let malicious_relay_inputs_leave_the_replica_unchanged () =
  with_directory "yeokcham-v1-malicious-sync-" (fun parent ->
      with_test_signer (fun signer_directory ->
          let source, destination, administrator_capability, member_capability =
            source_and_destination parent
          in
          Out_channel.with_open_bin (Filename.concat source "main.ml")
            (fun channel ->
              Out_channel.output_string channel "let remote = 2\n");
          Service.share_signed ~authority_epoch:None ~root:source
            ~change:
              (Model.Change_id.of_string "change-malicious" |> Result.get_ok)
            ~revision:
              (Model.Revision_id.of_string "revision-malicious" |> Result.get_ok)
            ~signing_capability:administrator_capability
          |> require_ok Service.error_to_string
          |> ignore;
          let outbound =
            Service.prepare_transport_outbound ~root:source ~remote:"team"
              ~signing_capability:administrator_capability
            |> require_ok Service.error_to_string
            |> Option.get
          in
          let publication = outbound.Service.outbound_publication in
          let artifact = outbound.Service.outbound_artifact in
          let source_identity =
            Service.identity ~root:source |> require_ok Service.error_to_string
          in
          let manifest = Package.artifact_manifest artifact in
          let first_object_id =
            match artifact_objects artifact with
            | (id, _) :: _ -> Object_store.Stored_object_id.to_hex id
            | [] ->
                Alcotest.fail "transport artifact unexpectedly has no objects"
          in
          let project = Trust.Repository_id.to_string (repository ()) in
          let base = "/v1/repositories/" ^ project in
          let publication_page id =
            Encoding.array
              [
                Encoding.array [ Encoding.text id |> Result.get_ok ]
                |> Result.get_ok;
                Encoding.null;
              ]
            |> Result.get_ok |> Encoding.encode
          in
          let reply_for_artifact ~listed_id ~publication ~manifest ~object_reply
              target =
            if String.starts_with ~prefix:(base ^ "/publications?") target then
              (200, publication_page listed_id)
            else if String.equal target (base ^ "/publications/" ^ listed_id)
            then (200, Transport.encode_publication publication)
            else if
              String.equal target
                (base ^ "/manifests/"
                ^ Transport.publication_manifest publication)
            then (200, manifest)
            else if String.starts_with ~prefix:(base ^ "/objects/") target then
              object_reply target
            else (404, "")
          in
          let same_publisher ~repository ~parents ~manifest =
            Transport.create_publication ~repository
              ~publisher:source_identity.Service.device
              ~certificate:(Transport.publication_certificate publication)
              ~parents ~manifest ~signing_capability:administrator_capability
            |> require_ok Transport.error_to_string
          in
          let corrupt_publication = "\255" in
          let corrupt_manifest = "\255" in
          let wrong_route_id = Transport.sha256 "announced route ID" in
          let wrong_repository =
            Trust.Repository_id.of_string
              "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
            |> Result.get_ok
          in
          let wrong_repository_publication =
            same_publisher ~repository:wrong_repository ~parents:[]
              ~manifest:(Transport.publication_manifest publication)
          in
          let corrupt_manifest_publication =
            same_publisher ~repository:(repository ()) ~parents:[]
              ~manifest:(Transport.sha256 corrupt_manifest)
          in
          let causal_parent_publication =
            same_publisher ~repository:(repository ())
              ~parents:[ Transport.sha256 "missing causal parent" ]
              ~manifest:(Transport.publication_manifest publication)
          in
          let cases =
            [
              ( "corrupt-publication",
                base ^ "/publications/" ^ Transport.sha256 corrupt_publication,
                fun target ->
                  if String.starts_with ~prefix:(base ^ "/publications?") target
                  then
                    ( 200,
                      publication_page (Transport.sha256 corrupt_publication) )
                  else if
                    String.equal target
                      (base ^ "/publications/"
                      ^ Transport.sha256 corrupt_publication)
                  then (200, corrupt_publication)
                  else (404, "") );
              ( "wrong-publication-route",
                base ^ "/publications/" ^ wrong_route_id,
                reply_for_artifact ~listed_id:wrong_route_id ~publication
                  ~manifest ~object_reply:(fun _ -> (404, "")) );
              ( "wrong-repository",
                base ^ "/manifests/"
                ^ Transport.publication_manifest wrong_repository_publication,
                reply_for_artifact
                  ~listed_id:
                    (Transport.publication_id wrong_repository_publication)
                  ~publication:wrong_repository_publication ~manifest
                  ~object_reply:(fun target ->
                    let id =
                      String.sub target
                        (String.length (base ^ "/objects/"))
                        (String.length target
                        - String.length (base ^ "/objects/"))
                    in
                    match
                      List.find_opt
                        (fun (object_id, _) ->
                          String.equal
                            (Object_store.Stored_object_id.to_hex object_id)
                            id)
                        (artifact_objects artifact)
                    with
                    | Some (_, bytes) -> (200, bytes)
                    | None -> (404, "")) );
              ( "corrupt-manifest",
                base ^ "/manifests/"
                ^ Transport.publication_manifest corrupt_manifest_publication,
                reply_for_artifact
                  ~listed_id:
                    (Transport.publication_id corrupt_manifest_publication)
                  ~publication:corrupt_manifest_publication
                  ~manifest:corrupt_manifest ~object_reply:(fun _ -> (404, ""))
              );
              ( "corrupt-object",
                base ^ "/objects/" ^ first_object_id,
                reply_for_artifact
                  ~listed_id:(Transport.publication_id publication)
                  ~publication ~manifest ~object_reply:(fun _ ->
                    (200, "corrupt object")) );
              ( "missing-closure-object",
                base ^ "/objects/" ^ first_object_id,
                reply_for_artifact
                  ~listed_id:(Transport.publication_id publication)
                  ~publication ~manifest ~object_reply:(fun _ -> (404, "")) );
              ( "causal-parent",
                base ^ "/objects/" ^ first_object_id,
                reply_for_artifact
                  ~listed_id:
                    (Transport.publication_id causal_parent_publication)
                  ~publication:causal_parent_publication ~manifest
                  ~object_reply:(fun target ->
                    let id =
                      String.sub target
                        (String.length (base ^ "/objects/"))
                        (String.length target
                        - String.length (base ^ "/objects/"))
                    in
                    match
                      List.find_opt
                        (fun (object_id, _) ->
                          String.equal
                            (Object_store.Stored_object_id.to_hex object_id)
                            id)
                        (artifact_objects artifact)
                    with
                    | Some (_, bytes) -> (200, bytes)
                    | None -> (404, "")) );
            ]
          in
          store_test_signer signer_directory member_capability;
          List.iter
            (fun (name, expected_request, respond) ->
              with_malicious_https_server ~respond (fun ~requests url ->
                  let remote = "malformed-" ^ name in
                  Transport_config.add ~root:destination ~name:remote ~url
                  |> require_ok Transport_config.error_to_string;
                  let destination_repository =
                    Store.open_repository ~root:destination
                    |> require_ok Store.error_to_string
                  in
                  let before_loaded =
                    Store.load destination_repository
                    |> require_ok Store.error_to_string
                  in
                  let before_objects =
                    Object_store.list_objects
                      (Store.underlying_store destination_repository)
                    |> require_ok Object_store.error_to_string
                    |> List.length
                  in
                  let before_cursor =
                    Service.transport_cursor ~root:destination ~remote
                    |> require_ok Service.error_to_string
                  in
                  let _output, _errors, status =
                    run_cli [ "sync"; "--root"; destination; remote ]
                  in
                  require_cli_failure ("malicious relay " ^ name) status;
                  let after_loaded =
                    Store.load destination_repository
                    |> require_ok Store.error_to_string
                  in
                  let after_objects =
                    Object_store.list_objects
                      (Store.underlying_store destination_repository)
                    |> require_ok Object_store.error_to_string
                    |> List.length
                  in
                  let after_cursor =
                    Service.transport_cursor ~root:destination ~remote
                    |> require_ok Service.error_to_string
                  in
                  Alcotest.(check string)
                    (name ^ " leaves the mutable state head unchanged")
                    (Object_store.Stored_object_id.to_hex
                       before_loaded.Store.object_id)
                    (Object_store.Stored_object_id.to_hex
                       after_loaded.Store.object_id);
                  Alcotest.(check int)
                    (name ^ " imports no destination object")
                    before_objects after_objects;
                  Alcotest.(check (option string))
                    (name ^ " changes no transport cursor")
                    before_cursor after_cursor;
                  Alcotest.(check string)
                    (name ^ " leaves the working tree untouched")
                    "let version = 1\n"
                    (In_channel.with_open_bin
                       (Filename.concat destination "main.ml")
                       In_channel.input_all);
                  Alcotest.(check bool)
                    (name ^ " reaches its malicious relay response")
                    true
                    ( In_channel.with_open_bin requests In_channel.input_all
                    |> fun observed -> contains observed expected_request )))
            cases))

let sync_receives_signed_resolutions_as_decision_resolutions () =
  with_https_relay (fun client project url ->
      with_directory "yeokcham-v1-resolution-sync-" (fun parent ->
          with_test_signer (fun signer_directory ->
              let ( source,
                    destination,
                    administrator_capability,
                    member_capability ) =
                source_and_destination parent
              in
              let change value =
                Model.Change_id.of_string value |> Result.get_ok
              in
              let revision value =
                Model.Revision_id.of_string value |> Result.get_ok
              in
              let draft value =
                Model.Draft_id.of_string value |> Result.get_ok
              in
              Out_channel.with_open_bin (Filename.concat source "main.ml")
                (fun channel ->
                  Out_channel.output_string channel "let version = 2\n");
              Service.share_signed ~authority_epoch:None ~root:source
                ~change:(change "change-resolution-a")
                ~revision:(revision "revision-resolution-a")
                ~signing_capability:administrator_capability
              |> require_ok Service.error_to_string
              |> ignore;
              Service.new_draft ~root:source
                ~id:(draft "draft-resolution-two")
                ~title:"conflicting work"
              |> require_ok Service.error_to_string
              |> ignore;
              Out_channel.with_open_bin (Filename.concat source "main.ml")
                (fun channel ->
                  Out_channel.output_string channel "let version = 3\n");
              let conflicting =
                Service.share_signed ~authority_epoch:None ~root:source
                  ~change:(change "change-resolution-b")
                  ~revision:(revision "revision-resolution-b")
                  ~signing_capability:administrator_capability
                |> require_ok Service.error_to_string
              in
              let decision = List.hd conflicting.Service.open_decisions in
              Service.resolve_signed ~authority_epoch:None ~root:source
                ~decision:decision.Model.decision_id
                ~change:(change "change-resolution-final")
                ~revision:(revision "revision-resolution-final")
                ~tree:None ~signing_capability:administrator_capability
              |> require_ok Service.error_to_string
              |> ignore;
              let outbound =
                Service.prepare_transport_outbound ~root:source ~remote:"team"
                  ~signing_capability:administrator_capability
                |> require_ok Service.error_to_string
              in
              let outbound =
                match outbound with
                | Some outbound -> outbound
                | None -> Alcotest.fail "resolution source has no package"
              in
              upload_artifact client ~project outbound.Service.outbound_artifact
                outbound.Service.outbound_publication;
              Transport_config.add ~root:destination ~name:"team" ~url
              |> require_ok Transport_config.error_to_string;
              store_test_signer signer_directory member_capability;
              Unix.putenv "YEOKCHAM_V1_TEST_TRANSPORT_TOKEN"
                (relay_test_token ());
              Unix.putenv "YEOKCHAM_V1_TEST_TRANSPORT_FAIL_PUT" "1";
              let output, errors, status =
                run_cli [ "sync"; "--root"; destination; "team" ]
              in
              require_cli_success "resolution sync" errors status;
              expect_output_contains "resolution publication is received"
                "received publications 1" output;
              let received =
                Service.status ~root:destination
                |> require_ok Service.error_to_string
              in
              Alcotest.(check int)
                "the received resolution closes its decision" 0
                (List.length received.Service.open_decisions);
              let repository =
                Store.open_repository ~root:destination
                |> require_ok Store.error_to_string
              in
              let loaded =
                Store.load repository |> require_ok Store.error_to_string
              in
              let signed_resolution =
                match loaded.Store.collaboration with
                | Some collaboration ->
                    Store.signed_revisions collaboration
                    |> List.find_opt (fun signed ->
                        Option.is_some (Trust.signed_revision_resolution signed))
                | None -> None
              in
              Alcotest.(check bool)
                "resolution stays purpose-bound in transport" true
                (Option.is_some signed_resolution);
              Alcotest.(check string)
                "sync leaves the working tree untouched" "let version = 1\n"
                (In_channel.with_open_bin
                   (Filename.concat destination "main.ml")
                   In_channel.input_all))))

let relay_is_create_only_and_paginated () =
  with_directory "yeokcham-v1-relay-" (fun root ->
      let relay =
        Relay.open_repository ~root |> require_ok Relay.error_to_string
      in
      let project = Trust.Repository_id.to_string (repository ()) in
      let first = "first manifest" in
      let first_id = Transport.sha256 first in
      Relay.create relay ~project ~kind:Relay.Manifest ~id:first_id ~bytes:first
      |> require_ok Relay.error_to_string;
      Relay.create relay ~project ~kind:Relay.Manifest ~id:first_id ~bytes:first
      |> require_ok Relay.error_to_string;
      (match
         Relay.create relay ~project ~kind:Relay.Manifest ~id:first_id
           ~bytes:"different"
       with
      | Error error ->
          Alcotest.(check string)
            "route digest mismatch"
            "invalid V1 relay immutable bytes: route ID does not match SHA-256 \
             bytes"
            (Relay.error_to_string error)
      | Ok () -> Alcotest.fail "route digest mismatch was accepted");
      let publications = [ "publication one"; "publication two" ] in
      List.iter
        (fun bytes ->
          Relay.create relay ~project ~kind:Relay.Publication
            ~id:(Transport.sha256 bytes) ~bytes
          |> require_ok Relay.error_to_string)
        publications;
      let page, cursor =
        Relay.list_publications relay ~project ~cursor:None ~limit:1
        |> require_ok Relay.error_to_string
      in
      Alcotest.(check int) "first page is bounded" 1 (List.length page);
      let second, _ =
        Relay.list_publications relay ~project ~cursor
          ~limit:Relay.max_page_size
        |> require_ok Relay.error_to_string
      in
      Alcotest.(check int)
        "second page contains remaining publication" 1 (List.length second))

let bootstrap_relay_entries_are_create_only_and_sha_bound () =
  with_directory "yeokcham-v1-bootstrap-relay-" (fun root ->
      let relay =
        Relay.open_repository ~root |> require_ok Relay.error_to_string
      in
      let project = Trust.Repository_id.to_string (repository ()) in
      let bytes = "bootstrap basis bytes" in
      let id = Transport.sha256 bytes in
      Relay.create relay ~project ~kind:Relay.Bootstrap ~id ~bytes
      |> require_ok Relay.error_to_string;
      Relay.create relay ~project ~kind:Relay.Bootstrap ~id ~bytes
      |> require_ok Relay.error_to_string;
      Alcotest.(check string)
        "bootstrap bytes round trip" bytes
        (Relay.get relay ~project ~kind:Relay.Bootstrap ~id
        |> require_ok Relay.error_to_string);
      (match
         Relay.create relay ~project ~kind:Relay.Bootstrap ~id ~bytes:"other"
       with
      | Error _ ->
          Alcotest.(check string)
            "bootstrap bytes remain immutable" bytes
            (Relay.get relay ~project ~kind:Relay.Bootstrap ~id
            |> require_ok Relay.error_to_string)
      | Ok () -> Alcotest.fail "bootstrap relay overwrote immutable bytes");
      match
        Relay.create relay ~project ~kind:Relay.Bootstrap
          ~id:(Transport.sha256 "other") ~bytes
      with
      | Error _ -> ()
      | Ok () -> Alcotest.fail "bootstrap relay accepted a wrong route digest")

let relay_access_scopes_rotation_and_expiry_are_enforced () =
  with_http_relay (fun ~relay_root ~port ~token:_ ->
      let project = Trust.Repository_id.to_string (repository ()) in
      let other_project =
        "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
      in
      let now = Int64.of_float (Unix.gettimeofday ()) in
      let issue ~repository ~scopes ~now ~expires_in =
        Relay_access.update ~root:relay_root (fun registry ->
            Relay_access.issue ~now ~repository ~scopes ~expires_in registry)
        |> require_ok Relay_access.error_to_string
      in
      let path project kind id =
        "/v1/repositories/" ^ project ^ "/" ^ kind ^ "/" ^ id
      in
      let list project = "/v1/repositories/" ^ project ^ "/publications" in
      let bytes = "access denied write" in
      let id = Transport.sha256 bytes in
      let read_only =
        issue ~repository:project ~scopes:[ Relay_access.Read ] ~now
          ~expires_in:Relay_access.default_lifetime_seconds
      in
      Alcotest.(check int)
        "read-only secret may list publications" 200
        (response_status
           (raw_http ~port
              (raw_request ~token:read_only.Relay_access.grant_secret "GET"
                 (list project))));
      Alcotest.(check int)
        "read-only secret cannot upload" 403
        (response_status
           (raw_http ~port
              (raw_request ~token:read_only.Relay_access.grant_secret
                 ~body:bytes "PUT"
                 (path project "manifests" id))));
      let write_only =
        issue ~repository:project ~scopes:[ Relay_access.Write ] ~now
          ~expires_in:Relay_access.default_lifetime_seconds
      in
      Alcotest.(check int)
        "write-only secret cannot list publications" 403
        (response_status
           (raw_http ~port
              (raw_request ~token:write_only.Relay_access.grant_secret "GET"
                 (list project))));
      let other_repository =
        issue ~repository:other_project
          ~scopes:[ Relay_access.Read; Relay_access.Write ]
          ~now ~expires_in:Relay_access.default_lifetime_seconds
      in
      Alcotest.(check int)
        "cross-repository secret is denied" 403
        (response_status
           (raw_http ~port
              (raw_request ~token:other_repository.Relay_access.grant_secret
                 "GET" (list project))));
      let expired =
        issue ~repository:project ~scopes:[ Relay_access.Read ]
          ~now:(Int64.sub now 2L) ~expires_in:1L
      in
      Alcotest.(check int)
        "expired secret is unauthenticated" 401
        (response_status
           (raw_http ~port
              (raw_request ~token:expired.Relay_access.grant_secret "GET"
                 (list project))));
      let replaced =
        issue ~repository:project ~scopes:[ Relay_access.Read ] ~now
          ~expires_in:Relay_access.default_lifetime_seconds
      in
      let replacement =
        Relay_access.update ~root:relay_root (fun registry ->
            Relay_access.rotate ~now
              ~credential_id:replaced.Relay_access.grant_credential_id
              ~expires_in:Relay_access.default_lifetime_seconds registry)
        |> require_ok Relay_access.error_to_string
      in
      Alcotest.(check int)
        "rotated old secret is rejected on replay" 401
        (response_status
           (raw_http ~port
              (raw_request ~token:replaced.Relay_access.grant_secret "GET"
                 (list project))));
      Alcotest.(check int)
        "rotated replacement remains usable" 200
        (response_status
           (raw_http ~port
              (raw_request ~token:replacement.Relay_access.grant_secret "GET"
                 (list project))));
      let revoked =
        issue ~repository:project ~scopes:[ Relay_access.Read ] ~now
          ~expires_in:Relay_access.default_lifetime_seconds
      in
      Relay_access.update ~root:relay_root (fun registry ->
          Relay_access.revoke ~now
            ~credential_id:revoked.Relay_access.grant_credential_id registry
          |> Result.map (fun registry -> (registry, ())))
      |> require_ok Relay_access.error_to_string;
      Alcotest.(check int)
        "revoked secret is unauthenticated" 401
        (response_status
           (raw_http ~port
              (raw_request ~token:revoked.Relay_access.grant_secret "GET"
                 (list project))));
      let relay =
        Relay.open_repository ~root:relay_root
        |> require_ok Relay.error_to_string
      in
      match Relay.get relay ~project ~kind:Relay.Manifest ~id with
      | Error error when Relay.is_missing error -> ()
      | Ok _ -> Alcotest.fail "denied upload wrote an immutable relay object"
      | Error error -> Alcotest.fail (Relay.error_to_string error))

let () =
  Alcotest.run "V1 transport"
    [
      ( "publication",
        [
          Alcotest.test_case "canonical signed publication" `Quick
            publication_round_trip;
          Alcotest.test_case "feed rejects missing parent" `Quick
            feed_rejects_missing_parent;
          Alcotest.test_case "same-publisher feed forks are retained" `Quick
            feed_preserves_same_publisher_forks;
          Alcotest.test_case "local state is canonical" `Quick
            local_state_round_trip;
        ] );
      ( "relay",
        [
          Alcotest.test_case "create-only storage and pagination" `Quick
            relay_is_create_only_and_paginated;
          Alcotest.test_case "bootstrap storage is create-only and SHA-bound"
            `Quick bootstrap_relay_entries_are_create_only_and_sha_bound;
          Alcotest.test_case "HTTP listener rejects invalid requests" `Quick
            http_listener_rejects_untrusted_requests_and_preserves_immutability;
          Alcotest.test_case "configured relay caps requested V2 session expiry"
            `Quick configured_relay_refuses_session_expiry_above_operator_limit;
          Alcotest.test_case "configured relay refuses nonwritable storage"
            `Quick configured_relay_refuses_nonwritable_storage;
          Alcotest.test_case
            "scoped access rejects expiry, revocation, replay, and \
             cross-project use"
            `Quick relay_access_scopes_rotation_and_expiry_are_enforced;
          Alcotest.test_case "HTTPS reverse proxy reaches the relay" `Slow
            https_client_reaches_relay_through_tls_reverse_proxy;
          Alcotest.test_case "V2 HTTPS upload resumes and download stays exact"
            `Slow https_v2_upload_resume_download_and_v1_fallback;
          Alcotest.test_case "V2 absence keeps V1 fallback explicit" `Slow
            explicit_v1_fallback_when_v2_is_unavailable;
          Alcotest.test_case "V2 retries only transient server failures" `Slow
            v2_retries_only_transient_server_failures;
          Alcotest.test_case "V2 revocation rejects a resumed segment" `Quick
            v2_http_credential_revocation_refuses_resumed_segment;
          Alcotest.test_case
            "interrupted upload retains received work for retry" `Slow
            interrupted_upload_leaves_received_work_durable;
          Alcotest.test_case "sync retains every publication in a feed fork"
            `Slow sync_retains_all_publications_in_a_feed_fork;
          Alcotest.test_case "incomplete relay closure cannot mutate a replica"
            `Slow incomplete_remote_closure_leaves_the_replica_unchanged;
          Alcotest.test_case "malicious relay inputs cannot mutate a replica"
            `Slow malicious_relay_inputs_leave_the_replica_unchanged;
          Alcotest.test_case "sync preserves signed resolution purpose" `Slow
            sync_receives_signed_resolutions_as_decision_resolutions;
        ] );
    ]
