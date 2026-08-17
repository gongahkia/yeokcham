module Peer_sync = Yeokcham_peer_sync
module Ssh = Yeokcham_peer_sync_ssh
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

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

let with_file prefix run =
  let path = Filename.temp_file prefix "" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> run path)

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

let snapshot store =
  let content =
    Snapshot.Content.store store "SSH peer-sync\n"
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

let store_identity store identity =
  ignore
    (Peer_sync.store_identity store identity
    |> require_ok Peer_sync.error_to_string)

let with_repositories run =
  with_directory "yeokcham-peer-ssh-source-" (fun source_root ->
      with_directory "yeokcham-peer-ssh-destination-" (fun destination_root ->
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
              ~endpoints:
                [ Peer_sync.Ssh { target = "fixture"; root = source_root } ]
            |> require_ok Peer_sync.error_to_string
          in
          ignore
            (Peer_sync.store_contact destination contact
            |> require_ok Peer_sync.error_to_string);
          let head =
            Peer_sync.make_sync_node ~author:alice ~private_key:alice_private
              ~snapshot:(snapshot source) ~parents:[]
            |> require_ok Peer_sync.error_to_string
          in
          ignore
            (Peer_sync.store_sync_node source head
            |> require_ok Peer_sync.error_to_string);
          run ~source_root ~source ~destination ~alice ~alice_private ~bob
            ~contact ~head))

let signed_response_is_challenge_bound () =
  with_repositories
    (fun
      ~source_root
      ~source
      ~destination
      ~alice
      ~alice_private
      ~bob
      ~contact
      ~head
    ->
      let nonce = String.make Peer_sync.nonce_bytes 'n' in
      let request =
        Ssh.make_request ~remote_root:source_root
          ~source:(Peer_sync.peer_id alice) ~destination:bob ~nonce
          ~tracking_name:"main"
          ~head:(Peer_sync.sync_node_id head)
        |> require_ok Ssh.error_to_string
      in
      with_file "yeokcham-peer-ssh-server-" (fun response_path ->
          let input = open_in_bin "/dev/null" in
          let output = open_out_bin response_path in
          let served =
            Ssh.serve_stream ~source ~source_identity:alice
              ~source_private_key:alice_private ~request ~input ~output
          in
          close_in input;
          close_out output;
          Alcotest.(check bool)
            "server stops without an exchange hello" true
            (Result.is_error served);
          let response = open_in_bin response_path in
          let sink_path = Filename.temp_file "yeokcham-peer-ssh-sink-" "" in
          let sink = open_out_bin sink_path in
          let received =
            Fun.protect
              ~finally:(fun () ->
                close_in_noerr response;
                close_out_noerr sink;
                Sys.remove sink_path)
              (fun () ->
                Ssh.sync_stream ~destination ~contact ~destination_identity:bob
                  ~request ~input:response ~output:sink ())
          in
          Alcotest.(check bool)
            "valid response reaches exchange boundary" true
            (Result.is_error received);
          let replay_request =
            Ssh.make_request ~remote_root:source_root
              ~source:(Peer_sync.peer_id alice) ~destination:bob
              ~nonce:(String.make Peer_sync.nonce_bytes 'r')
              ~tracking_name:"main"
              ~head:(Peer_sync.sync_node_id head)
            |> require_ok Ssh.error_to_string
          in
          let replay_response = open_in_bin response_path in
          let replay_sink_path =
            Filename.temp_file "yeokcham-peer-ssh-sink-" ""
          in
          let replay_sink = open_out_bin replay_sink_path in
          let replay =
            Fun.protect
              ~finally:(fun () ->
                close_in_noerr replay_response;
                close_out_noerr replay_sink;
                Sys.remove replay_sink_path)
              (fun () ->
                Ssh.sync_stream ~destination ~contact ~destination_identity:bob
                  ~request:replay_request ~input:replay_response
                  ~output:replay_sink ())
          in
          Alcotest.(check bool)
            "replayed response rejects before exchange" true
            (Result.is_error replay);
          Alcotest.(check (option string))
            "tracking stays absent without closure" None
            (Peer_sync.tracking_head destination ~contact ~name:"main"
            |> require_ok Peer_sync.error_to_string
            |> Option.map Yeokcham_id.Peer_sync_node_id.to_hex)))

