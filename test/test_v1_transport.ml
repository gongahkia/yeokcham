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
    (Golden.refresh_lower_hex_file
       (golden_path "v1/transport-publication-v1.cbor.hex")
       encoded
    |> require_ok Fun.id)
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

let[@warning "-4"] core_outbox_canonical_and_monotonic () =
  let module Outbox = Transport.Core_outbox in
  let repository, capability, publisher, certificate, _ = authority () in
  let endpoint = Transport.sha256 "https://relay.invalid" in
  let make manifest =
    Transport.create_publication ~repository ~publisher
      ~certificate:(Trust.certificate_id certificate)
      ~parents:[]
      ~manifest:(Transport.sha256 manifest)
      ~signing_capability:capability
    |> require_ok Transport.error_to_string
  in
  let courier = make "manifest" in
  let freeze state manifest publication =
    Outbox.freeze state ~remote:"origin" ~endpoint ~manifest ~publication
    |> require_ok Transport.error_to_string
  in
  let pending = freeze Transport.empty_local_state "manifest" courier in
  let encoded =
    Transport.encode_local_state pending |> require_ok Transport.error_to_string
  in
  let golden =
    In_channel.with_open_bin
      (golden_path "core-package/outbound-state.hex")
      In_channel.input_all
    |> String.trim
  in
  let hex =
    String.init
      (String.length encoded * 2)
      (fun i ->
        let byte = Char.code encoded.[i / 2] in
        "0123456789abcdef".[if i mod 2 = 0 then byte lsr 4 else byte land 15])
  in
  Alcotest.(check string) "independent frozen control vector" golden hex;
  let decoded =
    Transport.decode_local_state encoded |> require_ok Transport.error_to_string
  in
  Alcotest.(check string)
    "exact canonical local transport round trip" encoded
    (Transport.encode_local_state decoded
    |> require_ok Transport.error_to_string);
  let reject = function
    | Ok _ -> Alcotest.fail "invalid Core outbound state accepted"
    | Error _ -> ()
  in
  reject
    (Outbox.freeze pending ~remote:"origin" ~endpoint ~manifest:"later"
       ~publication:(make "later"));
  reject
    (Outbox.freeze pending ~remote:"origin" ~endpoint ~manifest:"wrong"
       ~publication:courier);
  reject
    (Outbox.find pending ~remote:"origin"
       ~endpoint:(Transport.sha256 "different"));
  reject
    (Outbox.acknowledge pending ~remote:"origin" ~endpoint
       ~publication:(Transport.sha256 "other"));
  reject (Outbox.validate_update ~previous:pending Transport.empty_local_state);
  reject
    (Transport.decode_local_state (String.make ((16 * 1024 * 1024) + 1) '\000'));
  let value =
    Encoding.decode encoded |> require_ok Encoding.decode_error_to_string
  in
  let malformed rows =
    Encoding.array
      [
        Encoding.integer 2L;
        Encoding.array [] |> require_ok Encoding.construction_error_to_string;
        Encoding.array rows |> require_ok Encoding.construction_error_to_string;
      ]
    |> require_ok Encoding.construction_error_to_string
    |> Encoding.encode
  in
  (match value with
  | Encoding.Array [ _; _; Encoding.Array [ row ] ] -> (
      reject (Transport.decode_local_state (malformed []));
      reject (Transport.decode_local_state (malformed [ row; row ]));
      match row with
      | Encoding.Array fields ->
          let altered =
            Encoding.array
              (List.mapi
                 (fun i value ->
                   if i = 2 then Encoding.bytes "wrong manifest" else value)
                 fields)
            |> require_ok Encoding.construction_error_to_string
          in
          reject (Transport.decode_local_state (malformed [ altered ]))
      | _ -> assert false)
  | _ -> assert false);
  let acked =
    Outbox.acknowledge pending ~remote:"origin" ~endpoint
      ~publication:(Transport.publication_id courier)
    |> require_ok Transport.error_to_string
  in
  let ack_bytes =
    Transport.encode_local_state acked |> require_ok Transport.error_to_string
  in
  let ack_hex =
    String.init
      (String.length ack_bytes * 2)
      (fun i ->
        let byte = Char.code ack_bytes.[i / 2] in
        "0123456789abcdef".[if i mod 2 = 0 then byte lsr 4 else byte land 15])
  in
  Alcotest.(check string)
    "independent acknowledged courier catalogue vector"
    (In_channel.with_open_bin
       (golden_path "core-package/courier-state.hex")
       In_channel.input_all
    |> String.trim)
    ack_hex;
  Outbox.validate_update ~previous:pending acked
  |> require_ok Transport.error_to_string;
  reject (Outbox.validate_update ~previous:acked pending);
  let repeated = freeze acked "manifest" courier in
  Alcotest.(check bool)
    "identical freeze cannot erase acknowledgement" true
    (Outbox.acknowledged (List.hd (Outbox.batches repeated)));
  let later = freeze acked "later" (make "later") in
  Outbox.validate_update ~previous:acked later
  |> require_ok Transport.error_to_string;
  let lost_evidence = Transport.remove_remote later ~name:"origin" in
  reject (Outbox.validate_update ~previous:acked lost_evidence)

let[@warning "-4"] clone_controls_are_canonical_and_frozen () =
  let module Core = Model.Core in
  let module Clone = Transport.Core_clone in
  let identifier parse byte length =
    parse (String.make length byte) |> require_ok Core.error_to_string
  in
  let repository = identifier Core.Repository_id.of_raw 'a' 32
  and root = identifier Core.Digest.of_raw 'r' 32
  and branch = identifier Core.Branch_id.of_raw 'b' 16
  and accepted = identifier Core.Record_id.of_raw 'v' 32
  and event = identifier Core.Record_id.of_raw 'e' 32 in
  let device =
    Model.Device_id.of_string "device-clone" |> require_ok Model.error_to_string
  in
  let create ~url ~events =
    Clone.create ~url ~repository ~root ~device ~branch ~accepted ~events
  in
  let intent =
    create ~url:"https://relay.invalid" ~events:[ event ]
    |> require_ok Transport.error_to_string
  in
  let state =
    Clone.initialize Transport.empty_local_state intent
    |> require_ok Transport.error_to_string
  in
  let bytes =
    Transport.encode_local_state state |> require_ok Transport.error_to_string
  in
  let hex bytes =
    String.init
      (String.length bytes * 2)
      (fun i ->
        let b = Char.code bytes.[i / 2] in
        "0123456789abcdef".[if i mod 2 = 0 then b lsr 4 else b land 15])
  in
  let vector name =
    In_channel.with_open_bin
      (golden_path ("core-package/" ^ name))
      In_channel.input_all
    |> String.trim
  in
  Alcotest.(check string)
    "independent clone schema 4" (vector "clone-state.hex") (hex bytes);
  Alcotest.(check string)
    "independent request domain"
    (vector "clone-request-id.hex")
    (Clone.id intent |> require_ok Transport.error_to_string);
  let decoded =
    Transport.decode_local_state bytes |> require_ok Transport.error_to_string
  in
  Alcotest.(check string)
    "clone state canonical round trip" bytes
    (Transport.encode_local_state decoded
    |> require_ok Transport.error_to_string);
  let reject = function
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "invalid clone control accepted"
  in
  reject (create ~url:"http://relay.invalid" ~events:[ event ]);
  reject (create ~url:"https://secret@relay.invalid" ~events:[ event ]);
  reject (create ~url:"https://relay.invalid" ~events:[]);
  reject (create ~url:"https://relay.invalid" ~events:[ event; event ]);
  reject (Clone.finish state);
  reject
    (Clone.validate_update
       ~plan_started:(fun _ -> false)
       ~previous:Transport.empty_local_state state);
  reject
    (Clone.validate_update
       ~plan_started:(fun _ -> false)
       ~previous:state Transport.empty_local_state);
  let plan = identifier Core.Plan_id.of_raw 'p' 32
  and later = identifier Core.Plan_id.of_raw 'q' 32 in
  let bound =
    Clone.bind_plan state ~plan |> require_ok Transport.error_to_string
  in
  Clone.validate_update ~plan_started:(fun _ -> false) ~previous:state bound
  |> require_ok Transport.error_to_string;
  let replaced =
    Clone.bind_plan bound ~plan:later |> require_ok Transport.error_to_string
  in
  Clone.validate_update ~plan_started:(fun _ -> false) ~previous:bound replaced
  |> require_ok Transport.error_to_string;
  reject
    (Clone.validate_update
       ~plan_started:(fun _ -> true)
       ~previous:bound replaced);
  reject
    (Clone.validate_update ~plan_started:(fun _ -> false) ~previous:bound state);
  let completed = Clone.finish bound |> require_ok Transport.error_to_string in
  Clone.validate_update ~plan_started:(fun _ -> true) ~previous:bound completed
  |> require_ok Transport.error_to_string;
  reject
    (Clone.validate_update
       ~plan_started:(fun _ -> true)
       ~previous:completed bound);
  Alcotest.(check string)
    "plan/completion do not retarget request"
    (Clone.id intent |> require_ok Transport.error_to_string)
    (Clone.id (Option.get (Clone.find completed))
    |> require_ok Transport.error_to_string);
  let value =
    Encoding.decode bytes |> require_ok Encoding.decode_error_to_string
  in
  (match value with
  | Encoding.Array
      [ version; remotes; outgoing; incoming; Encoding.Array fields ] ->
      List.iter
        (fun (position, replacement) ->
          let clone =
            Encoding.array
              (List.mapi
                 (fun i old -> if i = position then replacement else old)
                 fields)
            |> require_ok Encoding.construction_error_to_string
          in
          let bad =
            Encoding.array [ version; remotes; outgoing; incoming; clone ]
            |> require_ok Encoding.construction_error_to_string
            |> Encoding.encode
          in
          reject (Transport.decode_local_state bad))
        [
          (0, Encoding.integer 2L);
          (2, Encoding.bytes "short");
          (5, Encoding.bytes (String.make 32 'b'));
          ( 7,
            Encoding.array []
            |> require_ok Encoding.construction_error_to_string );
          (9, Encoding.bool true);
        ]
  | _ -> Alcotest.fail "unexpected clone schema");
  let module Credential = Yeokcham_v1_transport_credential in
  let scope url repo =
    Credential.native_scope ~url ~repository:repo
    |> require_ok Credential.error_to_string
  in
  let repo = Core.Repository_id.to_hex repository in
  Alcotest.(check bool)
    "credential realm binds endpoint" false
    (scope "https://alice.invalid" repo = scope "https://bob.invalid" repo);
  Alcotest.(check bool)
    "credential realm binds repository" false
    (scope "https://alice.invalid" repo
    = scope "https://alice.invalid" (String.make 64 'b'))

