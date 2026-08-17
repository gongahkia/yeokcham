module Daemon = Yeokcham_peer_sync_daemon
module Local_daemon = Yeokcham_local_daemon
module Peer_sync = Yeokcham_peer_sync
module Relay = Yeokcham_peer_sync_relay
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Sys.readdir path
      |> Array.iter (fun name -> remove (Filename.concat path name));
      Unix.rmdir path
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
  | Unix.S_SOCK ->
      Unix.unlink path

let with_directory prefix run =
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
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
  ( Peer_sync.make_identity ~public_key |> require_ok Peer_sync.error_to_string,
    private_key )

let write_private_key path private_key =
  let descriptor =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
  in
  Fun.protect
    ~finally:(fun () -> Unix.close descriptor)
    (fun () ->
      let bytes = Mirage_crypto_ec.Ed25519.priv_to_octets private_key in
      ignore (Unix.write_substring descriptor bytes 0 (String.length bytes)))

let snapshot store =
  let content =
    Snapshot.Content.store store "daemon peer-sync\n"
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

let with_repositories run =
  with_directory "yeokcham-peer-daemon-" (fun parent ->
      let source_root = Filename.concat parent "source"
      and destination_root = Filename.concat parent "destination"
      and runtime = Filename.concat parent "runtime"
      and relay = Filename.concat parent "relay" in
      Unix.mkdir source_root 0o700;
      Unix.mkdir destination_root 0o700;
      Unix.mkdir runtime 0o700;
      Unix.mkdir relay 0o700;
      let source =
        Store.init ~root:source_root |> require_ok Store.error_to_string
      in
      let destination =
        Store.init ~root:destination_root |> require_ok Store.error_to_string
      in
      let alice, alice_private = identity 'a' in
      let bob, _ = identity 'b' in
      ignore
        (Peer_sync.store_identity source alice
        |> require_ok Peer_sync.error_to_string);
      ignore
        (Peer_sync.store_identity destination bob
        |> require_ok Peer_sync.error_to_string);
      let local_contact =
        Peer_sync.make_contact ~name:"alice-local" ~identity:alice
          ~endpoints:[ Peer_sync.Local_path source_root ]
        |> require_ok Peer_sync.error_to_string
      in
      let relay_contact =
        Peer_sync.make_contact ~name:"alice-relay" ~identity:alice
          ~endpoints:[ Peer_sync.Relay relay ]
        |> require_ok Peer_sync.error_to_string
      in
      ignore
        (Peer_sync.store_contact destination local_contact
        |> require_ok Peer_sync.error_to_string);
      ignore
        (Peer_sync.store_contact destination relay_contact
        |> require_ok Peer_sync.error_to_string);
      let head =
        Peer_sync.make_sync_node ~author:alice ~private_key:alice_private
          ~snapshot:(snapshot source) ~parents:[]
        |> require_ok Peer_sync.error_to_string
      in
      ignore
        (Peer_sync.store_sync_node source head
        |> require_ok Peer_sync.error_to_string);
      let source_key = Filename.concat parent "alice.key" in
      write_private_key source_key alice_private;
      run ~source ~destination ~source_root ~destination_root ~runtime ~relay
        ~alice ~alice_private ~bob ~local_contact ~relay_contact ~head
        ~source_key)

let tracking destination contact =
  Peer_sync.tracking_head destination ~contact ~name:"main"
  |> require_ok Peer_sync.error_to_string
  |> Option.map Yeokcham_id.Peer_sync_node_id.to_hex

let direct_poll_advances_only_peer_tracking () =
  with_repositories
    (fun
      ~source:_
      ~destination
      ~source_root
      ~destination_root
      ~runtime
      ~relay:_
      ~alice:_
      ~alice_private:_
      ~bob
      ~local_contact
      ~relay_contact
      ~head
      ~source_key
    ->
      let configuration =
        Daemon.make_configuration ~root:destination_root ~runtime_dir:runtime
          ~contact:(Peer_sync.contact_id local_contact)
          ~identity:(Peer_sync.peer_id bob) ~tracking_name:"main"
          ~transport:
            (Daemon.Local
               { source_root; source_key; head = Peer_sync.sync_node_id head })
        |> require_ok Daemon.error_to_string
      in
      let daemon =
        Daemon.start configuration |> require_ok Daemon.error_to_string
      in
      Fun.protect
        ~finally:(fun () -> Daemon.close daemon)
        (fun () ->
          let result =
            Daemon.poll_once daemon |> require_ok Daemon.error_to_string
          in
          Alcotest.(check bool)
            "direct poll advanced tracking" true
            (result = Daemon.Tracking_advanced);
          Alcotest.(check (option string))
            "only local contact tracking advanced"
            (Some
               (Yeokcham_id.Peer_sync_node_id.to_hex
                  (Peer_sync.sync_node_id head)))
            (tracking destination local_contact);
          Alcotest.(check (option string))
            "relay tracking remains absent" None
            (tracking destination relay_contact);
          let status =
            Daemon.read_status ~root:destination_root ~runtime_dir:runtime
            |> require_ok Daemon.error_to_string
          in
          Alcotest.(check bool)
            "runtime-only status reports result" true
            (Daemon.status_kind status = Daemon.Tracking_advanced)))

