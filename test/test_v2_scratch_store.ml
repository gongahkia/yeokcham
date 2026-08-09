module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_model
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store
module Scratch = Yeokcham_v2_scratch_store
module Scratch_service = Yeokcham_v2_scratch_service
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

let path components =
  Model.Path.of_components components |> require_ok Model.Path.error_to_string

let snapshot content =
  Model.Snapshot.of_entries
    [
      Model.Directory_path (path [ "nested" ]);
      Model.File_path
        (path [ "nested"; "file" ], { Model.mode = Model.Executable; content });
      Model.File_path
        (path [ "link" ], { Model.mode = Model.Symlink; content = "target\000" });
    ]
  |> require_ok Model.construction_error_to_string

let nonce character =
  Envelope.nonce_of_bytes (String.make 12 character)
  |> require_ok Envelope.error_to_string

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
  let root = Filename.temp_file "yeokcham-v2-scratch-store-" "" in
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

let checkpoint = function
  | Scratch.Checkpoint checkpoint -> checkpoint
  | Scratch.No_checkpoint ->
      Alcotest.fail "scratch checkpoint unexpectedly absent"
  | Scratch.Divergent_checkpoints _ ->
      Alcotest.fail "scratch checkpoint diverged"

let publish scratch snapshot snapshot_nonce ledger_nonce =
  Scratch.publish scratch ~snapshot ~snapshot_nonce:(nonce snapshot_nonce)
    ~ledger_nonce:(nonce ledger_nonce)
  |> require_ok Scratch.error_to_string

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let initial_change_unchanged_and_reopen () =
  with_repository (fun root bootstrap_repository scratch ->
      let initial = snapshot "initial" in
      let first = publish scratch initial '1' '2' in
      let first =
        match first with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "initial snapshot was unchanged"
      in
      Alcotest.(check string)
        "device scope is deterministic"
        ("scratch-" ^ V2_model.Device_id.to_hex device_id)
        (Scratch.scratch_ref_name scratch |> Ledger.Ref_name.to_string);
      let before =
        In_channel.with_open_bin
          (Bootstrap_store.bootstrap_path ~root)
          In_channel.input_all
      in
      let unchanged = publish scratch initial '3' '4' in
      (match unchanged with
      | Scratch.Unchanged checkpoint ->
          Alcotest.(check bool)
            "unchanged scan keeps checkpoint" true
            (Ledger.Event_id.equal first.Scratch.event_id
               checkpoint.Scratch.event_id)
      | Scratch.Published _ -> Alcotest.fail "unchanged snapshot published");
      let after =
        In_channel.with_open_bin
          (Bootstrap_store.bootstrap_path ~root)
          In_channel.input_all
      in
      Alcotest.(check string)
        "unchanged scan writes no bootstrap state" before after;
      let changed = snapshot "changed\000bytes" in
      let second = publish scratch changed '5' '6' in
      let second =
        match second with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "changed snapshot was unchanged"
      in
      Alcotest.(check bool)
        "changed snapshot extends causal event" false
        (Ledger.Event_id.equal first.Scratch.event_id second.Scratch.event_id);
      let reopened =
        Scratch.open_repository ~root ~bootstrap_repository
        |> require_ok Scratch.error_to_string
      in
      let restored =
        Scratch.inspect reopened
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      Alcotest.(check bool)
        "reopen returns exact latest snapshot" true
        (Model.Snapshot.equal changed restored.Scratch.snapshot))

let snapshot_first_interruption_resumes_without_moving_head () =
  with_repository (fun root bootstrap_repository scratch ->
      let initial = snapshot "initial" in
      let old =
        match publish scratch initial '1' '2' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "initial snapshot was unchanged"
      in
      let changed = snapshot "changed" in
      let plan =
        Scratch.plan scratch ~snapshot:changed ~snapshot_nonce:(nonce '3')
          ~ledger_nonce:(nonce '4')
        |> require_ok Scratch.error_to_string
      in
      let snapshot_envelope =
        match plan with
        | Scratch.Publish_plan { snapshot_envelope; _ } -> snapshot_envelope
        | Scratch.Unchanged_plan _ ->
            Alcotest.fail "changed snapshot planned no write"
      in
      let objects =
        Object_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key
        |> require_ok Object_store.error_to_string
      in
      ignore
        (Object_store.publish objects ~envelope:snapshot_envelope
        |> require_ok Object_store.error_to_string);
      let before_resume =
        Scratch.inspect scratch
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      Alcotest.(check bool)
        "snapshot-only interruption retains old head" true
        (Ledger.Event_id.equal old.Scratch.event_id
           before_resume.Scratch.event_id);
      let resumed =
        Scratch.publish_plan scratch plan |> require_ok Scratch.error_to_string
      in
      let resumed =
        match resumed with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "resumed plan was unchanged"
      in
      Alcotest.(check bool)
        "resumed candidate preserves planned exact snapshot" true
        (Model.Snapshot.equal changed resumed.Scratch.snapshot);
      let reopened =
        Scratch.open_repository ~root ~bootstrap_repository
        |> require_ok Scratch.error_to_string
      in
      let restored =
        Scratch.inspect reopened
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      Alcotest.(check bool)
        "reopened resumed checkpoint is exact" true
        (Model.Snapshot.equal changed restored.Scratch.snapshot))