let bounded_courier_batches_stop_before_accumulating_the_inventory () =
  let module Native = Yeokcham_v1_sync.Core in
  let repository, capability, publisher, certificate, _ = authority () in
  let rows =
    List.init 4 (fun i ->
        Transport.create_publication ~repository ~publisher
          ~certificate:(Trust.certificate_id certificate)
          ~parents:[]
          ~manifest:(Transport.sha256 (string_of_int i))
          ~signing_capability:capability
        |> require_ok Transport.error_to_string)
  in
  let ids = List.map Transport.publication_id rows in
  let fetched = ref [] in
  let fetch id =
    fetched := id :: !fetched;
    Ok (List.find (fun row -> Transport.publication_id row = id) rows)
  in
  let limit =
    rows
    |> List.filteri (fun i _ -> i < 2)
    |> List.fold_left
         (fun sum row -> sum + String.length (Transport.encode_publication row))
         0
  in
  let result =
    Native.For_test.collect_publications ~max_bytes:limit ~fetch ~known:[] ids
  in
  Alcotest.(check bool)
    "aggregate overflow refuses incomplete inventory" true
    (Result.is_error result);
  Alcotest.(check int)
    "overflow stops fetch before later inventory" 3 (List.length !fetched);
  fetched := [];
  let selected =
    Native.For_test.collect_publications ~max_bytes:limit ~fetch
      ~known:(List.filteri (fun i _ -> i >= 2) ids)
      ids
    |> require_ok Native.error_to_string
  in
  Alcotest.(check int)
    "exact bound accepts two couriers" 2 (List.length selected);
  Alcotest.(check int)
    "known inventory is not fetched or charged" 2 (List.length !fetched)

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
    (Golden.refresh_lower_hex_file
       (golden_path "v1/transport-local-state-v1.cbor.hex")
       encoded
    |> require_ok Fun.id)
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

let[@warning "-4-40-42"] native_core_replicas parent signer_directory =
  let module Core = Model.Core in
  let module Local = Store.Local in
  let module History = Yeokcham_v1_undo in
  let source, _, alice, bob = source_and_destination parent in
  store_test_signer signer_directory alice;
  store_test_signer signer_directory bob;
  let open_store root =
    Store.open_repository ~root |> require_ok Store.error_to_string
  in
  let load repository =
    Store.load repository |> require_ok Store.error_to_string
  in
  let source_repository = open_store source in
  let initial = load source_repository in
  let collaboration = Option.get initial.Store.collaboration in
  let authority = Option.get (Store.authority collaboration) in
  let initial_local =
    Local.initialize
      ~store:(Store.underlying_store source_repository)
      ~authority
      ~certificate:(Store.local_certificate collaboration)
      ~signing_capability:alice
      ~cursor:(History.current initial.Store.history).History.id
    |> require_ok Fun.id
  in
  Store.save_collaborative ~local:initial_local source_repository
    ~expected:initial.Store.head ~project:initial.Store.project ~collaboration
  |> require_ok Store.error_to_string
  |> ignore;
  let genesis = parent ^ "/genesis" in
  Package.Core.create
    ~source:(Store.underlying_store source_repository)
    ~destination:genesis ~authority
    ~records:(Local.record_objects initial_local)
    ~selected_branch:(Local.selected initial_local).Local.branch ~titles:[]
  |> require_ok Package.error_to_string
  |> ignore;
  let scope = Core.pool_repository (Local.pool initial_local) in
  let prepared =
    Package.Core.prepare ~package:genesis ~repository:scope
      ~known_authority:(Some authority)
    |> require_ok Package.error_to_string
  in
  let destination = parent ^ "/native-bob" in
  Unix.mkdir destination 0o700;
  let member_identity = device bob in
  let certificate =
    Trust.certificates (Trust.authority_membership authority)
    |> List.find (fun cert ->
        Trust.device_equal (Trust.certificate_subject cert) member_identity)
    |> Trust.certificate_id
  in
  (* pre-enrolled empty replica setup; this is not clone CLI evidence. *)
  let destination_repository =
    Store.init_local_collaborative_with ~root:destination ~bootstrap:(fun raw ->
        Package.Core.import_prepared ~destination:raw prepared
        |> require_ok Package.error_to_string;
        let local =
          Local.initialize_received ~store:raw ~authority
            ~records:(Package.Core.prepared_records prepared)
            ~selected_branch:(Local.selected initial_local).Local.branch
            ~cursor:0L
          |> require_ok Local.receive_error_to_string
        in
        let project =
          Model.init
            ~creator:(Trust.device_id member_identity)
            ~username:(Model.Username.of_string "bob" |> Result.get_ok)
            ~initial_snapshot:
              (Model.Snapshot_id.of_string
                 (Core.Object_id.to_hex (Local.empty_snapshot local))
              |> require_ok Model.error_to_string)
            ~initial_draft:
              (Model.Draft_id.of_string "bob-native" |> Result.get_ok)
            ~title:"private work"
        in
        let collaboration =
          Store.collaboration_with_authority ~authority ~revisions:[]
            ~local_certificate:certificate ~authorizations:[] ~adoptions:[]
          |> require_ok Store.error_to_string
        in
        Ok (project, collaboration, local))
    |> require_ok Store.error_to_string
  in
  ( source,
    destination,
    source_repository,
    destination_repository,
    alice,
    bob,
    scope )

