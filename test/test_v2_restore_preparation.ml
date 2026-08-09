module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Journal = Yeokcham_v2_restore_journal
module Journal_store = Yeokcham_v2_restore_journal_store
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
  let root = Filename.temp_file "yeokcham-v2-restore-preparation-" "" in
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

let checkpoint = function
  | Scratch.Checkpoint checkpoint -> checkpoint
  | Scratch.No_checkpoint ->
      Alcotest.fail "scratch checkpoint unexpectedly absent"
  | Scratch.Divergent_checkpoints _ -> Alcotest.fail "scratch scope diverged"

let selected_target_is_verified_without_head_selection () =
  with_repository (fun root _ scratch ->
      let work = Filename.concat root "work" in
      write_file work "target";
      let target = publish_scan root scratch '1' '2' in
      let selected =
        Scratch.checkpoint_for_event scratch ~event_id:target.Scratch.event_id
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check bool)
        "selected snapshot is exact" true
        (Model.Snapshot.equal target.Scratch.snapshot selected.Scratch.snapshot);
      let unknown =
        V2_model.Ref_event_id.of_bytes (String.make 32 'u')
        |> require_ok V2_model.identity_error_to_string
      in
      Alcotest.(check bool)
        "unknown target event rejects" true
        (Result.is_error
           (Scratch.checkpoint_for_event scratch ~event_id:unknown)))

let preparation_safety_checkpoints_before_journal_start () =
  with_repository (fun root bootstrap_repository scratch ->
      let work = Filename.concat root "work" in
      write_file work "target\000bytes";
      Unix.chmod work 0o755;
      let target = publish_scan root scratch '1' '2' in
      write_file work "observed\000bytes";
      Unix.chmod work 0o644;
      let result =
        Preparation.prepare ~root ~bootstrap_repository
          ~target_event_id:target.Scratch.event_id
          ~operation_id:(operation_id 'o') ~safety_snapshot_nonce:(nonce '3')
          ~safety_ledger_nonce:(nonce '4')
        |> require_ok Preparation.error_to_string
      in
      let prepared =
        match result with
        | Preparation.Prepared prepared -> prepared
        | Preparation.Noop _ -> Alcotest.fail "changed tree prepared as a no-op"
      in
      let safety = Preparation.safety_checkpoint prepared in
      let observed = Scanner.scan ~root |> require_ok Scanner.error_to_string in
      Alcotest.(check bool)
        "safety snapshot equals untouched observed tree" true
        (Model.Snapshot.equal observed safety.Scratch.snapshot);
      Alcotest.(check string)
        "preparation does not materialise worktree" "observed\000bytes"
        (read_file work);
      Alcotest.(check int)
        "changed target has materialisation actions" 1
        (List.length
           (Yeokcham_v2_restore_plan.actions (Preparation.plan prepared)));
      Alcotest.(check int64)
        "journal reaches pre-action generation" 1L
        (Journal.generation (Preparation.journal prepared));
      Alcotest.(check bool)
        "journal is applying zero" true
        (Journal.phase (Preparation.journal prepared) = Journal.Applying 0);
      let journal_store =
        Journal_store.open_repository ~root ~repository_id
        |> require_ok Journal_store.error_to_string
      in
      let records =
        Journal_store.scan journal_store
        |> require_ok Journal_store.error_to_string
      in
      Alcotest.(check int)
        "prepared and pre-action generations are durable" 2
        (List.length records);
      let current =
        Scratch.inspect scratch
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      Alcotest.(check bool)
        "safety event is the causal scratch head" true
        (Scratch.Ledger.Event_id.equal current.Scratch.event_id
           safety.Scratch.event_id);
      match
        Preparation.prepare ~root ~bootstrap_repository
          ~target_event_id:target.Scratch.event_id
          ~operation_id:(operation_id 'o') ~safety_snapshot_nonce:(nonce '5')
          ~safety_ledger_nonce:(nonce '6')
      with
      | Error (Preparation.Operation_already_exists record) ->
          Alcotest.(check int64)
            "existing operation reports latest generation" 1L
            (Journal.generation record)
      | Error error ->
          Alcotest.failf "reused operation returned wrong error: %s"
            (Preparation.error_to_string error)
      | Ok _ -> Alcotest.fail "reused operation was silently reused")
  [@warning "-4"]

let equal_target_is_a_noop_without_journal_or_checkpoint () =
  with_repository (fun root bootstrap_repository scratch ->
      let work = Filename.concat root "work" in
      write_file work "target";
      let target = publish_scan root scratch '1' '2' in
      let outcome =
        Preparation.prepare ~root ~bootstrap_repository
          ~target_event_id:target.Scratch.event_id
          ~operation_id:(operation_id 'n') ~safety_snapshot_nonce:(nonce '3')
          ~safety_ledger_nonce:(nonce '4')
        |> require_ok Preparation.error_to_string
      in
      (match outcome with
      | Preparation.Noop checkpoint ->
          Alcotest.(check bool)
            "no-op returns named target" true
            (Scratch.Ledger.Event_id.equal checkpoint.Scratch.event_id
               target.Scratch.event_id)
      | Preparation.Prepared _ -> Alcotest.fail "equal target prepared writes");
      let journal_store =
        Journal_store.open_repository ~root ~repository_id
        |> require_ok Journal_store.error_to_string
      in
      let records =
        Journal_store.scan journal_store
        |> require_ok Journal_store.error_to_string
      in
      Alcotest.(check int)
        "no-op writes no restore journal" 0 (List.length records);
      let current =
        Scratch.inspect scratch
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      Alcotest.(check bool)
        "no-op leaves scratch head unchanged" true
        (Scratch.Ledger.Event_id.equal current.Scratch.event_id
           target.Scratch.event_id))

let () =
  Alcotest.run "V2 guarded restore preparation"
    [
      ( "unit",
        [
          Alcotest.test_case
            "selected target is verified without head selection" `Quick
            selected_target_is_verified_without_head_selection;
          Alcotest.test_case
            "safety checkpoint precedes durable pre-action journal" `Quick
            preparation_safety_checkpoints_before_journal_start;
          Alcotest.test_case "equal target is a no-op without journal" `Quick
            equal_target_is_a_noop_without_journal_or_checkpoint;
        ] );
    ]
