module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Envelope = Yeokcham_v2_envelope
module Ledger = Yeokcham_v2_ledger
module Ledger_store = Yeokcham_v2_ledger_store
module Model = Yeokcham_model
module Object = Yeokcham_v2_object
module Object_store = Yeokcham_v2_object_store
module Retention = Yeokcham_v2_retention
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

let object_store root =
  Object_store.open_repository ~root ~repository_id ~address_key ~encryption_key
  |> require_ok Object_store.error_to_string

let ledger_store root =
  let public_keys =
    Bootstrap.public_key_registry capability
    |> require_ok Bootstrap.error_to_string
  in
  Ledger_store.open_repository ~root ~repository_id ~address_key ~encryption_key
    ~public_keys
  |> require_ok Ledger_store.error_to_string

let published_ref = function
  | Object_store.Published object_ref
  | Object_store.Already_published object_ref ->
      object_ref

let publish_frame root ~frame ~nonce_value =
  let envelope =
    Envelope.seal ~key:encryption_key ~nonce:nonce_value ~mandatory_features:0L
      (Object.encode frame)
    |> require_ok Envelope.error_to_string
  in
  Object_store.publish (object_store root) ~envelope
  |> require_ok Object_store.error_to_string
  |> published_ref

let publish_ledger_event root ~ref_name ~predecessor ~target ~nonce_value =
  let unsigned =
    Ledger.make_unsigned ~repository_id ~ref_name
      ~signer_key_id:(Bootstrap.capability_signer_key_id capability)
      ~predecessor
      ~target:(Some (Ledger.Ref_target.of_opaque_object_ref target))
      ~mandatory_features:0L
    |> require_ok Ledger.error_to_string
  in
  let event =
    Ledger.make ~unsigned ~algorithm:Ledger.algorithm
      ~signature:(Bootstrap.sign_ledger capability unsigned)
    |> require_ok Ledger.error_to_string
  in
  let envelope =
    Envelope.seal ~key:encryption_key ~nonce:nonce_value ~mandatory_features:0L
      (Object.ledger_event event |> Object.encode)
    |> require_ok Envelope.error_to_string
  in
  ignore
    (Ledger_store.publish (ledger_store root) ~envelope
    |> require_ok Ledger_store.error_to_string);
  Ledger.event_id event

let prepare_generation root scratch source ~compact_nonce ~manifest_nonce =
  let source_ref = Scratch.scratch_ref_name scratch in
  let active_ref =
    Scratch.compact_ref_name scratch ~source_head:source.Scratch.event_id
    |> require_ok Scratch.error_to_string
  in
  let active_anchor =
    publish_ledger_event root ~ref_name:active_ref ~predecessor:None
      ~target:source.Scratch.snapshot_ref ~nonce_value:compact_nonce
  in
  let generation =
    Retention.make_generation ~source_ref ~source_head:source.Scratch.event_id
      ~active_ref ~active_anchor ~retired_refs:[ source_ref ]
      ~cleanup_candidates:[]
    |> require_ok Retention.error_to_string
  in
  let manifest_ref =
    publish_frame root
      ~frame:(Object.scratch_generation generation)
      ~nonce_value:manifest_nonce
  in
  (active_ref, active_anchor, manifest_ref)

let activate_generation root scratch ~manifest_ref ~nonce_value =
  publish_ledger_event root
    ~ref_name:(Scratch.generation_ref_name scratch)
    ~predecessor:None ~target:manifest_ref ~nonce_value

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