let[@warning "-4-40-42"] native_core_exchange_uses_enrolled_replicas_and_exact_retry
    () =
  let module History = Yeokcham_v1_undo in
  let module Native = Yeokcham_v1_sync.Core in
  let module Outbox = Transport.Core_outbox in
  let load repository =
    Store.load repository |> require_ok Store.error_to_string
  in
  with_https_relay (fun client project url ->
      with_directory "yeokcham-native-exchange-" (fun parent ->
          with_test_signer (fun signer_directory ->
              let ( source,
                    destination,
                    source_repository,
                    destination_repository,
                    alice,
                    _,
                    scope ) =
                native_core_replicas parent signer_directory
              in
              List.iter
                (fun root ->
                  Transport_config.add ~root ~name:"team" ~url
                  |> require_ok Transport_config.error_to_string)
                [ source; destination ];
              let write path bytes =
                Out_channel.with_open_bin path (fun out ->
                    output_string out bytes)
              in
              let read path =
                In_channel.with_open_bin path In_channel.input_all
              in
              let sentinel = "PRIVATE ALICE SENTINEL NEVER EXPORTED 92fd432" in
              write (source ^ "/private.txt") sentinel;
              write (source ^ "/main.ml") "let version = 2\r\n";
              let binary =
                String.init 300731 (fun i -> Char.chr (i * 7 mod 251))
              in
              write (source ^ "/asset.bin") binary;
              write (source ^ "/run.sh") "#!/bin/sh\nprintf exact\n";
              Unix.chmod (source ^ "/run.sh") 0o700;
              Unix.symlink "main.ml" (source ^ "/link");
              Unix.mkdir (source ^ "/empty") 0o700;
              let output, errors, status =
                run_cli
                  [
                    "share";
                    "--root";
                    source;
                    "main.ml";
                    "asset.bin";
                    "run.sh";
                    "link";
                    "empty";
                    "--title";
                    "Selected D";
                    "--format";
                    "json";
                  ]
              in
              require_cli_success "native selected share" errors status;
              let open Yojson.Safe.Util in
              Alcotest.(check bool)
                "share returns domain JSON" true
                (Yojson.Safe.from_string output
                |> member "schema_version" = `Int 2);
              let before_send = load source_repository in
              let child = Unix.fork () in
              if child = 0 then (
                Native.For_test.run ~root:source ~remote:"team"
                  ~load_signing_capability:(fun _ -> Ok alice)
                  ~observe:(function
                    | Native.Courier_sent _ -> Unix._exit 73 | _ -> ())
                |> ignore;
                Unix._exit 74);
              let _, status = Unix.waitpid [] child in
              Alcotest.(check bool)
                "interrupted after actual HTTPS courier acceptance" true
                (status = Unix.WEXITED 73);
              let endpoint = Transport.sha256 url in
              let frozen () =
                Outbox.find
                  (Store.transport
                     (Option.get (load source_repository).Store.collaboration))
                  ~remote:"team" ~endpoint
                |> require_ok Transport.error_to_string
                |> Option.get
              in
              let pending = frozen () in
              let courier_id =
                Transport.publication_id (Outbox.publication pending)
              in
              Alcotest.(check bool)
                "local acknowledgement is still pending" false
                (Outbox.acknowledged pending);
              Transport_http.get client ~project
                ~kind:Transport_http.Publication ~id:courier_id
              |> require_ok Transport_http.error_to_string
              |> ignore;
              let source_key =
                Filename.concat signer_directory
                  (Model.Device_id.to_string (Trust.device_id (device alice)))
              in
              Unix.rename source_key (source_key ^ ".unavailable");
              let output, errors, status =
                run_cli
                  [ "exchange"; "--root"; source; "team"; "--format"; "json" ]
              in
              Unix.rename (source_key ^ ".unavailable") source_key;
              require_cli_success
                "fresh-process frozen courier retry without signer" errors
                status;
              let data = Yojson.Safe.from_string output |> member "data" in
              Alcotest.(check bool)
                "retry reports its actual acknowledgement" true
                (data |> member "outgoing" |> member "state"
               = `String "acknowledged");
              Alcotest.(check bool)
                "retry reuses exact signed identity" true
                (data |> member "outgoing" |> member "publication_id"
               = `String courier_id);
              let output, errors, status =
                run_cli [ "status"; "--root"; source; "--format"; "json" ]
              in
              require_cli_success
                "native status after actual relay acknowledgement" errors status;
              let rows =
                Yojson.Safe.from_string output
                |> member "data"
                |> member "local_publications"
                |> to_list
              in
              Alcotest.(check bool)
                "status reports the actual acknowledged publication" true
                (List.exists
                   (fun row ->
                     member "transfer_state" row = `String "acknowledged"
                     && member "acknowledged_remotes" row
                        = `List [ `String "team" ])
                   rows);
              Alcotest.(check string)
                "outbound retries do not capture or navigate private history"
                (History.encode before_send.Store.history |> require_ok Fun.id)
                (History.encode (load source_repository).Store.history
                |> require_ok Fun.id);
              let manifest =
                Package.Core.decode_manifest ~repository:scope
                  (Outbox.manifest pending)
                |> require_ok Package.error_to_string
              in
              Package.Core.inventory
                (Store.underlying_store source_repository)
                manifest
              |> require_ok Package.error_to_string
              |> List.iter (fun (id, _) ->
                  let bytes =
                    Transport_http.get client ~project
                      ~kind:Transport_http.Object
                      ~id:(Object_store.Stored_object_id.to_hex id)
                    |> require_ok Transport_http.error_to_string
                  in
                  Alcotest.(check bool)
                    "actual relay closure excludes Alice's unselected sentinel"
                    false (contains bytes sentinel));
              write (destination ^ "/bob-private.txt") "UNSAVED BOB PRIVATE E";
              let before_receive = load destination_repository in
              let output, errors, status =
                run_cli
                  [
                    "exchange";
                    "--root";
                    destination;
                    "team";
                    "--format";
                    "json";
                  ]
              in
              require_cli_success "native Bob receipt" errors status;
              Alcotest.(check bool)
                "receipt reports one new exact shared revision" true
                (Yojson.Safe.from_string output
                |> member "data" |> member "received_records" = `Int 1);
              let after_receive = load destination_repository in
              Alcotest.(check string)
                "receipt preserves exact private cursor and counter"
                (History.encode before_receive.Store.history
                |> require_ok Fun.id)
                (History.encode after_receive.Store.history |> require_ok Fun.id);
              Alcotest.(check bool)
                "receipt does not materialize selected shared files" false
                (Sys.file_exists (destination ^ "/main.ml"));
              Alcotest.(check string)
                "receipt leaves unsaved private bytes untouched"
                "UNSAVED BOB PRIVATE E"
                (read (destination ^ "/bob-private.txt"));
              let inbox =
                Transport.Core_inbox.receipts
                  (Store.transport
                     (Option.get after_receive.Store.collaboration))
              in
              Alcotest.(check int)
                "incoming and acknowledged outgoing couriers retain provenance"
                2 (List.length inbox);
              Alcotest.(check bool)
                "exact incoming courier remains identifiable" true
                (List.exists
                   (fun receipt ->
                     Transport.publication_id
                       (Transport.Core_inbox.publication receipt)
                     = courier_id)
                   inbox);
              let labels =
                Service.Core_receive.public_titles ~root:destination
                |> require_ok Service.Core_receive.error_to_string
              in
              Alcotest.(check bool)
                "shared display label retains original courier provenance" true
                (List.exists
                   (fun label ->
                     label.Service.Core_receive.title = "Selected D"
                     && label.Service.Core_receive.courier = courier_id)
                   labels);
              let output, errors, status =
                run_cli
                  [
                    "integrate";
                    "--root";
                    destination;
                    "--all";
                    "--yes";
                    "--format";
                    "json";
                  ]
              in
              require_cli_success "native Bob acceptance" errors status;
              Alcotest.(check bool)
                "integration returns a durable operation" true
                (Yojson.Safe.from_string output |> member "data" <> `Null);
              Alcotest.(check string)
                "CRLF selected contents materialize exactly"
                "let version = 2\r\n"
                (read (destination ^ "/main.ml"));
              Alcotest.(check string)
                "large binary bytes materialize exactly" binary
                (read (destination ^ "/asset.bin"));
              Alcotest.(check bool)
                "executable distinction survives relay and acceptance" true
                ((Unix.stat (destination ^ "/run.sh")).Unix.st_perm land 0o111
                <> 0);
              Alcotest.(check string)
                "symlink target survives relay and acceptance" "main.ml"
                (Unix.readlink (destination ^ "/link"));
              Alcotest.(check bool)
                "empty directory survives relay and acceptance" true
                ((Unix.lstat (destination ^ "/empty")).Unix.st_kind = Unix.S_DIR);
              Alcotest.(check string)
                "integration retains later private E" "UNSAVED BOB PRIVATE E"
                (read (destination ^ "/bob-private.txt"));
              let output, errors, status =
                run_cli [ "exchange"; "--root"; destination; "team" ]
              in
              require_cli_success "native Bob accepted-history exchange" errors
                status;
              expect_output_contains
                "plain exchange reports real acknowledgement"
                "outgoing: acknowledged" output;
              let bob_batch =
                Outbox.find
                  (Store.transport
                     (Option.get
                        (load destination_repository).Store.collaboration))
                  ~remote:"team" ~endpoint
                |> require_ok Transport.error_to_string
                |> Option.get
              in
              let bob_manifest =
                Package.Core.decode_manifest ~repository:scope
                  (Outbox.manifest bob_batch)
                |> require_ok Package.error_to_string
              in
              Package.Core.inventory
                (Store.underlying_store destination_repository)
                bob_manifest
              |> require_ok Package.error_to_string
              |> List.iter (fun (id, _) ->
                  let bytes =
                    Transport_http.get client ~project
                      ~kind:Transport_http.Object
                      ~id:(Object_store.Stored_object_id.to_hex id)
                    |> require_ok Transport_http.error_to_string
                  in
                  Alcotest.(check bool)
                    "actual accepted-history relay closure excludes Bob's \
                     private E"
                    false
                    (contains bytes "UNSAVED BOB PRIVATE E"));
              let alice_before_receipt = load source_repository in
              let output, errors, status =
                run_cli [ "exchange"; "--root"; source; "team" ]
              in
              require_cli_success "Alice receives Bob's accepted history" errors
                status;
              expect_output_contains "plain exchange reports verified coverage"
                "verified local shared closure" output;
              Alcotest.(check string)
                "accepted-history receipt leaves Alice's history untouched"
                (History.encode alice_before_receipt.Store.history
                |> require_ok Fun.id)
                (History.encode (load source_repository).Store.history
                |> require_ok Fun.id);
              Alcotest.(check string)
                "Alice's private sentinel survives accepted-history receipt"
                sentinel
                (read (source ^ "/private.txt"));
              Alcotest.(check bool)
                "Bob's private E is absent from Alice" false
                (Sys.file_exists (source ^ "/bob-private.txt")))))