let relay_poll_imports_configured_contact () =
  with_repositories
    (fun
      ~source
      ~destination
      ~source_root:_
      ~destination_root
      ~runtime
      ~relay
      ~alice
      ~alice_private
      ~bob
      ~local_contact
      ~relay_contact
      ~head
      ~source_key:_
    ->
      let package =
        let issued_at = Int64.of_float (Unix.gettimeofday ()) in
        Relay.make_package ~source ~source_identity:alice
          ~source_private_key:alice_private ~destination:bob
          ~tracking_name:"main"
          ~head:(Peer_sync.sync_node_id head)
          ~issued_at ~expires_at:(Int64.add issued_at 600L)
          ~nonce:(String.make Peer_sync.nonce_bytes 'n')
        |> require_ok Relay.error_to_string
      in
      let advertisement =
        Relay.make_advertisement package ~private_key:alice_private
        |> require_ok Relay.error_to_string
      in
      Relay.publish ~relay ~package ~advertisement
      |> require_ok Relay.error_to_string;
      let configuration =
        Daemon.make_configuration ~root:destination_root ~runtime_dir:runtime
          ~contact:(Peer_sync.contact_id relay_contact)
          ~identity:(Peer_sync.peer_id bob) ~tracking_name:"main"
          ~transport:(Daemon.Relay { relay })
        |> require_ok Daemon.error_to_string
      in
      let daemon =
        Daemon.start configuration |> require_ok Daemon.error_to_string
      in
      Fun.protect
        ~finally:(fun () -> Daemon.close daemon)
        (fun () ->
          Alcotest.(check bool)
            "relay poll advances tracking" true
            (Daemon.poll_once daemon
            |> require_ok Daemon.error_to_string
            = Daemon.Tracking_advanced);
          Alcotest.(check (option string))
            "relay contact tracking advanced"
            (Some
               (Yeokcham_id.Peer_sync_node_id.to_hex
                  (Peer_sync.sync_node_id head)))
            (tracking destination relay_contact);
          Alcotest.(check bool)
            "replay receipt becomes no current update" true
            (Daemon.poll_once daemon
            |> require_ok Daemon.error_to_string
            = Daemon.No_current_update));
      let rejected_runtime = Filename.concat runtime "unconfigured" in
      Unix.mkdir rejected_runtime 0o700;
      let rejected_configuration =
        Daemon.make_configuration ~root:destination_root
          ~runtime_dir:rejected_runtime
          ~contact:(Peer_sync.contact_id local_contact)
          ~identity:(Peer_sync.peer_id bob) ~tracking_name:"main"
          ~transport:(Daemon.Relay { relay })
        |> require_ok Daemon.error_to_string
      in
      let rejected_daemon =
        Daemon.start rejected_configuration |> require_ok Daemon.error_to_string
      in
      Fun.protect
        ~finally:(fun () -> Daemon.close rejected_daemon)
        (fun () ->
          Alcotest.(check bool)
            "unconfigured relay is not polled" true
            (Result.is_error (Daemon.poll_once rejected_daemon))))