let divergent_heads_refuse_automatic_publication () =
  with_repository (fun root _ scratch ->
      let initial = snapshot "initial" in
      let root_checkpoint =
        match publish scratch initial '1' '2' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "initial snapshot was unchanged"
      in
      let left = snapshot "left" in
      ignore (publish scratch left '3' '4');
      let objects =
        Object_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key
        |> require_ok Object_store.error_to_string
      in
      let right = snapshot "right" in
      let right_envelope =
        Envelope.seal ~key:encryption_key ~nonce:(nonce '5')
          ~mandatory_features:0L
          (Object.scratch_snapshot right |> Object.encode)
        |> require_ok Envelope.error_to_string
      in
      let right_ref =
        Object_store.publish objects ~envelope:right_envelope
        |> require_ok Object_store.error_to_string
        |> function
        | Object_store.Published object_ref
        | Object_store.Already_published object_ref ->
            object_ref
      in
      let scratch_ref = Scratch.scratch_ref_name scratch in
      let unsigned =
        Ledger.make_unsigned ~repository_id ~ref_name:scratch_ref
          ~signer_key_id:(Bootstrap.capability_signer_key_id capability)
          ~predecessor:(Some root_checkpoint.Scratch.event_id)
          ~target:(Some (Ledger.Ref_target.of_opaque_object_ref right_ref))
          ~mandatory_features:0L
        |> require_ok Ledger.error_to_string
      in
      let event =
        Ledger.make ~unsigned ~algorithm:Ledger.algorithm
          ~signature:(Bootstrap.sign_ledger capability unsigned)
        |> require_ok Ledger.error_to_string
      in
      let alternative_envelope =
        Envelope.seal ~key:encryption_key ~nonce:(nonce '6')
          ~mandatory_features:0L
          (Object.ledger_event event |> Object.encode)
        |> require_ok Envelope.error_to_string
      in
      let public_keys =
        Bootstrap.public_key_registry capability
        |> require_ok Bootstrap.error_to_string
      in
      let ledger =
        Ledger_store.open_repository ~root ~repository_id ~address_key
          ~encryption_key ~public_keys
        |> require_ok Ledger_store.error_to_string
      in
      ignore
        (Ledger_store.publish ledger ~envelope:alternative_envelope
        |> require_ok Ledger_store.error_to_string);
      (match Scratch.inspect scratch |> require_ok Scratch.error_to_string with
      | Scratch.Divergent_checkpoints heads ->
          Alcotest.(check int)
            "two causal heads remain explicit" 2 (List.length heads)
      | Scratch.No_checkpoint | Scratch.Checkpoint _ ->
          Alcotest.fail "divergent scratch scope was collapsed");
      (match
         Scratch.publish scratch ~snapshot:(snapshot "new")
           ~snapshot_nonce:(nonce '7') ~ledger_nonce:(nonce '8')
       with
      | Error (Scratch.Divergent_scratch_heads _) -> ()
      | Ok _ -> Alcotest.fail "divergent scratch scope published automatically"
      | Error error ->
          Alcotest.failf "wrong divergent publication error: %s"
            (Scratch.error_to_string error))
      [@warning "-4"])

let exact_scan_service_publishes_only_changes () =
  with_repository (fun root bootstrap_repository scratch ->
      let file = Filename.concat root "work" in
      write_file file "first\000bytes";
      let first =
        Scratch_service.scan_and_publish ~root ~bootstrap_repository
          ~snapshot_nonce:(nonce '1') ~ledger_nonce:(nonce '2')
        |> require_ok Scratch_service.error_to_string
      in
      (match first with
      | Scratch.Published _ -> ()
      | Scratch.Unchanged _ -> Alcotest.fail "first exact scan was unchanged");
      let unchanged =
        Scratch_service.scan_and_publish ~root ~bootstrap_repository
          ~snapshot_nonce:(nonce '3') ~ledger_nonce:(nonce '4')
        |> require_ok Scratch_service.error_to_string
      in
      (match unchanged with
      | Scratch.Unchanged _ -> ()
      | Scratch.Published _ -> Alcotest.fail "unchanged exact scan published");
      write_file file "second\000bytes";
      let changed =
        Scratch_service.scan_and_publish ~root ~bootstrap_repository
          ~snapshot_nonce:(nonce '5') ~ledger_nonce:(nonce '6')
        |> require_ok Scratch_service.error_to_string
      in
      (match changed with
      | Scratch.Published _ -> ()
      | Scratch.Unchanged _ -> Alcotest.fail "changed exact scan was unchanged");
      let checkpoint =
        Scratch.inspect scratch
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      let expected =
        Model.Snapshot.of_entries
          [
            Model.File_path
              ( path [ "work" ],
                { Model.mode = Model.Regular; content = "second\000bytes" } );
          ]
        |> require_ok Model.construction_error_to_string
      in
      Alcotest.(check bool)
        "scan service publishes the latest exact bytes" true
        (Model.Snapshot.equal expected checkpoint.Scratch.snapshot))

let () =
  Alcotest.run "V2 local scratch publication"
    [
      ( "unit",
        [
          Alcotest.test_case "initial, changed, unchanged, and reopen" `Quick
            initial_change_unchanged_and_reopen;
          Alcotest.test_case "snapshot-first interruption resumes safely" `Quick
            snapshot_first_interruption_resumes_without_moving_head;
          Alcotest.test_case "divergent heads refuse automatic publication"
            `Quick divergent_heads_refuse_automatic_publication;
          Alcotest.test_case "exact scan service publishes only changes" `Quick
            exact_scan_service_publishes_only_changes;
        ] );
    ]
