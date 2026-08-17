module Peer_sync = Yeokcham_peer_sync
module Relay = Yeokcham_peer_sync_relay
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Golden = Yeokcham_testkit.Golden_fixture
module Hash = Yeokcham_hash.Sha256

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let with_directory prefix run =
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  let rec remove path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> run root)

let identity byte =
  let private_key =
    Mirage_crypto_ec.Ed25519.priv_of_octets (String.make 32 byte)
    |> require_ok (Format.asprintf "%a" Mirage_crypto_ec.pp_error)
  in
  let public_key =
    Mirage_crypto_ec.Ed25519.pub_of_priv private_key
    |> Mirage_crypto_ec.Ed25519.pub_to_octets
  in
  let identity =
    Peer_sync.make_identity ~public_key |> require_ok Peer_sync.error_to_string
  in
  (identity, private_key)

let store_identity store identity =
  ignore
    (Peer_sync.store_identity store identity
    |> require_ok Peer_sync.error_to_string)

let snapshot store =
  let content =
    Snapshot.Content.store store "relay peer-sync\n"
    |> require_ok Snapshot.error_to_string
  in
  let tree =
    Snapshot.Tree.create
      [ ("tracked", Snapshot.Tree.File { mode = Snapshot.Regular; content }) ]
    |> require_ok Snapshot.error_to_string
  in
  let root =
    Snapshot.Tree.store store tree |> require_ok Snapshot.error_to_string
  in
  Snapshot.Snapshot.create ~root
  |> Snapshot.Snapshot.store store
  |> require_ok Snapshot.error_to_string

let hex_of_bytes bytes =
  let digits = "0123456789abcdef" in
  let output = Bytes.create (2 * String.length bytes) in
  String.iteri
    (fun index value ->
      Bytes.set output (2 * index) digits.[Char.code value lsr 4];
      Bytes.set output ((2 * index) + 1) digits.[Char.code value land 15])
    bytes;
  Bytes.unsafe_to_string output

let now = 1_700_000_000L
let expiry = Int64.add now 600L

let with_repositories run =
  with_directory "yeokcham-peer-relay-source-" (fun source_root ->
      with_directory "yeokcham-peer-relay-destination-" (fun destination_root ->
          with_directory "yeokcham-peer-relay-mailbox-" (fun relay ->
              let source =
                Store.init ~root:source_root |> require_ok Store.error_to_string
              in
              let destination =
                Store.init ~root:destination_root
                |> require_ok Store.error_to_string
              in
              let alice, alice_private = identity 'a' in
              let bob, _ = identity 'b' in
              store_identity source alice;
              store_identity destination bob;
              let contact =
                Peer_sync.make_contact ~name:"alice" ~identity:alice
                  ~endpoints:[ Peer_sync.Relay relay ]
                |> require_ok Peer_sync.error_to_string
              in
              ignore
                (Peer_sync.store_contact destination contact
                |> require_ok Peer_sync.error_to_string);
              let head =
                Peer_sync.make_sync_node ~author:alice
                  ~private_key:alice_private ~snapshot:(snapshot source)
                  ~parents:[]
                |> require_ok Peer_sync.error_to_string
              in
              ignore
                (Peer_sync.store_sync_node source head
                |> require_ok Peer_sync.error_to_string);
              run ~source ~destination ~relay ~alice ~alice_private ~bob
                ~contact ~head)))

let make_publication ~source ~alice ~alice_private ~bob ~head =
  let package =
    Relay.make_package ~source ~source_identity:alice
      ~source_private_key:alice_private ~destination:bob ~tracking_name:"main"
      ~head:(Peer_sync.sync_node_id head)
      ~issued_at:now ~expires_at:expiry
      ~nonce:(String.make Peer_sync.nonce_bytes 'n')
    |> require_ok Relay.error_to_string
  in
  let advertisement =
    Relay.make_advertisement package ~private_key:alice_private
    |> require_ok Relay.error_to_string
  in
  (package, advertisement)

