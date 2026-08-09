module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Journal = Yeokcham_v2_restore_journal
module Journal_store = Yeokcham_v2_restore_journal_store
module Materializer = Yeokcham_v2_restore_materializer
module Model = Yeokcham_model
module Preparation = Yeokcham_v2_restore_preparation
module Recovery = Yeokcham_v2_restore_recovery
module Scanner = Yeokcham_v2_scanner
module Scratch = Yeokcham_v2_scratch_store
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

let nonce character =
  Envelope.nonce_of_bytes (String.make 12 character)
  |> require_ok Envelope.error_to_string

let operation_id character =
  V2_model.Transaction_id.of_bytes (String.make 32 character)
  |> require_ok V2_model.identity_error_to_string

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
  let root = Filename.temp_file "yeokcham-v2-restore-recovery-" "" in
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

let publish_scan root scratch snapshot_nonce ledger_nonce =
  let snapshot = Scanner.scan ~root |> require_ok Scanner.error_to_string in
  Scratch.publish scratch ~snapshot ~snapshot_nonce:(nonce snapshot_nonce)
    ~ledger_nonce:(nonce ledger_nonce)
  |> require_ok Scratch.error_to_string
  |> function
  | Scratch.Published checkpoint -> checkpoint
  | Scratch.Unchanged _ -> Alcotest.fail "first selected target was unchanged"

let prepare root bootstrap_repository target operation =
  Preparation.prepare ~root ~bootstrap_repository
    ~target_event_id:target.Scratch.event_id ~operation_id:operation
    ~safety_snapshot_nonce:(nonce '3') ~safety_ledger_nonce:(nonce '4')
  |> require_ok Preparation.error_to_string
  |> function
  | Preparation.Prepared prepared -> prepared
  | Preparation.Noop _ -> Alcotest.fail "changed tree prepared as a no-op"

let journal_store root =
  Journal_store.open_repository ~root ~repository_id
  |> require_ok Journal_store.error_to_string

let recover root bootstrap_repository operation =
  Recovery.resume ~root ~bootstrap_repository ~operation_id:operation
    ~post_snapshot_nonce:(nonce '5') ~post_ledger_nonce:(nonce '6')
  |> require_ok Recovery.error_to_string

let checkpoint = function
  | Scratch.Checkpoint checkpoint -> checkpoint
  | Scratch.No_checkpoint ->
      Alcotest.fail "scratch checkpoint unexpectedly absent"
  | Scratch.Divergent_checkpoints _ ->
      Alcotest.fail "scratch checkpoint diverged"

let post_write_restart_reconciles_and_publishes_the_target () =
  with_repository (fun root bootstrap_repository scratch ->
      let work = Filename.concat root "work" in
      write_file work "target\000bytes";
      Unix.chmod work 0o755;
      let target = publish_scan root scratch '1' '2' in
      write_file work "observed\000bytes";
      Unix.chmod work 0o644;
      let operation = operation_id 'o' in
      let prepared = prepare root bootstrap_repository target operation in
      (match
         Materializer.materialize
           ~fault:(Materializer.Fault.interrupt_after_action 1)
           ~root ~journal_store:(journal_store root)
           ~plan:(Preparation.plan prepared)
           ~journal:(Preparation.journal prepared)
           ()
       with
      | Error (Materializer.Injected_interruption { completed_actions = 1 }) ->
          ()
      | Error error ->
          Alcotest.failf "expected injected interruption, received: %s"
            (Materializer.error_to_string error)
      | Ok _ -> Alcotest.fail "materialiser ignored injected interruption");
      let result = recover root bootstrap_repository operation in
      Alcotest.(check bool)
        "recovery reaches published journal" true
        (Journal.phase (Recovery.journal result) = Journal.Published);
      let actual = Scanner.scan ~root |> require_ok Scanner.error_to_string in
      Alcotest.(check bool)
        "root remains the selected exact target" true
        (Model.Snapshot.equal actual target.Scratch.snapshot);
      let current =
        Scratch.inspect scratch
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      Alcotest.(check bool)
        "published scratch checkpoint is exact target" true
        (Model.Snapshot.equal current.Scratch.snapshot target.Scratch.snapshot);
      Alcotest.(check bool)
        "result checkpoint is current target" true
        (Model.Snapshot.equal (Recovery.checkpoint result).Scratch.snapshot
           target.Scratch.snapshot);
      let records =
        Journal_store.scan (journal_store root)
        |> require_ok Journal_store.error_to_string
      in
      Alcotest.(check int)
        "journal retains every recovery generation" 5 (List.length records);
      let repeated = recover root bootstrap_repository operation in
      Alcotest.(check bool)
        "published recovery is idempotent" true
        (Journal.phase (Recovery.journal repeated) = Journal.Published))
  [@warning "-4"]