let[@warning "-4-40-42"] native_missing_remote_objects_cannot_publish_private_cache_bytes
    () =
  let module Outbox = Transport.Core_outbox in
  let module History = Yeokcham_v1_undo in
  with_https_relay (fun client project url ->
      with_directory "yeokcham-native-private-cache-" (fun parent ->
          with_test_signer (fun signer_directory ->
              let ( source,
                    destination,
                    source_repository,
                    destination_repository,
                    alice,
                    _,
                    _ ) =
                native_core_replicas parent signer_directory
              in
              let secret =
                "PRIVATE CACHE CONTENT MUST NOT BE SUPPLIED TO A PEER BY HASH \
                 ALONE 870c9a"
              in
              let write path =
                Out_channel.with_open_bin path (fun out ->
                    output_string out secret)
              in
              write (destination ^ "/private.txt");
              Service.save ~root:destination
              |> require_ok Service.error_to_string
              |> ignore;
              write (source ^ "/public.txt");
              Service.share_selected ~root:source ~paths:[ [ "public.txt" ] ]
                ~update:None ~title:(Some "advertised missing contents")
                ~dry_run:false ~signing_capability:(Some alice)
              |> require_ok Service.error_to_string
              |> ignore;
              let blob =
                Yeokcham_snapshot.Content.store
                  (Store.underlying_store source_repository)
                  secret
                |> require_ok Yeokcham_snapshot.error_to_string
                |> Yeokcham_snapshot.Content.stored_object_id
              in
              Object_store.get
                (Store.underlying_store destination_repository)
                blob
              |> require_ok Object_store.error_to_string
              |> ignore;
              let outgoing =
                Service.Core_outbound.prepare ~root:source ~remote:"team"
                  ~endpoint:(Transport.sha256 url)
                  ~signing_capability:(Some alice)
                |> require_ok Service.Core_outbound.error_to_string
                |> Option.get
              in
              Fun.protect
                ~finally:(fun () ->
                  Package.dispose_artifact
                    outgoing.Service.Core_outbound.artifact)
                (fun () ->
                  Package.iter_artifact_objects
                    outgoing.Service.Core_outbound.artifact ~f:(fun id bytes ->
                      if Object_store.Stored_object_id.equal blob id then Ok ()
                      else (
                        Transport_http.put client ~project
                          ~kind:Transport_http.Object
                          ~id:(Object_store.Stored_object_id.to_hex id)
                          ~bytes
                        |> require_ok Transport_http.error_to_string;
                        Ok ()))
                  |> require_ok Package.error_to_string;
                  let batch = outgoing.Service.Core_outbound.batch in
                  Transport_http.put client ~project
                    ~kind:Transport_http.Manifest
                    ~id:(Transport.sha256 (Outbox.manifest batch))
                    ~bytes:(Outbox.manifest batch)
                  |> require_ok Transport_http.error_to_string;
                  let courier = Outbox.publication batch in
                  Transport_http.put client ~project
                    ~kind:Transport_http.Publication
                    ~id:(Transport.publication_id courier)
                    ~bytes:(Transport.encode_publication courier)
                  |> require_ok Transport_http.error_to_string);
              Transport_config.add ~root:destination ~name:"team" ~url
              |> require_ok Transport_config.error_to_string;
              let before =
                Store.load destination_repository
                |> require_ok Store.error_to_string
              in
              let output, _, status =
                run_cli
                  [
                    "exchange";
                    "--root";
                    destination;
                    "team";
                    "--format";
                    "json";
                  ]
              in
              Alcotest.(check bool)
                "missing peer contents are unavailable despite a private local \
                 hash match"
                true (status = Unix.WEXITED 5);
              let open Yojson.Safe.Util in
              Alcotest.(check bool)
                "missing remote object is reported explicitly" true
                (Yojson.Safe.from_string output
                |> member "error" |> member "code"
                = `String "exchange-unavailable");
              let after =
                Store.load destination_repository
                |> require_ok Store.error_to_string
              in
              Alcotest.(check bool)
                "unavailable incoming graph cannot publish a state root" true
                (Object_store.Mutable_ref.equal before.Store.head
                   after.Store.head);
              Alcotest.(check string)
                "private history/cursor/counter remain unchanged"
                (History.encode before.Store.history |> require_ok Fun.id)
                (History.encode after.Store.history |> require_ok Fun.id);
              Alcotest.(check string)
                "private working bytes survive" secret
                (In_channel.with_open_bin
                   (destination ^ "/private.txt")
                   In_channel.input_all);
              let remote =
                Transport_http.get client ~project ~kind:Transport_http.Object
                  ~id:(Object_store.Stored_object_id.to_hex blob)
              in
              Alcotest.(check bool)
                "automatic outbound work did not disclose private cached bytes"
                true
                (remote = Error (Transport_http.Unexpected_status 404)))))

let[@warning "-4-40-42"] native_clone_verifies_materializes_and_resumes () =
  let module Core = Model.Core in
  let module Local = Store.Local in
  let module Clone = Yeokcham_v1_sync.Clone in
  let module History = Yeokcham_v1_undo in
  let module Integrate = Service.Integrate in
  let load root =
    Store.open_repository ~root
    |> require_ok Store.error_to_string
    |> Store.load
    |> require_ok Store.error_to_string
  in
  let write path bytes =
    Out_channel.with_open_bin path (fun out -> output_string out bytes)
  in
  let read path = In_channel.with_open_bin path In_channel.input_all in
  let cli name arguments =
    let output, errors, status = run_cli arguments in
    require_cli_success name (errors ^ output) status;
    output
  in
  with_https_relay (fun _ project url ->
      with_directory "yeokcham-native-clone-" (fun parent ->
          with_test_signer (fun signer_directory ->
              let source_root, _, _, _, _, bob, scope =
                native_core_replicas parent signer_directory
              in
              Transport_config.add ~root:source_root ~name:"team" ~url
              |> require_ok Transport_config.error_to_string;
              write (source_root ^ "/main.ml") "let cloned = 2\r\n";
              let binary =
                String.init 300731 (fun i -> Char.chr (i * 11 mod 251))
              in
              write (source_root ^ "/asset.bin") binary;
              write (source_root ^ "/run.sh") "#!/bin/sh\nexit 0\n";
              Unix.chmod (source_root ^ "/run.sh") 0o700;
              Unix.symlink "main.ml" (source_root ^ "/link");
              Unix.mkdir (source_root ^ "/empty") 0o700;
              write (source_root ^ "/secret.txt") "UNSELECTED CLONE SENTINEL";
              let shared =
                cli "clone source share"
                  [
                    "share";
                    "--root";
                    source_root;
                    "main.ml";
                    "asset.bin";
                    "run.sh";
                    "link";
                    "empty";
                    "--format";
                    "json";
                  ]
              in
              let change_id =
                Yojson.Safe.Util.(
                  Yojson.Safe.from_string shared
                  |> member "data" |> member "change_id" |> to_string)
              in
              cli "clone source accepts D privately retaining E"
                [ "integrate"; "--root"; source_root; "--all"; "--yes" ]
              |> ignore;
              cli "clone source real HTTPS publication"
                [ "exchange"; "--root"; source_root; "team" ]
              |> ignore;
              let source_loaded = load source_root in
              let source_local = Option.get source_loaded.Store.local in
              let authority =
                Option.get
                  (Store.authority
                     (Option.get source_loaded.Store.collaboration))
              in
              let certificate =
                Trust.certificates (Trust.authority_membership authority)
                |> List.find (fun cert -> Trust.certificate_issuer cert = None)
              in
              let phrase =
                Yeokcham_v1_recovery.verification_phrase certificate
              in
              let device_id =
                Model.Device_id.to_string (Trust.device_id (device bob))
              in
              let clone_url = url ^ "/v1/repositories/" ^ project in
              let clone_source =
                Clone.source clone_url |> require_ok Clone.error_to_string
              in
              Alcotest.(check string)
                "URL pins exact repository"
                (Core.Repository_id.to_hex scope)
                (Core.Repository_id.to_hex clone_source.Clone.repository);
              let destination = parent ^ "/cloned" in
              let args destination phrase =
                [
                  "clone";
                  clone_url;
                  destination;
                  "--device";
                  device_id;
                  "--verify-phrase";
                  phrase;
                  "--format";
                  "json";
                ]
              in
              let _, _, status = run_cli (args destination "wrong phrase") in
              Alcotest.(check bool)
                "wrong root is blocked" true (status = Unix.WEXITED 7);
              Alcotest.(check bool)
                "wrong root creates no destination" false
                (Sys.file_exists destination);
              let outsider = capability 'z' in
              store_test_signer signer_directory outsider;
              let blocked =
                Clone.run ~source:clone_source ~destination ~branch:"main"
                  ~token:(relay_test_token ()) ~signing_capability:outsider
                  ~verify_phrase:phrase ~expected_request:None ~preview:false
              in
              Alcotest.(check bool)
                "bearer cannot enroll an unknown signer" true
                (match blocked with
                | Error (Clone.Blocked _) -> true
                | _ -> false);
              Alcotest.(check bool)
                "unenrolled clone creates no destination" false
                (Sys.file_exists destination);
              let open Yojson.Safe.Util in
              let preview =
                cli "verified clone preview"
                  (args destination phrase @ [ "--preview" ])
                |> Yojson.Safe.from_string |> member "data"
              in
              Alcotest.(check bool)
                "preview is read-only" false
                (Sys.file_exists destination);
              let request = preview |> member "request_id" |> to_string in
              let stale =
                Core.Digest.of_hex (String.make 64 '0')
                |> require_ok Core.error_to_string
              in
              Alcotest.(check bool)
                "different request cannot apply" true
                (match
                   Clone.run ~source:clone_source ~destination ~branch:"main"
                     ~token:(relay_test_token ()) ~signing_capability:bob
                     ~verify_phrase:phrase ~expected_request:(Some stale)
                     ~preview:false
                 with
                | Error (Clone.Choice _) -> true
                | _ -> false);
              let result =
                cli "native CLI clone"
                  (args destination phrase @ [ "--request"; request ])
                |> Yojson.Safe.from_string |> member "data"
              in
              Alcotest.(check bool)
                "clone reports verified closure" true
                (result |> member "coverage" |> member "verified_complete"
               = `Bool true);
              let verify_files root =
                Alcotest.(check string)
                  "CRLF clone" "let cloned = 2\r\n"
                  (read (root ^ "/main.ml"));
                Alcotest.(check string)
                  "streamed binary clone" binary
                  (read (root ^ "/asset.bin"));
                Alcotest.(check bool)
                  "executable clone" true
                  ((Unix.stat (root ^ "/run.sh")).Unix.st_perm land 0o111 <> 0);
                Alcotest.(check string)
                  "symlink clone" "main.ml"
                  (Unix.readlink (root ^ "/link"));
                Alcotest.(check bool)
                  "empty directory clone" true
                  ((Unix.lstat (root ^ "/empty")).Unix.st_kind = Unix.S_DIR);
                Alcotest.(check bool)
                  "source private sentinel absent" false
                  (Sys.file_exists (root ^ "/secret.txt"))
              in
              verify_files destination;
              let cloned = load destination in
              let local = Option.get cloned.Store.local in
              Alcotest.(check bool)
                "same accepted version, no new acceptance" true
                (Core.Record_id.equal (Local.selected source_local).Local.basis
                   (Local.selected local).Local.basis);
              Alcotest.(check bool)
                "public record map is exact" true
                (Local.record_objects source_local = Local.record_objects local);
              Alcotest.(check int)
                "one navigation after private empty genesis" 2
                (List.length (History.nodes cloned.Store.history));
              Alcotest.(check bool)
                "fresh workspace namespace" false
                (Core.Workspace_id.equal
                   (Option.get (History.workspace source_loaded.Store.history))
                   (Option.get (History.workspace cloned.Store.history)));
              let before =
                History.encode cloned.Store.history |> require_ok Fun.id
              in
              cli "completed clone resume" [ "clone"; "--resume"; destination ]
              |> ignore;
              Alcotest.(check string)
                "completed retry does not navigate" before
                (History.encode (load destination).Store.history
                |> require_ok Fun.id);
              cli "cloned origin exchange"
                [ "exchange"; "--root"; destination; "origin" ]
              |> ignore;
              let fault_points =
                [
                  ( "metadata",
                    (function Clone.After_metadata_attach -> true | _ -> false),
                    false );
                  ( "plan-before",
                    (function Clone.Before_plan_bind -> true | _ -> false),
                    false );
                  ( "plan-after",
                    (function Clone.After_plan_bind -> true | _ -> false),
                    false );
                  ( "prepared",
                    (function
                    | Clone.Application Integrate.Prepared_root -> true
                    | _ -> false),
                    false );
                  ( "applying",
                    (function
                    | Clone.Application Integrate.Applying_root -> true
                    | _ -> false),
                    false );
                  ( "file",
                    (function
                    | Clone.Application
                        (Integrate.Mutation
                           (Service.Safe_apply.After_mutation, _)) ->
                        true
                    | _ -> false),
                    false );
                  ( "materialized",
                    (function
                    | Clone.Application Integrate.Materialized_root -> true
                    | _ -> false),
                    true );
                  ( "committed",
                    (function
                    | Clone.Application Integrate.Committed_root -> true
                    | _ -> false),
                    false );
                  ( "completed",
                    (function
                    | Clone.Application Integrate.Completed_root -> true
                    | _ -> false),
                    false );
                  ( "intent-before",
                    (function Clone.Before_complete -> true | _ -> false),
                    false );
                  ( "intent-after",
                    (function Clone.After_complete -> true | _ -> false),
                    false );
                ]
              in
              List.iter
                (fun (label, stop, late_edit) ->
                  let target = parent ^ "/fault-" ^ label in
                  let child = Unix.fork () in
                  if child = 0 then (
                    let result =
                      Clone.For_test.run ~source:clone_source
                        ~destination:target ~branch:"main"
                        ~token:(relay_test_token ()) ~signing_capability:bob
                        ~verify_phrase:phrase ~expected_request:None
                        ~preview:false ~observe:(fun boundary ->
                          if stop boundary then Unix._exit 73)
                    in
                    (match result with
                    | Error error -> prerr_endline (Clone.error_to_string error)
                    | Ok _ -> ());
                    Unix._exit 74);
                  let _, status = Unix.waitpid [] child in
                  Alcotest.(check bool)
                    (label ^ " hits actual boundary")
                    true (status = Unix.WEXITED 73);
                  let partial = load target in
                  let partial_local = Option.get partial.Store.local in
                  let operations = Local.operations partial_local in
                  if label = "metadata" then (
                    let _, _, blocked =
                      run_cli [ "save"; "--root"; target; "--format"; "json" ]
                    in
                    Alcotest.(check bool)
                      "ordinary save cannot capture an incomplete clone" true
                      (blocked = Unix.WEXITED 8);
                    Alcotest.(check string)
                      "blocked save preserves partial history"
                      (History.encode partial.Store.history |> require_ok Fun.id)
                      (History.encode (load target).Store.history
                      |> require_ok Fun.id));
                  let key = Filename.concat signer_directory device_id in
                  Unix.rename key (key ^ ".hidden");
                  if late_edit then
                    write (target ^ "/main.ml")
                      "external edit after materialization\n";
                  Fun.protect
                    ~finally:(fun () -> Unix.rename (key ^ ".hidden") key)
                    (fun () ->
                      cli
                        (label ^ " resumes in fresh CLI without signer")
                        [ "clone"; "--resume"; target; "--format"; "json" ]
                      |> ignore);
                  let final = load target in
                  let final_local = Option.get final.Store.local in
                  Alcotest.(check int)
                    (label ^ " one operation") 1
                    (List.length (Local.operations final_local));
                  List.iter
                    (fun prior ->
                      Alcotest.(check bool)
                        (label ^ " same operation token")
                        true
                        (List.exists
                           (fun current ->
                             Core.Operation_id.equal prior.Local.Operation.token
                               current.Local.Operation.token)
                           (Local.operations final_local)))
                    operations;
                  Alcotest.(check int)
                    (label ^ " no partial capture/duplicate navigation")
                    2
                    (List.length (History.nodes final.Store.history));
                  Alcotest.(check bool)
                    (label ^ " no duplicate public history")
                    true
                    (Local.record_objects source_local
                    = Local.record_objects final_local);
                  if late_edit then
                    Alcotest.(check string)
                      "late external edit preserved"
                      "external edit after materialization\n"
                      (read (target ^ "/main.ml"))
                  else verify_files target;
                  let history =
                    History.encode final.Store.history |> require_ok Fun.id
                  in
                  cli
                    (label ^ " repeated resume")
                    [ "clone"; "--resume"; target ]
                  |> ignore;
                  Alcotest.(check string)
                    (label ^ " exact repeat") history
                    (History.encode (load target).Store.history
                    |> require_ok Fun.id))
                fault_points;
              write
                (destination ^ "/bob-private.txt")
                "Bob's compatible private E";
              write (source_root ^ "/main.ml") "let cloned = 3\r\n";
              cli "Alice updates exact shared change"
                [
                  "share";
                  "--root";
                  source_root;
                  "main.ml";
                  "--update";
                  change_id;
                ]
              |> ignore;
              cli "Alice exchanges new immutable revision"
                [ "exchange"; "--root"; source_root; "team" ]
              |> ignore;
              let before_receipt =
                History.encode (load destination).Store.history
                |> require_ok Fun.id
              in
              cli "cloned Bob receives update"
                [
                  "exchange";
                  "--root";
                  destination;
                  "origin";
                  "--format";
                  "json";
                ]
              |> ignore;
              Alcotest.(check string)
                "receipt preserves cloned private history" before_receipt
                (History.encode (load destination).Store.history
                |> require_ok Fun.id);
              Alcotest.(check string)
                "receipt leaves cloned working files" "let cloned = 2\r\n"
                (read (destination ^ "/main.ml"));
              cli "cloned Bob previews update"
                [
                  "integrate";
                  "--root";
                  destination;
                  "--all";
                  "--preview";
                  "--format";
                  "json";
                ]
              |> ignore;
              Alcotest.(check string)
                "preview leaves working files" "let cloned = 2\r\n"
                (read (destination ^ "/main.ml"));
              cli "cloned Bob accepts update"
                [ "integrate"; "--root"; destination; "--all"; "--yes" ]
              |> ignore;
              Alcotest.(check string)
                "updated CRLF contents" "let cloned = 3\r\n"
                (read (destination ^ "/main.ml"));
              Alcotest.(check string)
                "later E remains private" "Bob's compatible private E"
                (read (destination ^ "/bob-private.txt"));
              cli "cloned Bob exchanges accepted update"
                [ "exchange"; "--root"; destination; "origin" ]
              |> ignore)))

