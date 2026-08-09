module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Linux_daemon = Yeokcham_v2_linux_scratch_daemon
module Runtime = Yeokcham_local_daemon
module Scheduler = Yeokcham_v2_scratch_scheduler
module Store = Yeokcham_store
module V2_model = Yeokcham_v2_model

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let repository_id =
  V2_model.Repository_id.of_bytes (String.make 32 'r')
  |> require_ok V2_model.identity_error_to_string

let device_id =
  V2_model.Device_id.of_bytes (String.make 32 'd')
  |> require_ok V2_model.identity_error_to_string

let encryption_key =
  Envelope.key_of_bytes (String.make 32 'e')
  |> require_ok Envelope.error_to_string

let address_key =
  Address.key_of_bytes (String.make 32 'a')
  |> require_ok Address.error_to_string

let signing_key =
  Mirage_crypto_ec.Ed25519.priv_of_octets
    (String.init 32 (fun index -> Char.chr (index + 1)))
  |> require_ok (fun error ->
      Format.asprintf "%a" Mirage_crypto_ec.pp_error error)

let capability =
  Bootstrap.make_capability ~encryption_key ~address_key ~signing_key
  |> require_ok Bootstrap.error_to_string

let key_handle =
  Bootstrap.Key_handle.of_bytes (String.make 32 'h')
  |> require_ok V2_model.identity_error_to_string

let bootstrap =
  Bootstrap.make ~repository_id ~device_id ~key_handle ~capability
    ~mandatory_features:0L
  |> require_ok Bootstrap.error_to_string

let scheduler_config =
  Scheduler.make_config ~quiet_period:10L ~max_latency:30L
  |> require_ok Scheduler.error_to_string

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

let with_daemon run =
  let parent = Filename.temp_file "yc-v2d-" "" in
  Unix.unlink parent;
  Unix.mkdir parent 0o700;
  let root = Filename.concat parent "repository"
  and runtime_dir = Filename.concat parent "runtime" in
  Unix.mkdir root 0o700;
  Unix.mkdir runtime_dir 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree parent)
    (fun () ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      ignore
        (Bootstrap_store.initialize ~root bootstrap
        |> require_ok Bootstrap_store.error_to_string);
      let bootstrap_repository =
        Bootstrap_store.open_repository ~root ~capability
        |> require_ok Bootstrap_store.error_to_string
      in
      let daemon =
        Linux_daemon.start ~root ~runtime_dir ~bootstrap_repository
          ~scheduler_config ()
        |> require_ok Linux_daemon.error_to_string
      in
      Fun.protect
        ~finally:(fun () -> Linux_daemon.close daemon)
        (fun () -> run root runtime_dir daemon))

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let initial_whole_root_scan_is_due_after_start () =
  with_daemon (fun root _ daemon ->
      write_file (Filename.concat root "work") "initial";
      let due =
        match Linux_daemon.next_due_at daemon with
        | Some due -> due
        | None -> Alcotest.fail "initial scan was not queued"
      in
      let outcomes =
        Linux_daemon.tick daemon ~at:due
        |> require_ok Linux_daemon.error_to_string
      in
      Alcotest.(check bool)
        "initial whole-root scan publishes current work" true
        (List.exists
           (fun outcome ->
             match outcome.Linux_daemon.Runner.publication with
             | Linux_daemon.Runner.Published_checkpoint _ -> true
             | Linux_daemon.Runner.No_checkpoint -> false)
           outcomes))

let clock_is_monotonic_and_runtime_shutdown_stops_the_worker () =
  with_daemon (fun root runtime_dir daemon ->
      let first =
        Yeokcham_v2_monotonic_clock.now ()
        |> require_ok Yeokcham_v2_monotonic_clock.error_to_string
      in
      ignore (Unix.select [] [] [] 0.001);
      let second =
        Yeokcham_v2_monotonic_clock.now ()
        |> require_ok Yeokcham_v2_monotonic_clock.error_to_string
      in
      Alcotest.(check bool)
        "daemon clock does not move backwards" true
        (Int64.compare second first >= 0);
      match Unix.fork () with
      | 0 ->
          let status =
            match Linux_daemon.serve daemon with Ok () -> 0 | Error _ -> 1
          in
          exit status
      | child ->
          Runtime.shutdown ~root ~runtime_dir
          |> require_ok Runtime.error_to_string;
          let _, status = Unix.waitpid [] child in
          Alcotest.(check bool)
            "authenticated shutdown stops the scratch worker" true
            (status = Unix.WEXITED 0))

let () =
  Alcotest.run "V2 Linux scratch daemon"
    [
      ( "runtime",
        [
          Alcotest.test_case "start queues an initial whole-root scan" `Quick
            initial_whole_root_scan_is_due_after_start;
          Alcotest.test_case "monotonic loop and controlled shutdown" `Quick
            clock_is_monotonic_and_runtime_shutdown_stops_the_worker;
        ] );
    ]