let generation_activation_preserves_exact_snapshot_and_redirects_publication ()
    =
  with_repository (fun root bootstrap_repository scratch ->
      let retained = snapshot "retained\000bytes" in
      let source =
        match publish scratch retained '1' '2' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "initial scratch was unchanged"
      in
      let active_ref, active_anchor, manifest_ref =
        prepare_generation root scratch source ~compact_nonce:(nonce '3')
          ~manifest_nonce:(nonce '4')
      in
      let before_activation =
        Scratch.inspect scratch
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      Alcotest.(check bool)
        "unpublished generation manifest leaves the base checkpoint active" true
        (Ledger.Event_id.equal source.Scratch.event_id
           before_activation.Scratch.event_id);
      ignore
        (activate_generation root scratch ~manifest_ref ~nonce_value:(nonce '5'));
      let active =
        Scratch.active_scratch_ref_name scratch
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check string)
        "generation selects the declared compact scope"
        (Ledger.Ref_name.to_string active_ref)
        (Ledger.Ref_name.to_string active);
      let activated =
        Scratch.inspect scratch
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      Alcotest.(check bool)
        "activated compact head is exact" true
        (Ledger.Event_id.equal active_anchor activated.Scratch.event_id);
      Alcotest.(check bool)
        "activated compact checkpoint reuses exact retained bytes" true
        (Model.Snapshot.equal retained activated.Scratch.snapshot);
      let reopened =
        Scratch.open_repository ~root ~bootstrap_repository
        |> require_ok Scratch.error_to_string
      in
      let reopened_checkpoint =
        Scratch.inspect reopened
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      Alcotest.(check bool)
        "reopened generation remains the exact active checkpoint" true
        (Ledger.Event_id.equal active_anchor
           reopened_checkpoint.Scratch.event_id);
      let updated = snapshot "updated-after-generation" in
      let published =
        match publish reopened updated '6' '7' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "updated scratch was unchanged"
      in
      let current =
        Scratch.inspect reopened
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      Alcotest.(check bool)
        "post-activation publication extends the compact scope" true
        (Ledger.Event_id.equal published.Scratch.event_id
           current.Scratch.event_id);
      Alcotest.(check bool)
        "post-activation publication preserves new exact bytes" true
        (Model.Snapshot.equal updated current.Scratch.snapshot);
      let retired_event_is_outside =
       (function
       | Scratch.Event_outside_scratch_scope event_id ->
           Ledger.Event_id.equal event_id source.Scratch.event_id
       | _ -> false)
       [@warning "-4"]
      in
      match
        Scratch.checkpoint_for_event reopened ~event_id:source.Scratch.event_id
      with
      | Error error when retired_event_is_outside error -> ()
      | Error error ->
          Alcotest.failf "wrong retired-event error: %s"
            (Scratch.error_to_string error)
      | Ok _ -> Alcotest.fail "retired source event remained active")

let malformed_generation_refuses_activation () =
  with_repository (fun root _ scratch ->
      let source =
        match publish scratch (snapshot "source") '1' '2' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "initial scratch was unchanged"
      in
      let source_ref = Scratch.scratch_ref_name scratch in
      let wrong_active_ref =
        Ledger.Ref_name.of_string "scratch-compact-wrong-device"
        |> require_ok Fun.id
      in
      let generation =
        Retention.make_generation ~source_ref
          ~source_head:source.Scratch.event_id ~active_ref:wrong_active_ref
          ~active_anchor:source.Scratch.event_id ~retired_refs:[ source_ref ]
          ~cleanup_candidates:[]
        |> require_ok Retention.error_to_string
      in
      let manifest_ref =
        publish_frame root
          ~frame:(Object.scratch_generation generation)
          ~nonce_value:(nonce '3')
      in
      ignore
        (activate_generation root scratch ~manifest_ref ~nonce_value:(nonce '4'));
      let active_ref_is_malformed =
       (function
       | Scratch.Generation_active_ref_mismatch _ -> true
       | _ -> false)
       [@warning "-4"]
      in
      match Scratch.inspect scratch with
      | Error error when active_ref_is_malformed error -> ()
      | Error error ->
          Alcotest.failf "wrong malformed-generation error: %s"
            (Scratch.error_to_string error)
      | Ok _ -> Alcotest.fail "malformed generation selected an active scope")