let[@warning "-4-40-42"] native_shared_branch_selection_and_nondefault_clone ()
    =
  let module Core = Model.Core in
  let module Local = Store.Local in
  let module History = Yeokcham_v1_undo in
  let load repository =
    Store.load repository |> require_ok Store.error_to_string
  in
  let cli label args =
    let output, errors, status = run_cli args in
    require_cli_success label (errors ^ output) status;
    output
  in
  let write path bytes =
    Out_channel.with_open_bin path (fun out -> output_string out bytes)
  in
  let read path = In_channel.with_open_bin path In_channel.input_all in
  with_https_relay (fun _ project url ->
      with_directory "yeokcham-native-shared-branches-" (fun parent ->
          with_test_signer (fun signer_directory ->
              let ( source,
                    destination,
                    source_repository,
                    destination_repository,
                    _,
                    bob,
                    _ ) =
                native_core_replicas parent signer_directory
              in
              List.iter
                (fun root ->
                  Transport_config.add ~root ~name:"team" ~url
                  |> require_ok Transport_config.error_to_string)
                [ source; destination ];
              write
                (source ^ "/alice-private.txt")
                "ALICE UNSHARED BRANCH SENTINEL";
              cli "Alice shares main file"
                [ "share"; "--root"; source; "main.ml" ]
              |> ignore;
              cli "Alice accepts shared main"
                [ "integrate"; "--root"; source; "--all"; "--yes" ]
              |> ignore;
              cli "Alice creates named shared branch"
                [ "branch"; "create"; "feature"; "--root"; source ]
              |> ignore;
              cli "Alice publishes both branches over real TLS"
                [ "exchange"; "--root"; source; "team" ]
              |> ignore;
              let sender = load source_repository in
              let sender_local = Option.get sender.Store.local in
              let feature =
                Local.branches sender_local
                |> List.find (fun branch ->
                    branch.Core.display_names = [ "feature" ])
              in
              let feature_basis = List.hd feature.Core.accepted_heads in
              write
                (destination ^ "/bob-private.txt")
                "BOB PRIVATE SOURCE ALTERNATIVE";
              let before = load destination_repository in
              cli "Bob receives named branch without moving files"
                [ "exchange"; "--root"; destination; "team" ]
              |> ignore;
              let received = load destination_repository in
              Alcotest.(check string)
                "TLS receipt does not allocate private history"
                (History.encode before.Store.history |> require_ok Fun.id)
                (History.encode received.Store.history |> require_ok Fun.id);
              Alcotest.(check bool)
                "received branch has no fabricated private position" false
                (List.exists
                   (fun position ->
                     Core.Branch_id.equal position.Local.branch
                       feature.Core.branch_id)
                   (Local.positions (Option.get received.Store.local)));
              let preview =
                cli "Bob previews first shared branch selection"
                  [
                    "switch";
                    "feature";
                    "--root";
                    destination;
                    "--preview";
                    "--format";
                    "json";
                  ]
              in
              let open Yojson.Safe.Util in
              let preview = Yojson.Safe.from_string preview in
              Alcotest.(check bool)
                "first target identity is marked provisional" true
                (preview |> member "data"
                |> member "target_history_provisional"
                = `Bool true);
              Alcotest.(check bool)
                "preview preserves source root" true
                (Object_store.Mutable_ref.equal received.Store.head
                   (load destination_repository).Store.head);
              let plan = preview |> member "plan_id" |> to_string in
              let bob_id =
                Model.Device_id.to_string (Trust.device_id (device bob))
              in
              let key = Filename.concat signer_directory bob_id in
              Unix.rename key (key ^ ".hidden");
              Fun.protect
                ~finally:(fun () -> Unix.rename (key ^ ".hidden") key)
                (fun () ->
                  cli "Bob selects received branch without signer"
                    [
                      "switch";
                      "feature";
                      "--root";
                      destination;
                      "--yes";
                      "--plan";
                      plan;
                      "--format";
                      "json";
                    ]
                  |> ignore;
                  let selected = load destination_repository in
                  let local = Option.get selected.Store.local in
                  Alcotest.(check bool)
                    "exact authenticated branch selected" true
                    (Core.Branch_id.equal feature.Core.branch_id
                       (Local.selected local).Local.branch);
                  Alcotest.(check bool)
                    "known accepted head reused" true
                    (Core.Record_id.equal feature_basis
                       (Local.selected local).Local.basis);
                  Alcotest.(check string)
                    "verified branch contents materialized" "let version = 1\n"
                    (read (destination ^ "/main.ml"));
                  Alcotest.(check bool)
                    "private source stays on its branch" false
                    (Sys.file_exists (destination ^ "/bob-private.txt"));
                  Alcotest.(check bool)
                    "selection creates no public records" true
                    (Local.record_objects sender_local
                    = Local.record_objects local);
                  let returned =
                    cli "Bob returns to saved main before catch-up"
                      [
                        "switch";
                        "main";
                        "--root";
                        destination;
                        "--yes";
                        "--format";
                        "json";
                      ]
                    |> Yojson.Safe.from_string |> member "data"
                  in
                  Alcotest.(check bool)
                    "saved main basis is distinct from its new shared head" true
                    (returned
                    |> member "known_accepted_heads"
                    <> `List [ member "target_working_basis" returned ]);
                  Alcotest.(check string)
                    "private source bytes restored across fresh processes"
                    "BOB PRIVATE SOURCE ALTERNATIVE"
                    (read (destination ^ "/bob-private.txt"));
                  cli
                    "Bob explicitly catches up shared main without new \
                     signature"
                    [ "integrate"; "--root"; destination; "--all"; "--yes" ]
                  |> ignore;
                  Alcotest.(check string)
                    "private continuation retained by explicit shared catch-up"
                    "BOB PRIVATE SOURCE ALTERNATIVE"
                    (read (destination ^ "/bob-private.txt")));
              cli "Bob exchanges after local branch selection"
                [ "exchange"; "--root"; destination; "team" ]
              |> ignore;
              let authority =
                Option.get
                  (Store.authority (Option.get sender.Store.collaboration))
              in
              let root_cert =
                Trust.certificates (Trust.authority_membership authority)
                |> List.find (fun cert -> Trust.certificate_issuer cert = None)
              in
              let phrase = Yeokcham_v1_recovery.verification_phrase root_cert in
              let cloned_root = parent ^ "/feature-clone" in
              cli "clone selects a nondefault authenticated branch"
                [
                  "clone";
                  url ^ "/v1/repositories/" ^ project;
                  cloned_root;
                  "--branch";
                  "feature";
                  "--device";
                  bob_id;
                  "--verify-phrase";
                  phrase;
                  "--format";
                  "json";
                ]
              |> ignore;
              let cloned_repository =
                Store.open_repository ~root:cloned_root
                |> require_ok Store.error_to_string
              in
              let cloned = load cloned_repository in
              let cloned_local = Option.get cloned.Store.local in
              Alcotest.(check bool)
                "nondefault clone retains branch identity" true
                (Core.Branch_id.equal feature.Core.branch_id
                   (Local.selected cloned_local).Local.branch);
              Alcotest.(check string)
                "nondefault clone materializes exact accepted bytes"
                "let version = 1\n"
                (read (cloned_root ^ "/main.ml"));
              Alcotest.(check bool)
                "Alice private work is not cloned" false
                (Sys.file_exists (cloned_root ^ "/alice-private.txt"));
              Alcotest.(check bool)
                "Bob private work is not cloned" false
                (Sys.file_exists (cloned_root ^ "/bob-private.txt"));
              Alcotest.(check bool)
                "clone has a new workspace namespace" false
                (Core.Workspace_id.equal
                   (Option.get
                      (History.workspace
                         (load destination_repository).Store.history))
                   (Option.get (History.workspace cloned.Store.history))))))