let read_all descriptor =
  let buffer = Bytes.create 256 in
  let rec loop chunks =
    match Unix.read descriptor buffer 0 (Bytes.length buffer) with
    | 0 -> String.concat "" (List.rev chunks)
    | count -> loop (Bytes.sub_string buffer 0 count :: chunks)
  in
  loop []

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let unauthorized_client_is_rejected root runtime endpoint =
  let discovery = Local_daemon.discovery_path endpoint in
  let original = read_file discovery in
  let replacement =
    String.split_on_char '\n' original
    |> List.map (fun line ->
        if String.starts_with ~prefix:"capability=" line then
          "capability=" ^ String.make 64 '0'
        else line)
    |> String.concat "\n"
  in
  write_file discovery replacement;
  let rejected = Daemon.ping ~root ~runtime_dir:runtime in
  write_file discovery original;
  Alcotest.(check bool)
    "wrong capability is rejected" true
    (rejected = Error (Daemon.Local_daemon_error Local_daemon.Unauthorized))

let rec wait_until attempts predicate =
  if predicate () then ()
  else if attempts = 0 then Alcotest.fail "timed out waiting for daemon state"
  else (
    ignore (Unix.select [] [] [] 0.01);
    wait_until (attempts - 1) predicate)

let lifecycle_rejects_malformed_requests_and_shuts_down () =
  with_repositories
    (fun
      ~source:_
      ~destination:_
      ~source_root:_
      ~destination_root
      ~runtime
      ~relay
      ~alice:_
      ~alice_private:_
      ~bob
      ~local_contact:_
      ~relay_contact
      ~head:_
      ~source_key:_
    ->
      let configuration =
        Daemon.make_configuration ~root:destination_root ~runtime_dir:runtime
          ~contact:(Peer_sync.contact_id relay_contact)
          ~identity:(Peer_sync.peer_id bob) ~tracking_name:"main"
          ~transport:(Daemon.Relay { relay })
        |> require_ok Daemon.error_to_string
      in
      let daemon =
        Daemon.start configuration |> require_ok Daemon.error_to_string
      in
      let endpoint = Daemon.endpoint daemon in
      match Unix.fork () with
      | 0 ->
          let result = Daemon.run daemon ~idle_timeout:0.01 in
          exit (if Result.is_ok result then 0 else 1)
      | child ->
          let client = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
          Unix.connect client
            (Unix.ADDR_UNIX (Local_daemon.socket_path endpoint));
          ignore (Unix.write_substring client "malformed\n" 0 10);
          Unix.shutdown client Unix.SHUTDOWN_SEND;
          Alcotest.(check string)
            "malformed control request"
            "yeokcham-local-response 1\nstatus=malformed\n" (read_all client);
          Unix.close client;
          unauthorized_client_is_rejected destination_root runtime endpoint;
          Daemon.ping ~root:destination_root ~runtime_dir:runtime
          |> require_ok Daemon.error_to_string;
          Daemon.shutdown ~root:destination_root ~runtime_dir:runtime
          |> require_ok Daemon.error_to_string;
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "shutdown cancels runner" true (status = Unix.WEXITED 0);
          Daemon.close daemon)

