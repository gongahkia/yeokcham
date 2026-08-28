module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust
module Transport = Yeokcham_v4_transport
module Relay = Yeokcham_v4_relay
module Relay_http = Yeokcham_v4_relay_http
module Transport_http = Yeokcham_v4_transport_http
module Transport_config = Yeokcham_v4_transport_config
module Service = Yeokcham_v4_local_service
module Package = Yeokcham_v4_package
module Store = Yeokcham_store

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
    (read_golden "v4/transport-publication-v1.cbor.hex")
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
        ("V4 transport publication is missing feed parent: " ^ parent)
        (Transport.error_to_string error)
  | Ok () -> Alcotest.fail "missing feed parent was accepted"

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
    (read_golden "v4/transport-local-state-v1.cbor.hex")
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
  let openssl = "/usr/bin/openssl" in
  let socat = "/usr/bin/socat" in
  if not (Sys.file_exists openssl && Sys.file_exists socat) then
    Alcotest.skip "requires local openssl and socat";
  with_directory "yeokcham-v4-https-relay-" (fun root ->
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
      let token_file = Filename.concat root "token" in
      Out_channel.with_open_bin token_file (fun channel ->
          Out_channel.output_string channel "test-relay-token\n");
      let backend_port = available_loopback_port () in
      let proxy_port = available_loopback_port () in
      let backend =
        match Unix.fork () with
        | 0 -> (
            match
              Relay_http.serve ~root:relay_root
                ~listen:("127.0.0.1:" ^ string_of_int backend_port)
                ~token_file
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
      Fun.protect
        ~finally:(fun () ->
          terminate proxy;
          terminate backend)
        (fun () ->
          Unix.putenv "YEOKCHAM_V4_TEST_TRANSPORT" "1";
          Unix.putenv "YEOKCHAM_V4_TEST_TRANSPORT_CA_BUNDLE" certificate;
          let client =
            Transport_http.create
              ~url:("https://127.0.0.1:" ^ string_of_int proxy_port)
              ~token:"test-relay-token"
            |> require_ok Transport_http.error_to_string
          in
          let project = Trust.Repository_id.to_string (repository ()) in
          wait_for_https_relay client project 100;
          run client project
            ("https://127.0.0.1:" ^ string_of_int proxy_port)))

let https_client_reaches_relay_through_tls_reverse_proxy () =
  with_https_relay (fun client project _url ->
          let object_bytes = "TLS reverse proxy object" in
          let object_id = Transport.sha256 object_bytes in
          Transport_http.put client ~project ~kind:Transport_http.Object
            ~id:object_id ~bytes:object_bytes
          |> require_ok Transport_http.error_to_string;
          let retrieved =
            Transport_http.get client ~project ~kind:Transport_http.Object
              ~id:object_id
            |> require_ok Transport_http.error_to_string
          in
          Alcotest.(check string)
            "the TLS proxy preserves relay object bytes" object_bytes retrieved;
          let publication = "TLS reverse proxy publication" in
          let publication_id = Transport.sha256 publication in
          Transport_http.put client ~project ~kind:Transport_http.Publication
            ~id:publication_id ~bytes:publication
          |> require_ok Transport_http.error_to_string;
          let publications, cursor =
            Transport_http.list_publications client ~project ~cursor:None
              ~limit:1
            |> require_ok Transport_http.error_to_string
          in
          Alcotest.(check (list string))
            "publication discovery crosses the TLS proxy" [ publication_id ]
            publications;
          Alcotest.(check (option string))
            "one publication has no next page" None cursor)

let executable () =
  let from_test_binary =
    Sys.executable_name |> Filename.dirname |> Filename.dirname
    |> fun build_root -> Filename.concat build_root "bin/yeokcham_v4.exe"
  in
  let candidates = [ from_test_binary; "_build/default/bin/yeokcham_v4.exe" ] in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.fail "cannot locate the yeokcham-v4 executable"

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
  let directory = Filename.temp_file "yeokcham-v4-test-signer-" "" in
  Unix.unlink directory;
  Unix.mkdir directory 0o700;
  Unix.putenv "YEOKCHAM_V4_TEST_SIGNER_DIRECTORY" directory;
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
        (Trust.signing_private_key_bytes capability))

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
  let source_loaded = Store.load source_repository |> require_ok Store.error_to_string in
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