let[@warning "-4-40-42"] native_conflicts_resolve_and_preserve_private_work_through_tls
    () =
  let module Core = Model.Core in
  let module Local = Store.Local in
  let module History = Yeokcham_v1_undo in
  let module Outbox = Transport.Core_outbox in
  let open Yojson.Safe.Util in
  let load root =
    Store.open_repository ~root
    |> require_ok Store.error_to_string
    |> Store.load
    |> require_ok Store.error_to_string
  in
  let cli root label args =
    let output, errors, status =
      run_cli (args @ [ "--root"; root; "--format"; "json" ])
    in
    require_cli_success label (errors ^ output) status;
    let value = Yojson.Safe.from_string output in
    Alcotest.(check bool)
      (label ^ " uses domain JSON")
      true
      (member "schema_version" value = `Int 2);
    value
  in
  let write path bytes =
    Out_channel.with_open_bin path (fun out -> output_string out bytes)
  in
  let read path = In_channel.with_open_bin path In_channel.input_all in
  let history root =
    History.encode (load root).Store.history |> require_ok Fun.id
  in
  let same_root label before root =
    Alcotest.(check bool)
      label true
      (Object_store.Mutable_ref.equal before.Store.head (load root).Store.head)
  in
  with_https_relay (fun client project url ->
      with_directory "yeokcham-native-resolution-tls-" (fun parent ->
          with_test_signer (fun signer_directory ->
              let alice, _, _, _, _, bob_signer, scope =
                native_core_replicas parent signer_directory
              in
              Transport_config.add ~root:alice ~name:"team" ~url
              |> require_ok Transport_config.error_to_string;
              let alice_secret = "ALICE PRIVATE SENTINEL resolution 61a2" in
              let bob_secret = "BOB PRIVATE SENTINEL resolution 7d35" in
              let alice_e = "ALICE LATER PRIVATE E\r\n" in
              let bob_e = "BOB OVERLAPPING PRIVATE E\r\n" in
              write (alice ^ "/alice-private.txt") alice_secret;
              write (alice ^ "/main.ml") "base\r\n";
              let original =
                cli alice "Alice shares initial selected contents"
                  [ "share"; "main.ml" ]
                |> member "data"
              in
              let change = member "change_id" original |> to_string in
              cli alice "Alice accepts original shared version"
                [ "integrate"; change; "--yes" ]
              |> ignore;
              cli alice "Alice exchanges clone source" [ "exchange"; "team" ]
              |> ignore;
              let authority =
                Option.get
                  (Store.authority
                     (Option.get (load alice).Store.collaboration))
              in
              let root_certificate =
                Trust.certificates (Trust.authority_membership authority)
                |> List.find (fun cert -> Trust.certificate_issuer cert = None)
              in
              let phrase =
                Yeokcham_v1_recovery.verification_phrase root_certificate
              in
              let bob = parent ^ "/cloned-bob" in
              let bob_id =
                Model.Device_id.to_string (Trust.device_id (device bob_signer))
              in
              let output, errors, status =
                run_cli
                  [
                    "clone";
                    url ^ "/v1/repositories/" ^ project;
                    bob;
                    "--device";
                    bob_id;
                    "--verify-phrase";
                    phrase;
                    "--format";
                    "json";
                  ]
              in
              require_cli_success "Bob obtains a verified native clone"
                (errors ^ output) status;
              Alcotest.(check string)
                "clone materializes accepted CRLF" "base\r\n"
                (read (bob ^ "/main.ml"));
              Alcotest.(check bool)
                "clone excludes Alice's private sentinel" false
                (Sys.file_exists (bob ^ "/alice-private.txt"));
              write (bob ^ "/bob-private.txt") bob_secret;
              write (alice ^ "/main.ml") "Alice exact shared choice\r\n";
              let alice_revision =
                cli alice "Alice updates the original change"
                  [ "share"; "main.ml"; "--update"; change ]
                |> member "data" |> member "revision_id" |> to_string
              in
              write (bob ^ "/main.ml") "Bob concurrent shared choice\r\n";
              let bob_revision =
                cli bob "Bob independently updates the same change"
                  [ "share"; "main.ml"; "--update"; change ]
                |> member "data" |> member "revision_id" |> to_string
              in
              write (alice ^ "/asset.bin") "\000Alice opaque variant\255";
              cli alice "Alice shares an opaque variant"
                [ "share"; "asset.bin" ]
              |> ignore;
              write (bob ^ "/asset.bin") "\000Bob opaque variant\254";
              cli bob "Bob shares a distinct opaque variant"
                [ "share"; "asset.bin" ]
              |> ignore;
              write (alice ^ "/main.ml") alice_e;
              write (bob ^ "/main.ml") bob_e;
              cli bob "Bob exchanges concurrent publications"
                [ "exchange"; "origin" ]
              |> ignore;
              let alice_history = history alice in
              cli alice "Alice receives Bob's concurrent publications"
                [ "exchange"; "team" ]
              |> ignore;
              Alcotest.(check string)
                "receipt keeps Alice's private cursor and allocation"
                alice_history (history alice);
              Alcotest.(check string)
                "receipt keeps Alice's unsaved E" alice_e
                (read (alice ^ "/main.ml"));
              cli bob "Bob receives Alice's exact concurrent revision"
                [ "exchange"; "origin" ]
              |> ignore;
              let change_id =
                Core.Change_id.of_hex change |> require_ok Core.error_to_string
              in
              List.iter
                (fun root ->
                  let local = Option.get (load root).Store.local in
                  Alcotest.(check int)
                    "both causal change heads survive receipt" 2
                    (List.length
                       (Core.change_heads (Local.pool local) change_id)))
                [ alice; bob ];
              let before_resolution = load alice in
              let inspection =
                cli alice "Alice inspects named shared conflict versions"
                  [ "conflicts" ]
                |> member "data"
              in
              let shared =
                inspection |> member "conflicts" |> to_list
                |> List.find (fun row ->
                    member "path" row |> member "display" = `String "main.ml")
              in
              let conflict_id = member "conflict_id" shared |> to_string in
              let versions =
                member "versions" shared |> to_list
                |> List.map (fun row -> member "version_id" row |> to_string)
              in
              Alcotest.(check bool)
                "named versions include Alice and Bob exactly" true
                (List.mem ("revision:" ^ alice_revision) versions
                && List.mem ("revision:" ^ bob_revision) versions);
              cli alice "Alice safely defers the shared conflict"
                [ "resolve"; conflict_id; "--defer" ]
              |> ignore;
              same_root
                "inspection and deferral never move accepted/private state"
                before_resolution alice;
              let chosen =
                cli alice "Alice chooses the exact shared text version"
                  [
                    "resolve";
                    conflict_id;
                    "--use";
                    "revision:" ^ alice_revision;
                  ]
              in
              let plan_id = member "plan_id" chosen |> to_string in
              let inspection =
                cli alice "Alice inspects the remaining opaque decision"
                  [ "conflicts"; "--plan"; plan_id ]
                |> member "data"
              in
              let opaque =
                inspection |> member "conflicts" |> to_list
                |> List.find (fun row ->
                    member "path" row |> member "display" = `String "asset.bin")
              in
              let replacement = parent ^ "/combined.bin" in
              let opaque_bytes =
                String.init 16391 (fun i -> Char.chr (i * 17 mod 251))
              in
              write replacement opaque_bytes;
              Unix.chmod replacement 0o700;
              let chosen =
                cli alice
                  "Alice explicitly supplies exact opaque replacement contents"
                  [
                    "resolve";
                    member "conflict_id" opaque |> to_string;
                    "--file";
                    replacement;
                    "--plan";
                    plan_id;
                  ]
              in
              let plan_id = member "plan_id" chosen |> to_string in
              Alcotest.(check string)
                "resolution does not apply shared contents" alice_e
                (read (alice ^ "/main.ml"));
              Alcotest.(check string)
                "opaque resolution does not replace live file"
                "\000Alice opaque variant\255"
                (read (alice ^ "/asset.bin"));
              Alcotest.(check string)
                "resolution does not allocate private history" alice_history
                (history alice);
              let prepared = load alice in
              cli alice "Alice previews separate accepted/private results"
                [ "integrate"; "--plan"; plan_id; "--preview" ]
              |> ignore;
              let output, _, status =
                run_cli
                  [
                    "integrate";
                    "--root";
                    alice;
                    "--plan";
                    plan_id;
                    "--format";
                    "json";
                  ]
              in
              Alcotest.(check bool)
                "unconfirmed JSON acceptance requires an explicit choice" true
                (status = Unix.WEXITED 3);
              Alcotest.(check bool)
                "choice response identifies the exact plan" true
                (Yojson.Safe.from_string output
                |> member "plan_id" = `String plan_id);
              same_root
                "preview and unconfirmed application leave state unchanged"
                prepared alice;
              let accepted =
                cli alice "Alice explicitly accepts resolved shared work"
                  [ "integrate"; "--plan"; plan_id; "--yes" ]
              in
              let accepted_record =
                member "data" accepted |> member "operation"
                |> member "accepted_record" |> to_string
              in
              let accepted_snapshot =
                member "data" accepted |> member "accepted_snapshot"
              in
              Alcotest.(check string)
                "Alice's private E survives accepted shared D" alice_e
                (read (alice ^ "/main.ml"));
              Alcotest.(check string)
                "exact opaque choice materializes" opaque_bytes
                (read (alice ^ "/asset.bin"));
              Alcotest.(check bool)
                "replacement executable distinction survives" true
                ((Unix.stat (alice ^ "/asset.bin")).Unix.st_perm land 0o111 <> 0);
              cli alice
                "Alice exchanges authenticated resolution and acceptance"
                [ "exchange"; "team" ]
              |> ignore;
              let batch =
                Outbox.find
                  (Store.transport
                     (Option.get (load alice).Store.collaboration))
                  ~remote:"team" ~endpoint:(Transport.sha256 url)
                |> require_ok Transport.error_to_string
                |> Option.get
              in
              let manifest =
                Package.Core.decode_manifest ~repository:scope
                  (Outbox.manifest batch)
                |> require_ok Package.error_to_string
              in
              Package.Core.inventory
                (Store.underlying_store
                   (Store.open_repository ~root:alice
                   |> require_ok Store.error_to_string))
                manifest
              |> require_ok Package.error_to_string
              |> List.iter (fun (id, _) ->
                  let bytes =
                    Transport_http.get client ~project
                      ~kind:Transport_http.Object
                      ~id:(Object_store.Stored_object_id.to_hex id)
                    |> require_ok Transport_http.error_to_string
                  in
                  List.iter
                    (fun sentinel ->
                      Alcotest.(check bool)
                        "actual resolved relay closure excludes private bytes"
                        false (contains bytes sentinel))
                    [ alice_secret; bob_secret; alice_e; bob_e ];
                  let envelope =
                    Yeokcham_envelope.decode bytes
                    |> require_ok Yeokcham_envelope.decode_error_to_string
                  in
                  Alcotest.(check bool)
                    "private plans are absent from public relay closure" false
                    (Yeokcham_envelope.object_type envelope
                    = Yeokcham_envelope.Core_integration_plan));
              let bob_history = history bob in
              cli bob "Bob receives accepted resolved work without application"
                [ "exchange"; "origin" ]
              |> ignore;
              Alcotest.(check string)
                "resolved receipt preserves Bob's cursor and allocation"
                bob_history (history bob);
              Alcotest.(check string)
                "resolved receipt preserves Bob's unsaved E" bob_e
                (read (bob ^ "/main.ml"));
              let known = Option.get (load bob).Store.local in
              let known_accepted =
                Core.records (Local.pool known)
                |> List.filter_map (fun (id, body) ->
                    match body.Core.payload with
                    | Core.Accepted_version _ -> Some id
                    | _ -> None)
              in
              let inspection =
                cli bob "Bob inspects overlapping private conflict"
                  [ "conflicts" ]
                |> member "data"
              in
              let private_conflict =
                member "conflicts" inspection
                |> to_list
                |> List.find (fun row ->
                    member "private_workspace" row = `Bool true)
              in
              let key = Filename.concat signer_directory bob_id in
              Unix.rename key (key ^ ".hidden");
              Fun.protect
                ~finally:(fun () -> Unix.rename (key ^ ".hidden") key)
                (fun () ->
                  let chosen =
                    cli bob "Bob keeps private E without a signer"
                      [
                        "resolve";
                        member "conflict_id" private_conflict |> to_string;
                        "--use";
                        "working";
                      ]
                  in
                  Alcotest.(check bool)
                    "private resolution has no public record" true
                    (member "data" chosen |> member "public_resolution" = `Null);
                  let plan = member "plan_id" chosen |> to_string in
                  let ready = member "data" chosen |> member "plan" in
                  Alcotest.(check bool)
                    "Bob accepts Alice's exact shared result separately from E"
                    true
                    (member "accepted_snapshot" ready = accepted_snapshot);
                  let caught_up =
                    cli bob
                      "Bob selects already accepted work without another \
                       signature"
                      [ "integrate"; "--plan"; plan; "--yes" ]
                  in
                  Alcotest.(check string)
                    "known accepted identity reused" accepted_record
                    (member "data" caught_up |> member "operation"
                   |> member "accepted_record" |> to_string);
                  let committed = load bob in
                  cli bob
                    "Bob retries the exact confirmed plan without a signer"
                    [ "integrate"; "--plan"; plan; "--yes" ]
                  |> ignore;
                  same_root "retry adds no navigation or acceptance" committed
                    bob);
              let final_local = Option.get (load bob).Store.local in
              Alcotest.(check bool)
                "catch-up creates no additional accepted record" true
                (known_accepted
                = (Core.records (Local.pool final_local)
                  |> List.filter_map (fun (id, body) ->
                      match body.Core.payload with
                      | Core.Accepted_version _ -> Some id
                      | _ -> None)));
              Alcotest.(check string)
                "Bob retains private E after real resolved catch-up" bob_e
                (read (bob ^ "/main.ml"));
              Alcotest.(check string)
                "Bob materializes exact opaque replacement" opaque_bytes
                (read (bob ^ "/asset.bin"));
              Alcotest.(check string)
                "Bob retains private sentinel" bob_secret
                (read (bob ^ "/bob-private.txt"));
              Alcotest.(check bool)
                "Alice sentinel was never received as a working file" false
                (Sys.file_exists (bob ^ "/alice-private.txt"));
              let output, errors, status =
                run_cli [ "conflicts"; "--root"; bob ]
              in
              require_cli_success "plain conflict inspection after acceptance"
                errors status;
              expect_output_contains
                "plain inspection exposes honest ready state" "integration plan"
                output;
              cli bob "Bob exchanges after resolved catch-up"
                [ "exchange"; "origin" ]
              |> ignore)))