let retry_is_bounded_and_stale_recovery_is_explicit () =
  with_repositories
    (fun
      ~source:_
      ~destination:_
      ~source_root:_
      ~destination_root
      ~runtime
      ~relay
      ~alice:_
      ~alice_private:_
      ~bob
      ~local_contact:_
      ~relay_contact
      ~head:_
      ~source_key:_
    ->
      Unix.rmdir relay;
      let descriptor =
        Unix.openfile relay [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      in
      Unix.close descriptor;
      let configuration =
        Daemon.make_configuration ~root:destination_root ~runtime_dir:runtime
          ~contact:(Peer_sync.contact_id relay_contact)
          ~identity:(Peer_sync.peer_id bob) ~tracking_name:"main"
          ~transport:(Daemon.Relay { relay })
        |> require_ok Daemon.error_to_string
      in
      let daemon =
        Daemon.start configuration |> require_ok Daemon.error_to_string
      in
      Alcotest.(check bool)
        "failed poll records retry" true
        (Result.is_error (Daemon.poll_once daemon));
      let status =
        Daemon.read_status ~root:destination_root ~runtime_dir:runtime
        |> require_ok Daemon.error_to_string
      in
      Alcotest.(check bool)
        "failure is never reported as synchronized" true
        (Daemon.status_kind status = Daemon.Failed);
      Alcotest.(check bool)
        "retry deadline is bounded" true
        (match Daemon.status_next_retry_at status with
        | None -> false
        | Some retry ->
            retry -. Unix.gettimeofday () <= Daemon.max_retry_delay_seconds);
      Daemon.close daemon;
      let stopped =
        Daemon.read_status ~root:destination_root ~runtime_dir:runtime
        |> require_ok Daemon.error_to_string
      in
      Alcotest.(check bool)
        "stopped daemon is never reported as synchronized" true
        (Daemon.status_kind stopped = Daemon.Stopped);
      let endpoint =
        Local_daemon.endpoint ~root:destination_root ~runtime_dir:runtime
        |> require_ok Local_daemon.error_to_string
      in
      let socket = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      Unix.bind socket (Unix.ADDR_UNIX (Local_daemon.socket_path endpoint));
      Unix.close socket;
      let discovery = Local_daemon.discovery_path endpoint in
      let output = open_out_bin discovery in
      output_string output "stale\n";
      close_out output;
      Daemon.recover_stale ~root:destination_root ~runtime_dir:runtime
      |> require_ok Daemon.error_to_string;
      Alcotest.(check bool)
        "stale endpoint removed" false
        (Sys.file_exists (Local_daemon.socket_path endpoint)))

let crash_recovery_preserves_tracking_and_restart_is_idempotent () =
  with_repositories
    (fun
      ~source:_
      ~destination
      ~source_root
      ~destination_root
      ~runtime
      ~relay:_
      ~alice:_
      ~alice_private:_
      ~bob
      ~local_contact
      ~relay_contact:_
      ~head
      ~source_key
    ->
      let configuration =
        Daemon.make_configuration ~root:destination_root ~runtime_dir:runtime
          ~contact:(Peer_sync.contact_id local_contact)
          ~identity:(Peer_sync.peer_id bob) ~tracking_name:"main"
          ~transport:
            (Daemon.Local
               { source_root; source_key; head = Peer_sync.sync_node_id head })
        |> require_ok Daemon.error_to_string
      in
      match Unix.fork () with
      | 0 ->
          let result =
            Result.bind (Daemon.start configuration) (fun daemon ->
                Daemon.run daemon ~idle_timeout:60.0)
          in
          exit (if Result.is_ok result then 0 else 1)
      | child ->
          wait_until 100 (fun () ->
              match
                Daemon.read_status ~root:destination_root ~runtime_dir:runtime
              with
              | Ok status ->
                  Daemon.status_kind status = Daemon.Tracking_advanced
              | Error _ -> false);
          Unix.kill child Sys.sigkill;
          let _, child_status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "crashed runner is observed" true
            (child_status = Unix.WSIGNALED Sys.sigkill);
          let endpoint =
            Local_daemon.endpoint ~root:destination_root ~runtime_dir:runtime
            |> require_ok Local_daemon.error_to_string
          in
          Daemon.recover_stale ~root:destination_root ~runtime_dir:runtime
          |> require_ok Daemon.error_to_string;
          Alcotest.(check bool)
            "crash recovery removes runtime status" false
            (Result.is_ok
               (Daemon.read_status ~root:destination_root ~runtime_dir:runtime));
          Alcotest.(check bool)
            "crash recovery removes endpoint" false
            (Sys.file_exists (Local_daemon.socket_path endpoint));
          let restarted =
            Daemon.start configuration |> require_ok Daemon.error_to_string
          in
          Fun.protect
            ~finally:(fun () -> Daemon.close restarted)
            (fun () ->
              Alcotest.(check bool)
                "restart preserves accepted tracking" true
                (Daemon.poll_once restarted
                |> require_ok Daemon.error_to_string
                = Daemon.Tracking_already_current);
              Alcotest.(check (option string))
                "restart keeps matching tracking head"
                (Some
                   (Yeokcham_id.Peer_sync_node_id.to_hex
                      (Peer_sync.sync_node_id head)))
                (tracking destination local_contact)))

let () =
  Alcotest.run "peer sync daemon"
    [
      ( "runtime",
        [
          Alcotest.test_case "configured direct poll tracks only its contact"
            `Quick direct_poll_advances_only_peer_tracking;
          Alcotest.test_case "configured relay poll imports a signed package"
            `Quick relay_poll_imports_configured_contact;
          Alcotest.test_case "control lifecycle and malformed request" `Quick
            lifecycle_rejects_malformed_requests_and_shuts_down;
          Alcotest.test_case "bounded retry and explicit stale recovery" `Quick
            retry_is_bounded_and_stale_recovery_is_explicit;
          Alcotest.test_case "crash recovery preserves tracking on restart"
            `Quick crash_recovery_preserves_tracking_and_restart_is_idempotent;
        ] );
    ]