let divergent_worktree_after_preparation_is_not_published () =
  with_repository (fun root bootstrap_repository scratch ->
      let work = Filename.concat root "work" in
      write_file work "target";
      let target = publish_scan root scratch '1' '2' in
      write_file work "observed";
      let operation = operation_id 's' in
      ignore (prepare root bootstrap_repository target operation);
      write_file work "external";
      match
        Recovery.resume ~root ~bootstrap_repository ~operation_id:operation
          ~post_snapshot_nonce:(nonce '5') ~post_ledger_nonce:(nonce '6')
      with
      | Error (Recovery.Materializer_error (Materializer.Stale_worktree _)) ->
          Alcotest.(check string)
            "external bytes remain untouched" "external"
            (In_channel.with_open_bin work In_channel.input_all);
          let records =
            Journal_store.scan (journal_store root)
            |> require_ok Journal_store.error_to_string
          in
          Alcotest.(check int)
            "no recovery generation is appended" 2 (List.length records)
      | Error error ->
          Alcotest.failf "expected stale-worktree rejection, received: %s"
            (Recovery.error_to_string error)
      | Ok _ -> Alcotest.fail "external worktree was published")
  [@warning "-4"]

let target_event_binding_is_reverified_before_resume () =
  with_repository (fun root bootstrap_repository scratch ->
      let work = Filename.concat root "work" in
      write_file work "target";
      let target = publish_scan root scratch '1' '2' in
      write_file work "observed";
      let prepared =
        prepare root bootstrap_repository target (operation_id 'o')
      in
      let safety = Preparation.safety_checkpoint prepared in
      let forged =
        Journal.make_prepared ~repository_id ~operation_id:(operation_id 'f')
          ~safety_event_id:safety.Scratch.event_id
          ~target_event_id:safety.Scratch.event_id
          ~safety_snapshot:safety.Scratch.snapshot_ref
          ~target_snapshot:target.Scratch.snapshot_ref ~action_count:1
          ~mandatory_features:0L
        |> require_ok Journal.error_to_string
      in
      let applying =
        Journal.advance forged (Journal.Applying 0)
        |> require_ok Journal.error_to_string
      in
      ignore
        (Journal_store.append (journal_store root) forged
        |> require_ok Journal_store.error_to_string);
      ignore
        (Journal_store.append (journal_store root) applying
        |> require_ok Journal_store.error_to_string);
      match
        Recovery.resume ~root ~bootstrap_repository
          ~operation_id:(operation_id 'f') ~post_snapshot_nonce:(nonce '5')
          ~post_ledger_nonce:(nonce '6')
      with
      | Error Recovery.Target_reference_mismatch ->
          Alcotest.(check string)
            "unverified target is never materialised" "observed"
            (In_channel.with_open_bin work In_channel.input_all)
      | Error error ->
          Alcotest.failf "expected target binding rejection, received: %s"
            (Recovery.error_to_string error)
      | Ok _ -> Alcotest.fail "mismatched target event was accepted")
  [@warning "-4"]

let () =
  Alcotest.run "V2 authenticated restore recovery"
    [
      ( "unit",
        [
          Alcotest.test_case "post-write restart publishes target" `Quick
            post_write_restart_reconciles_and_publishes_the_target;
          Alcotest.test_case "external root is not published" `Quick
            divergent_worktree_after_preparation_is_not_published;
          Alcotest.test_case "target event binding is reverified" `Quick
            target_event_binding_is_reverified_before_resume;
        ] );
    ]