let[@warning "-4-40-42"] native_requested_branch_contents_precede_other_shared_data
    () =
  let module Core = Model.Core in
  let module Local = Store.Local in
  let module Clone = Yeokcham_v1_sync.Clone in
  let module Native = Yeokcham_v1_sync.Core in
  let module Composition = Yeokcham_v1_composition in
  let open Yojson.Safe.Util in
  let load root =
    Store.open_repository ~root
    |> require_ok Store.error_to_string
    |> Store.load
    |> require_ok Store.error_to_string
  in
  let cli root args =
    let output, errors, status =
      run_cli (args @ [ "--root"; root; "--format"; "json" ])
    in
    require_cli_success "requested-branch priority fixture CLI"
      (errors ^ output) status;
    Yojson.Safe.from_string output
  in
  let share_accept root text =
    Out_channel.with_open_bin (root ^ "/main.ml") (fun out ->
        output_string out text);
    let change =
      cli root [ "share"; "main.ml" ]
      |> member "data" |> member "change_id" |> to_string
    in
    cli root [ "integrate"; change; "--yes" ] |> ignore
  in
  let content root name =
    let local = Option.get (load root).Store.local in
    let branch =
      Local.branches local
      |> List.find (fun row -> List.mem name row.Core.display_names)
    in
    let accepted =
      Composition.Graph.accepted (Local.pool local)
        (List.hd branch.Core.accepted_heads)
      |> require_ok Composition.Graph.error_to_string
    in
    let repository =
      Store.open_repository ~root |> require_ok Store.error_to_string
    in
    let tree =
      Composition.load
        (Store.underlying_store repository)
        accepted.Core.result_snapshot
      |> require_ok Composition.error_to_string
    in
    match List.assoc [ "main.ml" ] (Composition.entries tree) with
    | Composition.File { content; _ } ->
        Yeokcham_snapshot.Content.stored_object_id content
    | Composition.Directory -> Alcotest.fail "expected requested file"
  in
  let before selected other requests =
    let index id =
      requests
      |> List.mapi (fun n value -> (n, value))
      |> List.find (fun (_, value) ->
          Object_store.Stored_object_id.equal id value)
      |> fst
    in
    Alcotest.(check bool)
      "selected branch content requested before other shared content" true
      (index selected < index other)
  in
  with_https_relay (fun _ project url ->
      with_directory "yeokcham-native-branch-priority-" (fun parent ->
          with_test_signer (fun signer_directory ->
              let alice, _, _, _, _, bob_signer, _ =
                native_core_replicas parent signer_directory
              in
              Transport_config.add ~root:alice ~name:"team" ~url
              |> require_ok Transport_config.error_to_string;
              share_accept alice "MAIN shared version one\r\n";
              cli alice [ "exchange"; "team" ] |> ignore;
              cli alice [ "branch"; "create"; "feature" ] |> ignore;
              cli alice [ "switch"; "feature"; "--yes" ] |> ignore;
              share_accept alice "FEATURE selected version one\r\n";
              cli alice [ "switch"; "main"; "--yes" ] |> ignore;
              cli alice [ "exchange"; "team" ] |> ignore;
              let authority =
                Option.get
                  (Store.authority
                     (Option.get (load alice).Store.collaboration))
              in
              let certificate =
                Trust.certificates (Trust.authority_membership authority)
                |> List.find (fun cert -> Trust.certificate_issuer cert = None)
              in
              let phrase =
                Yeokcham_v1_recovery.verification_phrase certificate
              in
              let bob = parent ^ "/selected-feature" in
              let requested = ref [] in
              let source =
                Clone.source (url ^ "/v1/repositories/" ^ project)
                |> require_ok Clone.error_to_string
              in
              Clone.For_test.run ~source ~destination:bob ~branch:"feature"
                ~token:(relay_test_token ()) ~signing_capability:bob_signer
                ~verify_phrase:phrase ~expected_request:None ~preview:false
                ~observe:(function
                | Clone.Object_requested id -> requested := id :: !requested
                | _ -> ())
              |> require_ok Clone.error_to_string
              |> ignore;
              before (content alice "feature") (content alice "main")
                (List.rev !requested);
              Alcotest.(check string)
                "clone materializes requested branch, not sender selection"
                "FEATURE selected version one\r\n"
                (In_channel.with_open_bin (bob ^ "/main.ml")
                   In_channel.input_all);
              share_accept alice "MAIN unselected version two\r\n";
              cli alice [ "exchange"; "team" ] |> ignore;
              cli alice [ "switch"; "feature"; "--yes" ] |> ignore;
              share_accept alice "FEATURE selected version two\r\n";
              cli alice [ "switch"; "main"; "--yes" ] |> ignore;
              cli alice [ "exchange"; "team" ] |> ignore;
              requested := [];
              let saved =
                (load bob).Store.history |> Yeokcham_v1_undo.encode
                |> require_ok Fun.id
              in
              Native.For_test.run ~root:bob ~remote:"origin"
                ~load_signing_capability:(fun _ -> Ok bob_signer)
                ~observe:(function
                  | Native.Object_requested id -> requested := id :: !requested
                  | _ -> ())
              |> require_ok Native.error_to_string
              |> ignore;
              before (content alice "feature") (content alice "main")
                (List.rev !requested);
              Alcotest.(check string)
                "prioritized receipt keeps current files"
                "FEATURE selected version one\r\n"
                (In_channel.with_open_bin (bob ^ "/main.ml")
                   In_channel.input_all);
              Alcotest.(check string)
                "prioritized receipt keeps private history/counter" saved
                ((load bob).Store.history |> Yeokcham_v1_undo.encode
               |> require_ok Fun.id);
              let other = content bob "main" in
              Alcotest.(check string)
                "unvisited branch contents are also completely downloaded"
                "MAIN unselected version two\r\n"
                (Yeokcham_snapshot.Content.load
                   (Store.underlying_store
                      (Store.open_repository ~root:bob
                      |> require_ok Store.error_to_string))
                   (Yeokcham_snapshot.Content.of_stored_object_id other)
                |> require_ok Yeokcham_snapshot.error_to_string))))