let signature_failure_preserves_tracking () =
  with_repositories
    (fun
      ~source_root
      ~source
      ~destination
      ~alice
      ~alice_private:_
      ~bob
      ~contact
      ~head
    ->
      let _, wrong_private = identity 'z' in
      let request =
        Ssh.make_request ~remote_root:source_root
          ~source:(Peer_sync.peer_id alice) ~destination:bob
          ~nonce:(String.make Peer_sync.nonce_bytes 'n')
          ~tracking_name:"main"
          ~head:(Peer_sync.sync_node_id head)
        |> require_ok Ssh.error_to_string
      in
      with_file "yeokcham-peer-ssh-response-" (fun response_path ->
          let input = open_in_bin "/dev/null" in
          let output = open_out_bin response_path in
          ignore
            (Ssh.serve_stream ~source ~source_identity:alice
               ~source_private_key:wrong_private ~request ~input ~output);
          close_in input;
          close_out output;
          let response = open_in_bin response_path in
          let sink_path = Filename.temp_file "yeokcham-peer-ssh-sink-" "" in
          let sink = open_out_bin sink_path in
          let received =
            Fun.protect
              ~finally:(fun () ->
                close_in_noerr response;
                close_out_noerr sink;
                Sys.remove sink_path)
              (fun () ->
                Ssh.sync_stream ~destination ~contact ~destination_identity:bob
                  ~request ~input:response ~output:sink ())
          in
          Alcotest.(check bool)
            "wrong signature rejects before exchange" true
            (Result.is_error received);
          Alcotest.(check (option string))
            "tracking stays absent" None
            (Peer_sync.tracking_head destination ~contact ~name:"main"
            |> require_ok Peer_sync.error_to_string
            |> Option.map Yeokcham_id.Peer_sync_node_id.to_hex)))

let request_is_canonical_and_bounded () =
  let alice, _ = identity 'a' in
  let bob, _ = identity 'b' in
  let head =
    Yeokcham_id.Peer_sync_node_id.of_bytes (String.make 32 'h')
    |> require_ok Yeokcham_id.parse_error_to_string
  in
  let request =
    Ssh.make_request ~remote_root:"/var/tmp/yeokcham"
      ~source:(Peer_sync.peer_id alice) ~destination:bob
      ~nonce:(String.make Peer_sync.nonce_bytes 'n')
      ~tracking_name:"main" ~head
    |> require_ok Ssh.error_to_string
  in
  let payload = Ssh.request_payload request |> require_ok Ssh.error_to_string in
  let decoded =
    Ssh.decode_request_payload payload |> require_ok Ssh.error_to_string
  in
  Alcotest.(check string)
    "request inverse encoding"
    (Peer_sync.peer_id bob |> Yeokcham_id.Peer_id.to_hex)
    (Ssh.request_destination decoded
    |> Peer_sync.peer_id |> Yeokcham_id.Peer_id.to_hex);
  Alcotest.(check bool)
    "unsafe remote root rejects" true
    (Result.is_error
       (Ssh.make_request ~remote_root:"/var/tmp/yeokcham;bad"
          ~source:(Peer_sync.peer_id alice) ~destination:bob
          ~nonce:(String.make Peer_sync.nonce_bytes 'n')
          ~tracking_name:"main" ~head))

