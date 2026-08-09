module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Model = Yeokcham_model
module Object_store = Yeokcham_v2_object_store
module Runner = Yeokcham_v2_scratch_daemon
module Scanner = Yeokcham_v2_scanner
module Scheduler = Yeokcham_v2_scratch_scheduler
module Scratch = Yeokcham_v2_scratch_store
module Store = Yeokcham_store
module V2_model = Yeokcham_v2_model
module Watcher = Yeokcham_watcher

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

let request ?(reason = Watcher.Path_change) paths =
  {
    Watcher.reason;
    target = Watcher.Paths (List.map (fun path -> [ path ]) paths);
  }

let whole_root =
  { Watcher.reason = Watcher.Watcher_lost; target = Watcher.Whole_root }

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

let with_repository run =
  let root = Filename.temp_file "yeokcham-v2-scratch-daemon-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      ignore (Store.init ~root |> require_ok Store.error_to_string);
      ignore
        (Bootstrap_store.initialize ~root bootstrap
        |> require_ok Bootstrap_store.error_to_string);
      let bootstrap_repository =
        Bootstrap_store.open_repository ~root ~capability
        |> require_ok Bootstrap_store.error_to_string
      in
      let scratch =
        Scratch.open_repository ~root ~bootstrap_repository
        |> require_ok Scratch.error_to_string
      in
      run root bootstrap_repository scratch)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let nonce_source () =
  let next = ref 0 in
  fun () ->
    incr next;
    Envelope.nonce_of_bytes (String.make 12 (Char.chr !next))
    |> Result.map_error Envelope.error_to_string

let runner root bootstrap_repository =
  Runner.create ~root ~bootstrap_repository ~config:scheduler_config
    ~nonce_source:(nonce_source ())

let checkpoint = function
  | Scratch.Checkpoint checkpoint -> checkpoint
  | Scratch.No_checkpoint ->
      Alcotest.fail "scratch checkpoint unexpectedly absent"
  | Scratch.Divergent_checkpoints _ ->
      Alcotest.fail "scratch checkpoint diverged"

let expect_none name = function
  | None -> ()
  | Some _ -> Alcotest.failf "%s unexpectedly emitted" name

let expect_some name = function
  | Some value -> value
  | None -> Alcotest.failf "%s did not emit" name

let due_scan_publishes_once_then_unchanged_scan_writes_nothing () =
  with_repository (fun root bootstrap_repository scratch ->
      write_file (Filename.concat root "work") "before";
      let runner = runner root bootstrap_repository in
      Runner.observe runner ~at:0L (request [ "work" ])
      |> require_ok Runner.error_to_string
      |> expect_none "first request";
      let first =
        Runner.advance runner ~at:10L
        |> require_ok Runner.error_to_string
        |> expect_some "due request"
      in
      (match first.Runner.publication with
      | Runner.Published_checkpoint _ -> ()
      | Runner.No_checkpoint ->
          Alcotest.fail "initial exact scan was not published");
      let objects =
        Object_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key
        |> require_ok Object_store.error_to_string
        |> Object_store.list_object_refs
        |> require_ok Object_store.error_to_string
      in
      Runner.observe runner ~at:20L (request [ "work" ])
      |> require_ok Runner.error_to_string
      |> expect_none "unchanged request";
      let unchanged =
        Runner.advance runner ~at:30L
        |> require_ok Runner.error_to_string
        |> expect_some "unchanged due request"
      in
      Alcotest.(check bool)
        "exact unchanged scan requests no checkpoint" true
        (unchanged.Runner.publication = Runner.No_checkpoint);
      let after =
        Object_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key
        |> require_ok Object_store.error_to_string
        |> Object_store.list_object_refs
        |> require_ok Object_store.error_to_string
      in
      Alcotest.(check bool)
        "unchanged scan writes no object" true (objects = after);
      ignore
        (Scratch.inspect scratch
        |> require_ok Scratch.error_to_string
        |> checkpoint))

