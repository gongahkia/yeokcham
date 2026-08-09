module Daemon = Yeokcham_local_daemon
module Store = Yeokcham_store

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Daemon.error_to_string error)

let rec remove_tree path =
  try
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_directories run =
  let parent = Filename.temp_file "yeokcham-local-daemon-" "" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  let root = Filename.concat parent "repository"
  and runtime = Filename.concat parent "runtime" in
  Unix.mkdir root 0o700;
  Unix.mkdir runtime 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree parent)
    (fun () ->
      Store.init ~root |> Result.map_error Store.error_to_string |> function
      | Error error -> Alcotest.fail error
      | Ok _ -> run root runtime)

let read_all descriptor =
  let buffer = Bytes.create 256 in
  let rec loop chunks =
    match Unix.read descriptor buffer 0 (Bytes.length buffer) with
    | 0 -> String.concat "" (List.rev chunks)
    | count -> loop (Bytes.sub_string buffer 0 count :: chunks)
  in
  loop []

let malformed_client_is_rejected endpoint =
  let client = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close client)
    (fun () ->
      Unix.connect client (Unix.ADDR_UNIX (Daemon.socket_path endpoint));
      ignore (Unix.write client (Bytes.of_string "invalid\n") 0 8);
      Unix.shutdown client Unix.SHUTDOWN_SEND;
      Alcotest.(check string)
        "malformed response" "yeokcham-local-response 1\nstatus=malformed\n"
        (read_all client))

let daemon_lifecycle_and_protocol () =
  with_directories (fun root runtime ->
      let daemon = Daemon.start ~root ~runtime_dir:runtime |> require_ok in
      let endpoint = Daemon.endpoint ~root ~runtime_dir:runtime |> require_ok in
      Alcotest.(check bool)
        "second daemon is refused" true
        (Result.is_error (Daemon.start ~root ~runtime_dir:runtime));
      match Unix.fork () with
      | 0 ->
          let status =
            match Daemon.serve daemon with Ok () -> 0 | Error _ -> 1
          in
          exit status
      | child ->
          Daemon.ping ~root ~runtime_dir:runtime |> require_ok;
          malformed_client_is_rejected endpoint;
          Daemon.shutdown ~root ~runtime_dir:runtime |> require_ok;
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "controlled shutdown exits cleanly" true (status = Unix.WEXITED 0);
          Daemon.close daemon;
          let restarted =
            Daemon.start ~root ~runtime_dir:runtime |> require_ok
          in
          Daemon.close restarted)

let stale_socket_recovery_is_explicit () =
  with_directories (fun root runtime ->
      let endpoint = Daemon.endpoint ~root ~runtime_dir:runtime |> require_ok in
      let socket = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      Unix.bind socket (Unix.ADDR_UNIX (Daemon.socket_path endpoint));
      Unix.close socket;
      Out_channel.with_open_bin (Daemon.discovery_path endpoint) (fun channel ->
          Out_channel.output_string channel "stale\n");
      Daemon.recover_stale ~root ~runtime_dir:runtime |> require_ok;
      Alcotest.(check bool)
        "stale socket removed" false
        (Sys.file_exists (Daemon.socket_path endpoint));
      Alcotest.(check bool)
        "stale discovery removed" false
        (Sys.file_exists (Daemon.discovery_path endpoint)))

let () =
  Alcotest.run "local daemon"
    [
      ( "lifecycle",
        [
          Alcotest.test_case "singleton, authenticated protocol, and shutdown"
            `Quick daemon_lifecycle_and_protocol;
          Alcotest.test_case "stale recovery is explicit" `Quick
            stale_socket_recovery_is_explicit;
        ] );
    ]