let ssh_arguments_are_fixed_and_pinned () =
  let arguments =
    Ssh.ssh_arguments ~target:"peer-fixture" ~known_hosts:"/tmp/known_hosts" ()
    |> require_ok Ssh.error_to_string
    |> Array.to_list
  in
  Alcotest.(check bool)
    "host policy is strict" true
    (List.mem "StrictHostKeyChecking=yes" arguments);
  Alcotest.(check bool)
    "fixed remote command" true
    (List.mem "yeokcham peer sync ssh-serve" arguments);
  Alcotest.(check bool)
    "target injection rejects" true
    (Result.is_error
       (Ssh.ssh_arguments ~target:"peer;injected"
          ~known_hosts:"/tmp/known_hosts" ()))

let malformed_response_preserves_tracking () =
  with_repositories
    (fun
      ~source_root:_
      ~source:_
      ~destination
      ~alice:_
      ~alice_private:_
      ~bob
      ~contact
      ~head
    ->
      let request =
        Ssh.make_request ~remote_root:"/var/tmp/yeokcham"
          ~source:(Peer_sync.peer_id (Peer_sync.contact_identity contact))
          ~destination:bob
          ~nonce:(String.make Peer_sync.nonce_bytes 'n')
          ~tracking_name:"main"
          ~head:(Peer_sync.sync_node_id head)
        |> require_ok Ssh.error_to_string
      in
      with_file "yeokcham-peer-ssh-malformed-" (fun response_path ->
          let malformed = open_out_bin response_path in
          Out_channel.output_string malformed "not a framed response";
          close_out malformed;
          let response = open_in_bin response_path in
          let sink_path = Filename.temp_file "yeokcham-peer-ssh-sink-" "" in
          let sink = open_out_bin sink_path in
          let result =
            Fun.protect
              ~finally:(fun () ->
                close_in_noerr response;
                close_out_noerr sink;
                Sys.remove sink_path)
              (fun () ->
                Ssh.sync_stream ~destination ~contact ~destination_identity:bob
                  ~request ~input:response ~output:sink ())
          in
          Alcotest.(check bool)
            "malformed response rejects" true (Result.is_error result);
          Alcotest.(check (option string))
            "tracking stays absent" None
            (Peer_sync.tracking_head destination ~contact ~name:"main"
            |> require_ok Peer_sync.error_to_string
            |> Option.map Yeokcham_id.Peer_sync_node_id.to_hex)))

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () ->
      Out_channel.output_string channel contents;
      Out_channel.flush channel)

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> In_channel.input_all channel)

let write_private_key path private_key =
  let bytes = Mirage_crypto_ec.Ed25519.priv_to_octets private_key in
  let descriptor =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
  in
  Fun.protect
    ~finally:(fun () -> Unix.close descriptor)
    (fun () ->
      Unix.fchmod descriptor 0o600;
      let rec write offset =
        if offset = String.length bytes then ()
        else
          let count =
            Unix.write_substring descriptor bytes offset
              (String.length bytes - offset)
          in
          if count = 0 then Alcotest.fail "could not write SSH signing key"
          else write (offset + count)
      in
      write 0)

let run_process program arguments =
  let null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close null)
    (fun () ->
      let pid = Unix.create_process program arguments null null null in
      match snd (Unix.waitpid [] pid) with
      | Unix.WEXITED 0 -> ()
      | Unix.WEXITED status -> Alcotest.failf "%s exited with %d" program status
      | Unix.WSIGNALED signal ->
          Alcotest.failf "%s received signal %d" program signal
      | Unix.WSTOPPED signal ->
          Alcotest.failf "%s stopped with signal %d" program signal)

let fresh_loopback_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_, port) -> port
      | Unix.ADDR_UNIX _ -> Alcotest.fail "expected a TCP socket")

let wait_for_port port =
  let rec loop remaining =
    if remaining = 0 then Alcotest.fail "test sshd did not start"
    else
      let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      let connected =
        try
          Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
          true
        with Unix.Unix_error _ -> false
      in
      Unix.close socket;
      if connected then ()
      else (
        ignore (Unix.select [] [] [] 0.05);
        loop (remaining - 1))
  in
  loop 100

