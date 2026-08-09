module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Journal = Yeokcham_v2_restore_journal
module Journal_store = Yeokcham_v2_restore_journal_store
module Materializer = Yeokcham_v2_restore_materializer
module Model = Yeokcham_model
module Preparation = Yeokcham_v2_restore_preparation
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
  let root = Filename.temp_file "yeokcham-v2-restore-materializer-" "" in
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

let read_file path = In_channel.with_open_bin path In_channel.input_all

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

let materialize root prepared =
  Materializer.materialize ~root ~journal_store:(journal_store root)
    ~plan:(Preparation.plan prepared)
    ~journal:(Preparation.journal prepared)
    ()
  |> require_ok Materializer.error_to_string

let checkpoint = function
  | Scratch.Checkpoint checkpoint -> checkpoint
  | Scratch.No_checkpoint ->
      Alcotest.fail "scratch checkpoint unexpectedly absent"
  | Scratch.Divergent_checkpoints _ ->
      Alcotest.fail "scratch checkpoint diverged"

let exact_action_applier_preserves_bytes_modes_paths_and_symlink_targets () =
  with_repository (fun root bootstrap_repository scratch ->
      let mode_file = Filename.concat root "mode" in
      let link = Filename.concat root "link" in
      let target_directory = Filename.concat root "target-directory" in
      let target_file = Filename.concat target_directory "nested" in
      Unix.mkdir target_directory 0o755;
      write_file target_file "target\000bytes";
      Unix.chmod target_file 0o755;
      write_file mode_file "same";
      Unix.chmod mode_file 0o755;
      Unix.symlink "../raw-target" link;
      let target = publish_scan root scratch '1' '2' in
      Unix.unlink target_file;
      Unix.rmdir target_directory;
      Unix.unlink link;
      write_file link "replaced regular file";
      Unix.chmod mode_file 0o644;
      write_file (Filename.concat root "obsolete") "delete me";
      let old_directory = Filename.concat root "obsolete-directory" in
      Unix.mkdir old_directory 0o755;
      write_file (Filename.concat old_directory "child") "delete me too";
      let prepared =
        prepare root bootstrap_repository target (operation_id 'o')
      in
      let result = materialize root prepared in
      let actual = Scanner.scan ~root |> require_ok Scanner.error_to_string in
      Alcotest.(check bool)
        "materialised scan equals selected target" true
        (Model.Snapshot.equal actual target.Scratch.snapshot);
      Alcotest.(check string)
        "restored bytes" "target\000bytes" (read_file target_file);
      Alcotest.(check bool)
        "restored executable mode" true
        ((Unix.lstat target_file).Unix.st_perm land 0o111 <> 0);
      Alcotest.(check bool)
        "mode-only change is executable" true
        ((Unix.lstat mode_file).Unix.st_perm land 0o111 <> 0);
      Alcotest.(check string)
        "raw symlink target survives" "../raw-target" (Unix.readlink link);
      Alcotest.(check bool)
        "obsolete file removed" false
        (Sys.file_exists (Filename.concat root "obsolete"));
      Alcotest.(check bool)
        "obsolete directory removed" false
        (Sys.file_exists old_directory);
      Alcotest.(check bool)
        "journal is materialized" true
        (Journal.phase result.Materializer.journal = Journal.Materialized);
      let records =
        Journal_store.scan (journal_store root)
        |> require_ok Journal_store.error_to_string
      in
      Alcotest.(check int)
        "one journal generation per action plus terminal"
        (List.length
           (Yeokcham_v2_restore_plan.actions (Preparation.plan prepared))
        + 3)
        (List.length records))

let stale_worktree_rejects_before_the_first_write () =
  with_repository (fun root bootstrap_repository scratch ->
      let work = Filename.concat root "work" in
      write_file work "target";
      let target = publish_scan root scratch '1' '2' in
      write_file work "observed";
      let prepared =
        prepare root bootstrap_repository target (operation_id 's')
      in
      write_file work "external change";
      match
        Materializer.materialize ~root ~journal_store:(journal_store root)
          ~plan:(Preparation.plan prepared)
          ~journal:(Preparation.journal prepared)
          ()
      with
      | Error (Materializer.Stale_worktree _) ->
          Alcotest.(check string)
            "external bytes remain untouched" "external change" (read_file work);
          let records =
            Journal_store.scan (journal_store root)
            |> require_ok Journal_store.error_to_string
          in
          Alcotest.(check int)
            "no action generation is appended" 2 (List.length records)
      | Error error ->
          Alcotest.failf "expected stale-worktree rejection, received: %s"
            (Materializer.error_to_string error)
      | Ok _ -> Alcotest.fail "stale worktree was materialised")
  [@warning "-4"]

let injected_post_write_interruption_retains_safety_and_pre_action_journal () =
  with_repository (fun root bootstrap_repository scratch ->
      let work = Filename.concat root "work" in
      write_file work "target";
      let target = publish_scan root scratch '1' '2' in
      write_file work "observed";
      let prepared =
        prepare root bootstrap_repository target (operation_id 'i')
      in
      match
        Materializer.materialize
          ~fault:(Materializer.Fault.interrupt_after_action 1)
          ~root ~journal_store:(journal_store root)
          ~plan:(Preparation.plan prepared)
          ~journal:(Preparation.journal prepared)
          ()
      with
      | Error (Materializer.Injected_interruption { completed_actions = 1 }) ->
          Alcotest.(check string)
            "the completed filesystem action remains" "target" (read_file work);
          let records =
            Journal_store.scan (journal_store root)
            |> require_ok Journal_store.error_to_string
          in
          Alcotest.(check int)
            "progress record was not appended" 2 (List.length records);
          let safety = Preparation.safety_checkpoint prepared in
          let current =
            Scratch.inspect scratch
            |> require_ok Scratch.error_to_string
            |> checkpoint
          in
          Alcotest.(check bool)
            "safety remains the causal checkpoint" true
            (Scratch.Ledger.Event_id.equal current.Scratch.event_id
               safety.Scratch.event_id)
      | Error error ->
          Alcotest.failf "expected injected interruption, received: %s"
            (Materializer.error_to_string error)
      | Ok _ ->
          Alcotest.fail "injected interruption did not stop materialisation")
  [@warning "-4"]

let () =
  Alcotest.run "V2 restore materializer"
    [
      ( "unit",
        [
          Alcotest.test_case "exact files, modes, paths, and symlinks" `Quick
            exact_action_applier_preserves_bytes_modes_paths_and_symlink_targets;
          Alcotest.test_case "stale working tree rejects before writes" `Quick
            stale_worktree_rejects_before_the_first_write;
          Alcotest.test_case "post-write interruption retains safety state"
            `Quick
            injected_post_write_interruption_retains_safety_and_pre_action_journal;
        ] );
    ]