let published relay package advertisement =
  Relay.publish ~relay ~package ~advertisement
  |> require_ok Relay.error_to_string

let tracking destination contact =
  Peer_sync.tracking_head destination ~contact ~name:"main"
  |> require_ok Peer_sync.error_to_string
  |> Option.map Yeokcham_id.Peer_sync_node_id.to_hex

let replace_once source ~pattern ~replacement =
  if String.length pattern <> String.length replacement then None
  else
    let limit = String.length source - String.length pattern in
    let rec find offset =
      if offset > limit then None
      else if
        String.equal (String.sub source offset (String.length pattern)) pattern
      then
        Some
          (String.sub source 0 offset ^ replacement
          ^ String.sub source
              (offset + String.length pattern)
              (String.length source - offset - String.length pattern))
      else find (offset + 1)
    in
    find 0

let discovery_is_untrusted_and_retry_is_idempotent () =
  with_repositories
    (fun
      ~source ~destination ~relay ~alice ~alice_private ~bob ~contact ~head ->
      let package, advertisement =
        make_publication ~source ~alice ~alice_private ~bob ~head
      in
      let before =
        Store.list_objects destination |> require_ok Store.error_to_string
      in
      published relay package advertisement;
      published relay package advertisement;
      let advertisements =
        Relay.list_advertisements ~relay ~now
        |> require_ok Relay.error_to_string
      in
      Alcotest.(check int)
        "one retry-idempotent advertisement" 1
        (List.length advertisements);
      Alcotest.(check string)
        "advertisement package ID" (Relay.package_id package)
        (Relay.advertisement_package_id (List.hd advertisements));
      let after =
        Store.list_objects destination |> require_ok Store.error_to_string
      in
      Alcotest.(check int)
        "discovery writes no canonical objects" (List.length before)
        (List.length after);
      Alcotest.(check (option string))
        "discovery does not advance tracking" None
        (tracking destination contact))

let import_replay_and_tracking_isolation () =
  with_repositories
    (fun
      ~source ~destination ~relay ~alice ~alice_private ~bob ~contact ~head ->
      let package, advertisement =
        make_publication ~source ~alice ~alice_private ~bob ~head
      in
      published relay package advertisement;
      let advertisement =
        Relay.list_advertisements ~relay ~now
        |> require_ok Relay.error_to_string
        |> List.hd
      in
      let decision =
        Relay.import_advertisement ~destination ~contact
          ~destination_identity:bob ~relay ~tracking_name:"main" ~now
          ~advertisement
        |> require_ok Relay.error_to_string
      in
      (match decision with
      | Peer_sync.Tracking_advanced node ->
          Alcotest.(check string)
            "tracking head"
            (Yeokcham_id.Peer_sync_node_id.to_hex (Peer_sync.sync_node_id head))
            (Yeokcham_id.Peer_sync_node_id.to_hex (Peer_sync.sync_node_id node))
      | Peer_sync.Tracking_already_current _ | Peer_sync.Tracking_diverged _ ->
          Alcotest.fail "first relay import did not advance tracking");
      Alcotest.(check (option string))
        "tracking advanced exactly once"
        (Some
           (Yeokcham_id.Peer_sync_node_id.to_hex (Peer_sync.sync_node_id head)))
        (tracking destination contact);
      Alcotest.(check bool)
        "replay is rejected" true
        (Relay.import_advertisement ~destination ~contact
           ~destination_identity:bob ~relay ~tracking_name:"main" ~now
           ~advertisement
        |> Result.fold ~ok:(fun _ -> false) ~error:Relay.is_replay_error))