let stop_process pid =
  try
    let waited, _ = Unix.waitpid [ Unix.WNOHANG ] pid in
    if waited = 0 then (
      Unix.kill pid Sys.sigterm;
      ignore (Unix.waitpid [] pid))
  with Unix.Unix_error _ -> ()

let executable_path () =
  let test_directory = Filename.dirname Sys.executable_name in
  let build_directory = Filename.dirname test_directory in
  Filename.concat build_directory "bin/yeokcham.exe"

let real_openssh_sync_advances_tracking () =
  let sshd = "/usr/sbin/sshd" in
  let ssh_keygen = "/usr/bin/ssh-keygen" in
  if not (Sys.file_exists sshd && Sys.file_exists ssh_keygen) then
    Alcotest.skip ()
  else
    with_repositories
      (fun
        ~source_root
        ~source
        ~destination
        ~alice
        ~alice_private
        ~bob
        ~contact
        ~head
      ->
        ignore source;
        ignore alice;
        with_directory "yeokcham-peer-ssh-fixture-" (fun fixture ->
            let client_key = Filename.concat fixture "client" in
            let host_key = Filename.concat fixture "host" in
            let authorized_keys = Filename.concat fixture "authorized_keys" in
            let known_hosts = Filename.concat fixture "known_hosts" in
            let client_config = Filename.concat fixture "ssh_config" in
            let server_config = Filename.concat fixture "sshd_config" in
            let pid_file = Filename.concat fixture "sshd.pid" in
            run_process ssh_keygen
              [|
                ssh_keygen; "-q"; "-t"; "ed25519"; "-N"; ""; "-f"; client_key;
              |];
            run_process ssh_keygen
              [| ssh_keygen; "-q"; "-t"; "ed25519"; "-N"; ""; "-f"; host_key |];
            let capability = Ssh.capability_path ~root:source_root in
            write_private_key capability alice_private;
            let yeokcham = executable_path () in
            if not (Sys.file_exists yeokcham) then
              Alcotest.failf "same Yeokcham executable is unavailable: %s"
                yeokcham;
            let client_public = String.trim (read_file (client_key ^ ".pub")) in
            let forced =
              "command=\"" ^ yeokcham ^ " peer sync ssh-serve\",restrict "
              ^ client_public ^ "\n"
            in
            write_file authorized_keys forced;
            Unix.chmod authorized_keys 0o600;
            let port = fresh_loopback_port () in
            let host_public = String.trim (read_file (host_key ^ ".pub")) in
            write_file known_hosts
              (Printf.sprintf "[127.0.0.1]:%d %s\n" port host_public);
            Unix.chmod known_hosts 0o600;
            let user = (Unix.getpwuid (Unix.getuid ())).Unix.pw_name in
            write_file client_config
              (Printf.sprintf
                 "Host fixture\n\
                 \  HostName 127.0.0.1\n\
                 \  Port %d\n\
                 \  User %s\n\
                 \  IdentityFile %s\n\
                 \  IdentitiesOnly yes\n"
                 port user client_key);
            write_file server_config
              (Printf.sprintf
                 "Port %d\n\
                  ListenAddress 127.0.0.1\n\
                  HostKey %s\n\
                  PidFile %s\n\
                  AuthorizedKeysFile %s\n\
                  PasswordAuthentication no\n\
                  KbdInteractiveAuthentication no\n\
                  ChallengeResponseAuthentication no\n\
                  UsePAM no\n\
                  PermitRootLogin no\n\
                  StrictModes yes\n\
                  UseDNS no\n\
                  LogLevel ERROR\n"
                 port host_key pid_file authorized_keys);
            let null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
            let sshd_pid =
              Fun.protect
                ~finally:(fun () -> Unix.close null)
                (fun () ->
                  Unix.create_process sshd
                    [| sshd; "-D"; "-e"; "-f"; server_config |]
                    null null null)
            in
            Fun.protect
              ~finally:(fun () -> stop_process sshd_pid)
              (fun () ->
                wait_for_port port;
                let wrong_repository_contact =
                  Peer_sync.make_contact ~name:"wrong-root"
                    ~identity:(Peer_sync.contact_identity contact)
                    ~endpoints:
                      [
                        Peer_sync.Ssh
                          { target = "fixture"; root = Store.root destination };
                      ]
                  |> require_ok Peer_sync.error_to_string
                in
                ignore
                  (Peer_sync.store_contact destination wrong_repository_contact
                  |> require_ok Peer_sync.error_to_string);
                let wrong_repository =
                  Ssh.sync_ssh ~destination ~contact:wrong_repository_contact
                    ~destination_identity:bob ~known_hosts
                    ~ssh_config:client_config
                    ~nonce:(String.make Peer_sync.nonce_bytes 'w')
                    ~tracking_name:"main"
                    ~head:(Peer_sync.sync_node_id head)
                    ()
                in
                Alcotest.(check bool)
                  "wrong remote repository rejects" true
                  (Result.is_error wrong_repository);
                let interrupted =
                  Ssh.sync_ssh ~interrupt_after:0 ~destination ~contact
                    ~destination_identity:bob ~known_hosts
                    ~ssh_config:client_config
                    ~nonce:(String.make Peer_sync.nonce_bytes 'i')
                    ~tracking_name:"main"
                    ~head:(Peer_sync.sync_node_id head)
                    ()
                in
                Alcotest.(check bool)
                  "interrupted SSH transfer rejects" true
                  (Result.is_error interrupted);
                Alcotest.(check (option string))
                  "interrupted SSH transfer leaves tracking absent" None
                  (Peer_sync.tracking_head destination ~contact ~name:"main"
                  |> require_ok Peer_sync.error_to_string
                  |> Option.map Yeokcham_id.Peer_sync_node_id.to_hex);
                let outcome, decision =
                  Ssh.sync_ssh ~destination ~contact ~destination_identity:bob
                    ~known_hosts ~ssh_config:client_config
                    ~nonce:(String.make Peer_sync.nonce_bytes 'n')
                    ~tracking_name:"main"
                    ~head:(Peer_sync.sync_node_id head)
                    ()
                  |> require_ok Ssh.error_to_string
                in
                Alcotest.(check bool)
                  "OpenSSH transfers an immutable closure" true
                  (outcome.Yeokcham_exchange_store.transferred <> []);
                match decision with
                | Peer_sync.Tracking_advanced node ->
                    Alcotest.(check string)
                      "OpenSSH tracking head"
                      (Yeokcham_id.Peer_sync_node_id.to_hex
                         (Peer_sync.sync_node_id head))
                      (Yeokcham_id.Peer_sync_node_id.to_hex
                         (Peer_sync.sync_node_id node))
                | Peer_sync.Tracking_already_current _
                | Peer_sync.Tracking_diverged _ ->
                    Alcotest.fail "OpenSSH sync must advance empty tracking")))

let () =
  Alcotest.run "yeokcham_peer_sync_ssh"
    [
      ( "transport",
        [
          Alcotest.test_case "signed response is challenge-bound" `Quick
            signed_response_is_challenge_bound;
          Alcotest.test_case "bad remote signature preserves tracking" `Quick
            signature_failure_preserves_tracking;
          Alcotest.test_case "request is canonical and bounded" `Quick
            request_is_canonical_and_bounded;
          Alcotest.test_case "fixed command and host policy" `Quick
            ssh_arguments_are_fixed_and_pinned;
          Alcotest.test_case "malformed response preserves tracking" `Quick
            malformed_response_preserves_tracking;
          Alcotest.test_case "real OpenSSH sync advances tracking" `Slow
            real_openssh_sync_advances_tracking;
        ] );
    ]