let late_request_publishes_the_old_emission_before_rescheduling () =
  with_repository (fun root bootstrap_repository _ ->
      write_file (Filename.concat root "work") "before";
      let runner = runner root bootstrap_repository in
      Runner.observe runner ~at:0L (request [ "first" ])
      |> require_ok Runner.error_to_string
      |> expect_none "first request";
      let old =
        Runner.observe runner ~at:15L (request [ "second" ])
        |> require_ok Runner.error_to_string
        |> expect_some "late request"
      in
      Alcotest.(check bool)
        "late request keeps old advisory work separate" true
        (old.Runner.request = request [ "first" ]);
      let new_ =
        Runner.advance runner ~at:25L
        |> require_ok Runner.error_to_string
        |> expect_some "rescheduled request"
      in
      Alcotest.(check bool)
        "new advisory work remains pending" true
        (new_.Runner.request = request [ "second" ]);
      Alcotest.(check bool)
        "second exact scan is unchanged" true
        (new_.Runner.publication = Runner.No_checkpoint))

let restart_after_pending_work_replays_a_whole_root_scan () =
  with_repository (fun root bootstrap_repository scratch ->
      let work = Filename.concat root "work" in
      write_file work "before";
      let first_runner = runner root bootstrap_repository in
      ignore
        (Runner.observe first_runner ~at:0L (request [ "work" ])
        |> require_ok Runner.error_to_string);
      ignore
        (Runner.advance first_runner ~at:10L
        |> require_ok Runner.error_to_string);
      write_file work "after";
      ignore
        (Runner.observe first_runner ~at:20L (request [ "work" ])
        |> require_ok Runner.error_to_string);
      let before_restart =
        Scratch.inspect scratch
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      let current = Scanner.scan ~root |> require_ok Scanner.error_to_string in
      Alcotest.(check bool)
        "pending work leaves the old checkpoint valid" false
        (Model.Snapshot.equal before_restart.Scratch.snapshot current);
      let restarted_runner = runner root bootstrap_repository in
      Runner.observe restarted_runner ~at:30L whole_root
      |> require_ok Runner.error_to_string
      |> expect_none "restart request";
      let outcome =
        Runner.advance restarted_runner ~at:40L
        |> require_ok Runner.error_to_string
        |> expect_some "restart scan"
      in
      (match outcome.Runner.publication with
      | Runner.Published_checkpoint _ -> ()
      | Runner.No_checkpoint -> Alcotest.fail "restart scan did not publish");
      let expected = Scanner.scan ~root |> require_ok Scanner.error_to_string in
      let actual =
        Scratch.inspect scratch
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      Alcotest.(check bool)
        "whole-root restart reaches the exact current snapshot" true
        (Model.Snapshot.equal actual.Scratch.snapshot expected))

let duplicate_nonce_rejects_before_scanning_or_publication () =
  with_repository (fun root bootstrap_repository _ ->
      write_file (Filename.concat root "work") "before";
      let nonce =
        Envelope.nonce_of_bytes (String.make 12 'x')
        |> require_ok Envelope.error_to_string
      in
      let runner =
        Runner.create ~root ~bootstrap_repository ~config:scheduler_config
          ~nonce_source:(fun () -> Ok nonce)
      in
      ignore
        (Runner.observe runner ~at:0L (request [ "work" ])
        |> require_ok Runner.error_to_string);
      Alcotest.(check bool)
        "duplicate publication nonces reject" true
        (match Runner.advance runner ~at:10L with
        | Error error ->
            String.equal
              (Runner.error_to_string error)
              "scratch daemon nonce source reused one publication nonce"
        | Ok _ -> false);
      let objects =
        Object_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key
        |> require_ok Object_store.error_to_string
        |> Object_store.list_object_refs
        |> require_ok Object_store.error_to_string
      in
      Alcotest.(check int)
        "rejected nonce pair writes no object" 0 (List.length objects))

let () =
  Alcotest.run "V2 scratch daemon runner"
    [
      ( "unit",
        [
          Alcotest.test_case "due scan publishes then unchanged scan is quiet"
            `Quick due_scan_publishes_once_then_unchanged_scan_writes_nothing;
          Alcotest.test_case "late request emits then reschedules" `Quick
            late_request_publishes_the_old_emission_before_rescheduling;
          Alcotest.test_case "restart replays whole-root work" `Quick
            restart_after_pending_work_replays_a_whole_root_scan;
          Alcotest.test_case "duplicate nonces reject before publication" `Quick
            duplicate_nonce_rejects_before_scanning_or_publication;
        ] );
    ]