let corrupt_wrong_format_and_untrusted_entries_preserve_tracking () =
  with_repositories
    (fun
      ~source ~destination ~relay ~alice ~alice_private ~bob ~contact ~head ->
      let package, advertisement =
        make_publication ~source ~alice ~alice_private ~bob ~head
      in
      published relay package advertisement;
      let mailbox =
        Filename.concat
          (Filename.concat relay "mailboxes")
          (hex_of_bytes (Peer_sync.peer_id bob |> Yeokcham_id.Peer_id.to_bytes))
      in
      let package_path =
        Filename.concat mailbox
          (hex_of_bytes (Relay.package_id package) ^ ".package")
      in
      let descriptor =
        Unix.openfile package_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0
      in
      ignore (Unix.write_substring descriptor "corrupt" 0 7);
      Unix.close descriptor;
      let advertised =
        Relay.list_advertisements ~relay ~now
        |> require_ok Relay.error_to_string
        |> List.hd
      in
      Alcotest.(check bool)
        "corrupt package rejects before import" true
        (Result.is_error
           (Relay.import_advertisement ~destination ~contact
              ~destination_identity:bob ~relay ~tracking_name:"main" ~now
              ~advertisement:advertised));
      Alcotest.(check (option string))
        "corruption preserves tracking" None
        (tracking destination contact);
      let wrong_format_package =
        Relay.make_package ~source ~source_identity:alice
          ~source_private_key:alice_private ~destination:bob
          ~tracking_name:"main"
          ~head:(Peer_sync.sync_node_id head)
          ~issued_at:now ~expires_at:expiry
          ~nonce:(String.make Peer_sync.nonce_bytes 'f')
        |> require_ok Relay.error_to_string
      in
      let wrong_format_advertisement =
        Relay.make_advertisement wrong_format_package ~private_key:alice_private
        |> require_ok Relay.error_to_string
      in
      published relay wrong_format_package wrong_format_advertisement;
      let wrong_format_path =
        Filename.concat mailbox
          (hex_of_bytes (Relay.package_id wrong_format_package) ^ ".package")
      in
      let wrong_format_bytes =
        Relay.package_payload wrong_format_package
        |> require_ok Relay.error_to_string
        |> Yeokcham_encoding.encode
        |> replace_once
             ~pattern:
               (Hash.digest_string Store.repository_format |> Hash.to_raw_string)
             ~replacement:(String.make 32 'x')
        |> Option.get
      in
      let descriptor =
        Unix.openfile wrong_format_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0
      in
      ignore
        (Unix.write_substring descriptor wrong_format_bytes 0
           (String.length wrong_format_bytes));
      Unix.close descriptor;
      let wrong_format =
        Relay.list_advertisements ~relay ~now
        |> require_ok Relay.error_to_string
        |> List.find (fun advertisement ->
            String.equal
              (Relay.advertisement_package_id advertisement)
              (Relay.package_id wrong_format_package))
      in
      Alcotest.(check bool)
        "wrong repository package rejects before import" true
        (Result.is_error
           (Relay.import_advertisement ~destination ~contact
              ~destination_identity:bob ~relay ~tracking_name:"main" ~now
              ~advertisement:wrong_format));
      let eve, eve_private = identity 'e' in
      store_identity source eve;
      let eve_head =
        Peer_sync.make_sync_node ~author:eve ~private_key:eve_private
          ~snapshot:(snapshot source) ~parents:[]
        |> require_ok Peer_sync.error_to_string
      in
      ignore
        (Peer_sync.store_sync_node source eve_head
        |> require_ok Peer_sync.error_to_string);
      let untrusted =
        Relay.make_package ~source ~source_identity:eve
          ~source_private_key:eve_private ~destination:bob ~tracking_name:"main"
          ~head:(Peer_sync.sync_node_id eve_head)
          ~issued_at:now ~expires_at:expiry
          ~nonce:(String.make Peer_sync.nonce_bytes 'u')
        |> require_ok Relay.error_to_string
      in
      let untrusted_advertisement =
        Relay.make_advertisement untrusted ~private_key:eve_private
        |> require_ok Relay.error_to_string
      in
      published relay untrusted untrusted_advertisement;
      Alcotest.(check bool)
        "untrusted signed package is rejected" true
        (Result.is_error
           (Relay.import_advertisement ~destination ~contact
              ~destination_identity:bob ~relay ~tracking_name:"main" ~now
              ~advertisement:untrusted_advertisement));
      Alcotest.(check (option string))
        "untrusted entries preserve tracking" None
        (tracking destination contact))