let generation_anchor_must_remain_ancestral () =
  with_repository (fun root _ scratch ->
      let source =
        match publish scratch (snapshot "source") '1' '2' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "initial scratch was unchanged"
      in
      let source_ref = Scratch.scratch_ref_name scratch in
      let active_ref =
        Scratch.compact_ref_name scratch ~source_head:source.Scratch.event_id
        |> require_ok Scratch.error_to_string
      in
      ignore
        (publish_ledger_event root ~ref_name:active_ref ~predecessor:None
           ~target:source.Scratch.snapshot_ref ~nonce_value:(nonce '3'));
      let generation =
        Retention.make_generation ~source_ref
          ~source_head:source.Scratch.event_id ~active_ref
          ~active_anchor:source.Scratch.event_id ~retired_refs:[ source_ref ]
          ~cleanup_candidates:[]
        |> require_ok Retention.error_to_string
      in
      let manifest_ref =
        publish_frame root
          ~frame:(Object.scratch_generation generation)
          ~nonce_value:(nonce '4')
      in
      ignore
        (activate_generation root scratch ~manifest_ref ~nonce_value:(nonce '5'));
      let anchor_is_not_ancestral =
       (function
       | Scratch.Generation_active_anchor_not_reachable _ -> true
       | _ -> false)
       [@warning "-4"]
      in
      match Scratch.inspect scratch with
      | Error error when anchor_is_not_ancestral error -> ()
      | Error error ->
          Alcotest.failf "wrong inactive-anchor error: %s"
            (Scratch.error_to_string error)
      | Ok _ -> Alcotest.fail "generation accepted an unrelated active anchor")

let divergent_generation_heads_remain_explicit () =
  with_repository (fun root _ scratch ->
      let source =
        match publish scratch (snapshot "source") '1' '2' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "initial scratch was unchanged"
      in
      let source_ref = Scratch.scratch_ref_name scratch in
      let wrong_active_ref =
        Ledger.Ref_name.of_string "scratch-compact-wrong-device"
        |> require_ok Fun.id
      in
      let generation =
        Retention.make_generation ~source_ref
          ~source_head:source.Scratch.event_id ~active_ref:wrong_active_ref
          ~active_anchor:source.Scratch.event_id ~retired_refs:[ source_ref ]
          ~cleanup_candidates:[]
        |> require_ok Retention.error_to_string
      in
      let first_manifest =
        publish_frame root
          ~frame:(Object.scratch_generation generation)
          ~nonce_value:(nonce '3')
      in
      let second_manifest =
        publish_frame root
          ~frame:(Object.scratch_generation generation)
          ~nonce_value:(nonce '4')
      in
      ignore
        (activate_generation root scratch ~manifest_ref:first_manifest
           ~nonce_value:(nonce '5'));
      ignore
        (activate_generation root scratch ~manifest_ref:second_manifest
           ~nonce_value:(nonce '6'));
      let has_divergent_generation_heads =
       (function
       | Scratch.Divergent_generation_heads heads -> List.length heads = 2
       | _ -> false)
       [@warning "-4"]
      in
      match Scratch.inspect scratch with
      | Error error when has_divergent_generation_heads error -> ()
      | Error error ->
          Alcotest.failf "wrong divergent-generation error: %s"
            (Scratch.error_to_string error)
      | Ok _ -> Alcotest.fail "divergent generation selected an active scope")

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
          Alcotest.test_case
            "generation activation preserves exact bytes and redirects \
             publication"
            `Quick
            generation_activation_preserves_exact_snapshot_and_redirects_publication;
          Alcotest.test_case "malformed generation refuses activation" `Quick
            malformed_generation_refuses_activation;
          Alcotest.test_case "generation anchor remains ancestral" `Quick
            generation_anchor_must_remain_ancestral;
          Alcotest.test_case "divergent generation heads remain explicit" `Quick
            divergent_generation_heads_remain_explicit;
          Alcotest.test_case "divergent heads refuse automatic publication"
            `Quick divergent_heads_refuse_automatic_publication;
          Alcotest.test_case "exact scan service publishes only changes" `Quick
            exact_scan_service_publishes_only_changes;
        ] );
    ]