let upload_artifact client ~project artifact publication =
  Package.artifact_objects artifact
  |> List.iter (fun (id, bytes) ->
      Transport_http.put client ~project ~kind:Transport_http.Object
        ~id:(Store.Stored_object_id.to_hex id) ~bytes
      |> require_ok Transport_http.error_to_string);
  let manifest = Package.artifact_manifest artifact in
  Transport_http.put client ~project ~kind:Transport_http.Manifest
    ~id:(Transport.sha256 manifest) ~bytes:manifest
  |> require_ok Transport_http.error_to_string;
  let bytes = Transport.encode_publication publication in
  Transport_http.put client ~project ~kind:Transport_http.Publication
    ~id:(Transport.publication_id publication) ~bytes
  |> require_ok Transport_http.error_to_string

let interrupted_upload_leaves_received_work_durable () =
  with_https_relay (fun client project url ->
      with_directory "yeokcham-v4-interrupted-sync-" (fun parent ->
          with_test_signer (fun signer_directory ->
              let source, destination, administrator_capability, member_capability =
                source_and_destination parent
              in
              Out_channel.with_open_bin (Filename.concat source "main.ml")
                (fun channel ->
                  Out_channel.output_string channel "let version = 2\n");
              Service.share_signed ~authority_epoch:None ~root:source
                ~change:(Model.Change_id.of_string "change-transport" |> Result.get_ok)
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
                | None -> Alcotest.fail "source has no outbound transport package"
              in
              upload_artifact client ~project outbound.Service.outbound_artifact
                outbound.Service.outbound_publication;
              Transport_config.add ~root:destination ~name:"team"
                ~url
              |> require_ok Transport_config.error_to_string;
              store_test_signer signer_directory member_capability;
              Unix.putenv "YEOKCHAM_V4_TEST_TRANSPORT_TOKEN" "test-relay-token";
              Unix.putenv "YEOKCHAM_V4_TEST_TRANSPORT_FAIL_PUT" "1";
              let output, errors, status =
                run_cli [ "sync"; "--root"; destination; "team" ]
              in
              require_cli_success "interrupted sync" errors status;
              expect_output_contains "sync reports durable receipt"
                "received publications 1" output;
              expect_output_contains "sync reports the interrupted upload"
                "upload pending test-only V4 transport upload interruption" output;
              let received =
                Service.status ~root:destination |> require_ok Service.error_to_string
              in
              Alcotest.(check int) "received revision persists after upload failure"
                1 received.Service.shared_change_count;
              let retry =
                Service.prepare_transport_outbound ~root:destination ~remote:"team"
                  ~signing_capability:member_capability
                |> require_ok Service.error_to_string
              in
              Alcotest.(check bool) "failed upload is not marked announced" true
                (Option.is_some retry))))

let relay_is_create_only_and_paginated () =
  with_directory "yeokcham-v4-relay-" (fun root ->
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
            "invalid V4 relay immutable bytes: route ID does not match SHA-256 \
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

let () =
  Alcotest.run "V4 transport"
    [
      ( "publication",
        [
          Alcotest.test_case "canonical signed publication" `Quick
            publication_round_trip;
          Alcotest.test_case "feed rejects missing parent" `Quick
            feed_rejects_missing_parent;
          Alcotest.test_case "local state is canonical" `Quick
            local_state_round_trip;
        ] );
      ( "relay",
        [
          Alcotest.test_case "create-only storage and pagination" `Quick
            relay_is_create_only_and_paginated;
          Alcotest.test_case "HTTPS reverse proxy reaches the relay" `Slow
            https_client_reaches_relay_through_tls_reverse_proxy;
        ] );
    ]