let[@warning "-4-40-42"] native_clone_reports_corrupt_remote_contents_as_integrity_failure
    () =
  let module Outbox = Transport.Core_outbox in
  let open Yojson.Safe.Util in
  List.iter
    (fun denied ->
      with_directory "yeokcham-native-corrupt-clone-" (fun parent ->
          with_test_signer (fun signer_directory ->
              let alice, _, source_repository, _, alice_signer, bob_signer, _ =
                native_core_replicas parent signer_directory
              in
              let bytes = "public corruption probe\r\n" in
              Out_channel.with_open_bin (alice ^ "/probe.txt") (fun out ->
                  output_string out bytes);
              Service.share_selected ~root:alice ~paths:[ [ "probe.txt" ] ]
                ~update:None ~title:None ~dry_run:false
                ~signing_capability:(Some alice_signer)
              |> require_ok Service.error_to_string
              |> ignore;
              let id =
                Yeokcham_snapshot.Content.store
                  (Store.underlying_store source_repository)
                  bytes
                |> require_ok Yeokcham_snapshot.error_to_string
                |> Yeokcham_snapshot.Content.stored_object_id
                |> Object_store.Stored_object_id.to_hex
              in
              let outgoing =
                Service.Core_outbound.prepare ~root:alice ~remote:"fixture"
                  ~endpoint:(Transport.sha256 "fixture")
                  ~signing_capability:(Some alice_signer)
                |> require_ok Service.Core_outbound.error_to_string
                |> Option.get
              in
              Fun.protect
                ~finally:(fun () ->
                  Package.dispose_artifact
                    outgoing.Service.Core_outbound.artifact)
                (fun () ->
                  let objects = Hashtbl.create 32 in
                  Package.iter_artifact_objects
                    outgoing.Service.Core_outbound.artifact
                    ~f:(fun object_id bytes ->
                      Hashtbl.add objects
                        (Object_store.Stored_object_id.to_hex object_id)
                        bytes;
                      Ok ())
                  |> require_ok Package.error_to_string;
                  let bad = Bytes.of_string (Hashtbl.find objects id) in
                  Bytes.set bad 25
                    (Char.chr (Char.code (Bytes.get bad 25) lxor 1));
                  Hashtbl.replace objects id (Bytes.to_string bad);
                  let batch = outgoing.Service.Core_outbound.batch in
                  let courier = Outbox.publication batch in
                  let courier_id = Transport.publication_id courier in
                  let manifest = Outbox.manifest batch in
                  let project = Trust.Repository_id.to_string (repository ()) in
                  let base = "/v1/repositories/" ^ project in
                  let page =
                    Encoding.array
                      [
                        Encoding.array
                          [ Encoding.text courier_id |> Result.get_ok ]
                        |> Result.get_ok;
                        Encoding.null;
                      ]
                    |> Result.get_ok |> Encoding.encode
                  in
                  let loaded =
                    Store.load source_repository
                    |> require_ok Store.error_to_string
                  in
                  let authority =
                    Option.get
                      (Store.authority (Option.get loaded.Store.collaboration))
                  in
                  let certificate =
                    Trust.certificates (Trust.authority_membership authority)
                    |> List.find (fun cert ->
                        Trust.certificate_issuer cert = None)
                  in
                  let phrase =
                    Yeokcham_v1_recovery.verification_phrase certificate
                  in
                  with_malicious_https_server
                    ~respond:(fun target ->
                      if
                        denied
                        && String.starts_with
                             ~prefix:
                               ("/v2/repositories/" ^ project ^ "/objects/")
                             target
                      then (401, "")
                      else if
                        String.starts_with ~prefix:(base ^ "/publications?")
                          target
                      then (200, page)
                      else if target = base ^ "/publications/" ^ courier_id then
                        (200, Transport.encode_publication courier)
                      else if
                        target
                        = base ^ "/manifests/" ^ Transport.sha256 manifest
                      then (200, manifest)
                      else if
                        String.starts_with ~prefix:(base ^ "/objects/") target
                      then
                        let name =
                          String.sub target
                            (String.length base + 9)
                            (String.length target - String.length base - 9)
                        in
                        match Hashtbl.find_opt objects name with
                        | Some bytes -> (200, bytes)
                        | None -> (404, "")
                      else (404, ""))
                    (fun ~requests url ->
                      let destination = parent ^ "/refused-clone" in
                      let output, errors, status =
                        run_cli
                          [
                            "clone";
                            url ^ "/v1/repositories/" ^ project;
                            destination;
                            "--device";
                            Model.Device_id.to_string
                              (Trust.device_id (device bob_signer));
                            "--verify-phrase";
                            phrase;
                            "--format";
                            "json";
                          ]
                      in
                      let expected = if denied then 7 else 6 in
                      if status <> Unix.WEXITED expected then
                        Alcotest.failf
                          "native clone expected exit%d: %s %s; routes: %s"
                          expected output errors
                          (In_channel.with_open_bin requests
                             In_channel.input_all);
                      Alcotest.(check bool)
                        "corruption has structured domain output" true
                        (Yojson.Safe.from_string output
                        |> member "schema_version" = `Int 2);
                      Alcotest.(check string)
                        "integrity/access refusal is distinct from missing \
                         peer data"
                        (if denied then "exchange-access-blocked"
                         else "exchange-integrity-failure")
                        (Yojson.Safe.from_string output
                        |> member "error" |> member "code" |> to_string);
                      Alcotest.(check bool)
                        "refused peer cannot create a workspace" false
                        (Sys.file_exists destination))))))
    [ false; true ]

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
          Alcotest.test_case
            "Core outbound controls are canonical and monotonic" `Quick
            core_outbox_canonical_and_monotonic;
          Alcotest.test_case
            "clone controls and credential realms are canonical and frozen"
            `Quick clone_controls_are_canonical_and_frozen;
          Alcotest.test_case
            "foreground courier inventory has an aggregate metadata bound"
            `Quick
            bounded_courier_batches_stop_before_accumulating_the_inventory;
        ] );
      ( "relay",
        [
          Alcotest.test_case
            "native clone reports corrupt remote contents as integrity failure"
            `Slow
            native_clone_reports_corrupt_remote_contents_as_integrity_failure;
          Alcotest.test_case
            "clone and exchange prioritize the requested branch over sender \
             selection"
            `Slow native_requested_branch_contents_precede_other_shared_data;
          Alcotest.test_case
            "native text/opaque resolution and private catch-up work through \
             TLS CLI"
            `Slow native_conflicts_resolve_and_preserve_private_work_through_tls;
          Alcotest.test_case
            "received shared branches and nondefault clone work through TLS CLI"
            `Slow native_shared_branch_selection_and_nondefault_clone;
          Alcotest.test_case
            "native clone verifies contents and resumes real application \
             boundaries"
            `Slow native_clone_verifies_materializes_and_resumes;
          Alcotest.test_case
            "native Core exchange preserves privacy and exact retry through TLS"
            `Slow native_core_exchange_uses_enrolled_replicas_and_exact_retry;
          Alcotest.test_case
            "missing native objects cannot expose private cached bytes" `Slow
            native_missing_remote_objects_cannot_publish_private_cache_bytes;
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
