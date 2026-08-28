module Golden = Yeokcham_testkit.Golden_fixture
module Model = Yeokcham_v4_model
module Trust = Yeokcham_v4_trust
module Transport = Yeokcham_v4_transport
module Relay = Yeokcham_v4_relay

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
        ] );
    ]