let incomplete_files_are_not_discoverable () =
  with_repositories
    (fun
      ~source:_
      ~destination
      ~relay
      ~alice:_
      ~alice_private:_
      ~bob
      ~contact
      ~head:_
    ->
      let mailbox =
        Filename.concat
          (Filename.concat relay "mailboxes")
          (hex_of_bytes (Peer_sync.peer_id bob |> Yeokcham_id.Peer_id.to_bytes))
      in
      Unix.mkdir (Filename.concat relay "mailboxes") 0o755;
      Unix.mkdir mailbox 0o755;
      let path = Filename.concat mailbox (String.make 64 '0' ^ ".package") in
      let descriptor =
        Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o644
      in
      ignore (Unix.write_substring descriptor "partial" 0 7);
      Unix.close descriptor;
      let advertisements =
        Relay.list_advertisements ~relay ~now
        |> require_ok Relay.error_to_string
      in
      Alcotest.(check int)
        "package without an atomic advertisement is invisible" 0
        (List.length advertisements);
      Alcotest.(check (option string))
        "incomplete publication preserves tracking" None
        (tracking destination contact))

let package_and_advertisement_goldens_are_canonical () =
  let read path = Golden.read_lower_hex_file path |> require_ok Fun.id in
  let decode bytes =
    Yeokcham_encoding.decode bytes
    |> require_ok Yeokcham_encoding.decode_error_to_string
  in
  let package_bytes = read "golden/peer-sync-relay-v1.package.hex" in
  let package =
    decode package_bytes |> Relay.decode_package_payload
    |> require_ok Relay.error_to_string
  in
  let package_reencoded =
    Relay.package_payload package
    |> require_ok Relay.error_to_string
    |> Yeokcham_encoding.encode
  in
  Alcotest.(check string)
    "package golden is canonical" package_bytes package_reencoded;
  let advertisement_bytes =
    read "golden/peer-sync-relay-v1.advertisement.hex"
  in
  let advertisement =
    decode advertisement_bytes |> Relay.decode_advertisement_payload
    |> require_ok Relay.error_to_string
  in
  let advertisement_reencoded =
    Relay.advertisement_payload advertisement
    |> require_ok Relay.error_to_string
    |> Yeokcham_encoding.encode
  in
  Alcotest.(check string)
    "advertisement golden is canonical" advertisement_bytes
    advertisement_reencoded;
  let unsupported = Bytes.of_string package_bytes in
  Bytes.set unsupported 1 '\002';
  Alcotest.(check bool)
    "unknown package version rejects" true
    (match Yeokcham_encoding.decode (Bytes.unsafe_to_string unsupported) with
    | Error _ -> false
    | Ok value -> Result.is_error (Relay.decode_package_payload value));
  let unsupported = Bytes.of_string advertisement_bytes in
  Bytes.set unsupported 1 '\002';
  Alcotest.(check bool)
    "unknown advertisement version rejects" true
    (match Yeokcham_encoding.decode (Bytes.unsafe_to_string unsupported) with
    | Error _ -> false
    | Ok value -> Result.is_error (Relay.decode_advertisement_payload value))

let () =
  Alcotest.run "peer sync relay"
    [
      ( "mailbox",
        [
          Alcotest.test_case
            "discovery is untrusted and publish retry is idempotent" `Quick
            discovery_is_untrusted_and_retry_is_idempotent;
          Alcotest.test_case "import rejects replay and advances only tracking"
            `Quick import_replay_and_tracking_isolation;
          Alcotest.test_case "corrupt and untrusted entries preserve tracking"
            `Quick corrupt_wrong_format_and_untrusted_entries_preserve_tracking;
          Alcotest.test_case "incomplete files are not discoverable" `Quick
            incomplete_files_are_not_discoverable;
          Alcotest.test_case "package and advertisement golden fixtures" `Quick
            package_and_advertisement_goldens_are_canonical;
        ] );
    ]
