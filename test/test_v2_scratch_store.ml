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

let retention_policy ~recent_count =
  Retention.make_policy ~recent_count ~storage_budget_bytes:None
  |> require_ok Retention.error_to_string

let compaction_nonces compact_ledger_nonces manifest activation =
  {
    Scratch.compact_ledger_nonces = List.map nonce compact_ledger_nonces;
    generation_manifest_nonce = nonce manifest;
    generation_ledger_nonce = nonce activation;
  }

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

let compaction_activation_preserves_selected_snapshots_and_retries () =
  with_repository (fun root bootstrap_repository scratch ->
      let oldest =
        match publish scratch (snapshot "oldest") '1' '2' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "initial scratch was unchanged"
      in
      let middle =
        match publish scratch (snapshot "middle") '3' '4' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "middle scratch was unchanged"
      in
      let current =
        match publish scratch (snapshot "current") '5' '6' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "current scratch was unchanged"
      in
      let plan =
        Scratch.plan_compaction scratch
          ~policy:(retention_policy ~recent_count:2)
          ~nonces:(compaction_nonces [ '7'; '8' ] '9' 'a')
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check int)
        "recent window builds two replacement events" 2
        (List.length plan.Scratch.compacted_events);
      Alcotest.(check int)
        "source cleanup names all source events and one expired snapshot" 4
        (List.length
           plan.Scratch.compaction_generation_manifest
             .Retention.cleanup_candidates);
      let first_compacted = List.hd plan.Scratch.compacted_events in
      ignore
        (Ledger_store.publish (ledger_store root)
           ~envelope:first_compacted.Scratch.ledger_envelope
        |> require_ok Ledger_store.error_to_string);
      let before_activation =
        Scratch.inspect scratch
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      Alcotest.(check bool)
        "durable replacement event does not change the active source" true
        (Ledger.Event_id.equal current.Scratch.event_id
           before_activation.Scratch.event_id);
      let publication =
        Scratch.publish_compaction_plan scratch plan
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check bool)
        "activation ID is the planned ID" true
        (Ledger.Event_id.equal plan.Scratch.activation_event_id
           publication.Scratch.published_generation_event_id);
      let reopened =
        Scratch.open_repository ~root ~bootstrap_repository
        |> require_ok Scratch.error_to_string
      in
      let after_activation =
        Scratch.inspect reopened
        |> require_ok Scratch.error_to_string
        |> checkpoint
      in
      Alcotest.(check bool)
        "current selected snapshot remains exact" true
        (Model.Snapshot.equal current.Scratch.snapshot
           after_activation.Scratch.snapshot);
      let compacted = plan.Scratch.compacted_events in
      match compacted with
      | [ retained_middle; retained_current ] -> (
          let restored_middle =
            Scratch.checkpoint_for_event reopened
              ~event_id:retained_middle.Scratch.compacted_event_id
            |> require_ok Scratch.error_to_string
          in
          let restored_current =
            Scratch.checkpoint_for_event reopened
              ~event_id:retained_current.Scratch.compacted_event_id
            |> require_ok Scratch.error_to_string
          in
          Alcotest.(check bool)
            "middle selected snapshot remains exact" true
            (Model.Snapshot.equal middle.Scratch.snapshot
               restored_middle.Scratch.snapshot);
          Alcotest.(check bool)
            "current replacement reuses exact bytes" true
            (Model.Snapshot.equal current.Scratch.snapshot
               restored_current.Scratch.snapshot);
          let retired_event_is_outside =
           (function
           | Scratch.Event_outside_scratch_scope _ -> true
           | _ -> false)
           [@warning "-4"]
          in
          match
            Scratch.checkpoint_for_event reopened
              ~event_id:oldest.Scratch.event_id
          with
          | Error error when retired_event_is_outside error -> ()
          | Error error ->
              Alcotest.failf "wrong retired oldest error: %s"
                (Scratch.error_to_string error)
          | Ok _ -> Alcotest.fail "expired source event remained active")
      | _ -> Alcotest.fail "compaction did not retain the expected two events")

let compaction_folds_persisted_protection_claims () =
  with_repository (fun _root _ scratch ->
      let oldest =
        match publish scratch (snapshot "oldest") '1' '2' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "initial scratch was unchanged"
      in
      let middle =
        match publish scratch (snapshot "middle") '3' '4' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "middle scratch was unchanged"
      in
      let current =
        match publish scratch (snapshot "current") '5' '6' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "current scratch was unchanged"
      in
      let claim_plan =
        Scratch.plan_protection scratch ~event_id:oldest.Scratch.event_id
          ~action:Retention.Protect ~reason:Retention.User_pin
          ~protection_nonce:(nonce '7') ~ledger_nonce:(nonce '8')
        |> require_ok Scratch.error_to_string
      in
      let claim =
        Scratch.publish_protection_plan scratch claim_plan
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check bool)
        "claim publication keeps planned identity" true
        (Ledger.Event_id.equal claim_plan.Scratch.protection_event_id
           claim.Scratch.published_protection_event_id);
      let plan =
        Scratch.plan_compaction scratch
          ~policy:(retention_policy ~recent_count:1)
          ~nonces:(compaction_nonces [ '9'; 'a' ] 'b' 'c')
        |> require_ok Scratch.error_to_string
      in
      let selected =
        plan.Scratch.compaction_retention.Retention.retained
        |> List.map (fun planned ->
            planned.Retention.checkpoint.Retention.checkpoint_snapshot_ref)
      in
      Alcotest.(check bool)
        "explicit pin survives the recent window" true
        (List.exists
           (V2_model.Opaque_object_ref.equal oldest.Scratch.snapshot_ref)
           selected);
      Alcotest.(check bool)
        "current snapshot is retained" true
        (List.exists
           (V2_model.Opaque_object_ref.equal current.Scratch.snapshot_ref)
           selected);
      Alcotest.(check bool)
        "unprotected expired snapshot is excluded" false
        (List.exists
           (V2_model.Opaque_object_ref.equal middle.Scratch.snapshot_ref)
           selected))

let protection_frame_interruption_is_inert_and_resumes () =
  with_repository (fun root _ scratch ->
      let oldest =
        match publish scratch (snapshot "oldest") '1' '2' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "initial scratch was unchanged"
      in
      ignore
        (match publish scratch (snapshot "middle") '3' '4' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "middle scratch was unchanged");
      let current =
        match publish scratch (snapshot "current") '5' '6' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "current scratch was unchanged"
      in
      let claim_plan =
        Scratch.plan_protection scratch ~event_id:oldest.Scratch.event_id
          ~action:Retention.Protect ~reason:Retention.User_pin
          ~protection_nonce:(nonce '7') ~ledger_nonce:(nonce '8')
        |> require_ok Scratch.error_to_string
      in
      ignore
        (Object_store.publish (object_store root)
           ~envelope:claim_plan.Scratch.protection_envelope
        |> require_ok Object_store.error_to_string);
      let before_resume =
        Scratch.plan_compaction scratch
          ~policy:(retention_policy ~recent_count:1)
          ~nonces:(compaction_nonces [ '9' ] 'a' 'b')
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check int)
        "unledgered claim does not affect retention" 1
        (List.length
           before_resume.Scratch.compaction_retention.Retention.retained);
      ignore
        (Scratch.publish_protection_plan scratch claim_plan
        |> require_ok Scratch.error_to_string);
      let after_resume =
        Scratch.plan_compaction scratch
          ~policy:(retention_policy ~recent_count:1)
          ~nonces:(compaction_nonces [ 'c'; 'd' ] 'e' 'f')
        |> require_ok Scratch.error_to_string
      in
      let selected =
        after_resume.Scratch.compaction_retention.Retention.retained
        |> List.map (fun planned ->
            planned.Retention.checkpoint.Retention.checkpoint_snapshot_ref)
      in
      Alcotest.(check bool)
        "resumed claim retains selected old snapshot" true
        (List.exists
           (V2_model.Opaque_object_ref.equal oldest.Scratch.snapshot_ref)
           selected);
      Alcotest.(check bool)
        "resumed claim retains current snapshot" true
        (List.exists
           (V2_model.Opaque_object_ref.equal current.Scratch.snapshot_ref)
           selected))

let protection_plan_refuses_a_stale_claim_head () =
  with_repository (fun _ _ scratch ->
      let source =
        match publish scratch (snapshot "source") '1' '2' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "initial scratch was unchanged"
      in
      let first =
        Scratch.plan_protection scratch ~event_id:source.Scratch.event_id
          ~action:Retention.Protect ~reason:Retention.User_pin
          ~protection_nonce:(nonce '3') ~ledger_nonce:(nonce '4')
        |> require_ok Scratch.error_to_string
      in
      let second =
        Scratch.plan_protection scratch ~event_id:source.Scratch.event_id
          ~action:Retention.Protect ~reason:Retention.User_pin
          ~protection_nonce:(nonce '5') ~ledger_nonce:(nonce '6')
        |> require_ok Scratch.error_to_string
      in
      ignore
        (Scratch.publish_protection_plan scratch second
        |> require_ok Scratch.error_to_string);
      let protection_head_changed =
       (function
       | Scratch.Protection_head_changed _ -> true
       | _ -> false)
       [@warning "-4"]
      in
      match Scratch.publish_protection_plan scratch first with
      | Error error when protection_head_changed error -> ()
      | Ok _ -> Alcotest.fail "stale protection plan published a fork"
      | Error error ->
          Alcotest.failf "wrong stale-claim error: %s"
            (Scratch.error_to_string error))

let compaction_refuses_to_activate_a_stale_source_plan () =
  with_repository (fun _ _ scratch ->
      ignore
        (match publish scratch (snapshot "before-plan") '1' '2' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "initial scratch was unchanged");
      let plan =
        Scratch.plan_compaction scratch
          ~policy:(retention_policy ~recent_count:1)
          ~nonces:(compaction_nonces [ '3' ] '4' '5')
        |> require_ok Scratch.error_to_string
      in
      let after_plan =
        match publish scratch (snapshot "after-plan") '6' '7' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "changed scratch was unchanged"
      in
      let source_head_changed =
       (function
       | Scratch.Compaction_source_head_changed _ -> true
       | _ -> false)
       [@warning "-4"]
      in
      match Scratch.publish_compaction_plan scratch plan with
      | Error error when source_head_changed error ->
          let active =
            Scratch.inspect scratch
            |> require_ok Scratch.error_to_string
            |> checkpoint
          in
          Alcotest.(check bool)
            "stale activation keeps newer source active" true
            (Ledger.Event_id.equal after_plan.Scratch.event_id
               active.Scratch.event_id)
      | Ok _ -> Alcotest.fail "stale compaction plan activated"
      | Error error ->
          Alcotest.failf "wrong stale-plan error: %s"
            (Scratch.error_to_string error))

let compaction_refuses_to_activate_after_protection_changes () =
  with_repository (fun root _ scratch ->
      let source =
        match publish scratch (snapshot "source") '1' '2' with
        | Scratch.Published checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "initial scratch was unchanged"
      in
      let plan =
        Scratch.plan_compaction scratch
          ~policy:(retention_policy ~recent_count:1)
          ~nonces:(compaction_nonces [ '3' ] '4' '5')
        |> require_ok Scratch.error_to_string
      in
      let claim =
        Retention.protection ~snapshot_ref:source.Scratch.snapshot_ref
          ~action:Retention.Protect ~reason:Retention.User_pin
      in
      let claim_ref =
        publish_frame root
          ~frame:(Object.scratch_protection claim)
          ~nonce_value:(nonce '6')
      in
      ignore
        (publish_ledger_event root
           ~ref_name:(Scratch.protection_ref_name scratch)
           ~predecessor:None ~target:claim_ref ~nonce_value:(nonce '7'));
      let protection_head_changed =
       (function
       | Scratch.Compaction_protection_head_changed _ -> true
       | _ -> false)
       [@warning "-4"]
      in
      match Scratch.publish_compaction_plan scratch plan with
      | Error error when protection_head_changed error ->
          let active =
            Scratch.inspect scratch
            |> require_ok Scratch.error_to_string
            |> checkpoint
          in
          Alcotest.(check bool)
            "stale activation keeps the unchanged source active" true
            (Ledger.Event_id.equal source.Scratch.event_id
               active.Scratch.event_id)
      | Ok _ -> Alcotest.fail "stale compaction plan activated"
      | Error error ->
          Alcotest.failf "wrong stale-protection error: %s"
            (Scratch.error_to_string error))

let compact_cleanup_fixture scratch =
  let oldest =
    match publish scratch (snapshot "oldest") '1' '2' with
    | Scratch.Published checkpoint -> checkpoint
    | Scratch.Unchanged _ -> Alcotest.fail "initial scratch was unchanged"
  in
  let middle =
    match publish scratch (snapshot "middle") '3' '4' with
    | Scratch.Published checkpoint -> checkpoint
    | Scratch.Unchanged _ -> Alcotest.fail "middle scratch was unchanged"
  in
  let current =
    match publish scratch (snapshot "current") '5' '6' with
    | Scratch.Published checkpoint -> checkpoint
    | Scratch.Unchanged _ -> Alcotest.fail "current scratch was unchanged"
  in
  let plan =
    Scratch.plan_compaction scratch
      ~policy:(retention_policy ~recent_count:2)
      ~nonces:(compaction_nonces [ '7'; '8' ] '9' 'a')
    |> require_ok Scratch.error_to_string
  in
  let publication =
    Scratch.publish_compaction_plan scratch plan
    |> require_ok Scratch.error_to_string
  in
  (plan, publication, [ middle; current ], oldest)

let quarantine_path root generation candidate =
  Object_store.quarantine_path (object_store root)
    ~generation:(Ledger.Event_id.to_hex generation)
    ~object_ref:candidate.Retention.candidate_object_ref
  |> require_ok Object_store.error_to_string

let assert_quarantined root generation candidates =
  let objects = object_store root in
  List.iter
    (fun candidate ->
      let source =
        Object_store.object_path objects
          candidate.Retention.candidate_object_ref
      in
      let destination = quarantine_path root generation candidate in
      Alcotest.(check bool)
        "cleanup candidate leaves the live object namespace" false
        (Sys.file_exists source);
      Alcotest.(check bool)
        "cleanup candidate enters its active-generation quarantine" true
        (Sys.file_exists destination))
    candidates

let assert_pruned root generation candidates =
  let objects = object_store root in
  List.iter
    (fun candidate ->
      let source =
        Object_store.object_path objects
          candidate.Retention.candidate_object_ref
      in
      let destination = quarantine_path root generation candidate in
      Alcotest.(check bool)
        "pruned candidate is absent from the live namespace" false
        (Sys.file_exists source);
      Alcotest.(check bool)
        "pruned candidate is absent from quarantine" false
        (Sys.file_exists destination))
    candidates

let assert_retained_compacted_snapshots scratch plan expected =
  let compacted = plan.Scratch.compacted_events in
  Alcotest.(check int)
    "selected checkpoints remain in compact history" (List.length expected)
    (List.length compacted);
  List.iter2
    (fun compacted expected ->
      let restored =
        Scratch.checkpoint_for_event scratch
          ~event_id:compacted.Scratch.compacted_event_id
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check bool)
        "retained checkpoint bytes remain exact" true
        (Model.Snapshot.equal expected.Scratch.snapshot
           restored.Scratch.snapshot))
    compacted expected

let quarantine_interruptions_resume_without_losing_retained_snapshots () =
  let cleanup_fault_injected =
   (function
   | Scratch.Cleanup_fault_injected _ -> true
   | _ -> false)
   [@warning "-4"]
  in
  let run label fault =
    with_repository (fun root bootstrap_repository scratch ->
        let plan, publication, retained, _ = compact_cleanup_fixture scratch in
        let candidates =
          publication.Scratch.published_generation_manifest
            .Retention.cleanup_candidates
        in
        Alcotest.(check int)
          (label ^ " candidate count")
          4 (List.length candidates);
        (match Scratch.resume_cleanup ~fault scratch with
        | Error error when cleanup_fault_injected error -> ()
        | Error error ->
            Alcotest.failf "%s returned the wrong cleanup error: %s" label
              (Scratch.error_to_string error)
        | Ok _ -> Alcotest.fail (label ^ " did not interrupt cleanup"));
        let reopened =
          Scratch.open_repository ~root ~bootstrap_repository
          |> require_ok Scratch.error_to_string
        in
        let resumed =
          Scratch.resume_cleanup reopened |> require_ok Scratch.error_to_string
        in
        assert_quarantined root
          publication.Scratch.published_generation_event_id candidates;
        assert_retained_compacted_snapshots reopened plan retained;
        Alcotest.(check int)
          (label ^ " resumed plus durable prior moves cover every candidate")
          (List.length candidates)
          (resumed.Scratch.quarantined_objects
         + resumed.Scratch.already_quarantined_objects);
        let repeated =
          Scratch.resume_cleanup reopened |> require_ok Scratch.error_to_string
        in
        Alcotest.(check int)
          (label ^ " repeat cleanup is idempotent")
          (List.length candidates) repeated.Scratch.already_quarantined_objects)
  in
  List.iter
    (fun index ->
      run
        (Printf.sprintf "before-%d" index)
        (Scratch.Fault.before_candidate index);
      run
        (Printf.sprintf "after-%d" index)
        (Scratch.Fault.after_candidate index))
    (List.init 4 Fun.id)

let quarantine_resumes_a_durable_link_before_source_unlink () =
  with_repository (fun root _bootstrap_repository scratch ->
      let plan, publication, retained, _ = compact_cleanup_fixture scratch in
      let candidates =
        publication.Scratch.published_generation_manifest
          .Retention.cleanup_candidates
      in
      let candidate = List.hd candidates in
      let objects = object_store root in
      let source =
        Object_store.object_path objects
          candidate.Retention.candidate_object_ref
      in
      let destination =
        quarantine_path root publication.Scratch.published_generation_event_id
          candidate
      in
      let quarantine_root = Filename.dirname (Filename.dirname destination) in
      Unix.mkdir quarantine_root 0o700;
      Unix.mkdir (Filename.dirname destination) 0o700;
      Unix.link source destination;
      let resumed =
        Scratch.resume_cleanup scratch |> require_ok Scratch.error_to_string
      in
      Alcotest.(check int)
        "linked candidate is recognized as a retry" 1
        resumed.Scratch.already_quarantined_objects;
      assert_quarantined root publication.Scratch.published_generation_event_id
        candidates;
      assert_retained_compacted_snapshots scratch plan retained)

let prune_interruptions_are_separate_and_never_delete_live_objects () =
  let cleanup_fault_injected =
   (function
   | Scratch.Cleanup_fault_injected _ -> true
   | _ -> false)
   [@warning "-4"]
  in
  let run label fault =
    with_repository (fun root bootstrap_repository scratch ->
        let plan, publication, retained, _ = compact_cleanup_fixture scratch in
        let candidates =
          publication.Scratch.published_generation_manifest
            .Retention.cleanup_candidates
        in
        ignore
          (Scratch.resume_cleanup scratch |> require_ok Scratch.error_to_string);
        (match Scratch.prune_quarantine ~fault scratch with
        | Error error when cleanup_fault_injected error -> ()
        | Error error ->
            Alcotest.failf "%s returned the wrong prune error: %s" label
              (Scratch.error_to_string error)
        | Ok _ -> Alcotest.fail (label ^ " did not interrupt prune"));
        let reopened =
          Scratch.open_repository ~root ~bootstrap_repository
          |> require_ok Scratch.error_to_string
        in
        let resumed =
          Scratch.prune_quarantine reopened
          |> require_ok Scratch.error_to_string
        in
        assert_pruned root publication.Scratch.published_generation_event_id
          candidates;
        assert_retained_compacted_snapshots reopened plan retained;
        Alcotest.(check int)
          (label ^ " resumed plus durable prior prunes cover every candidate")
          (List.length candidates)
          (resumed.Scratch.pruned_objects
         + resumed.Scratch.already_pruned_objects);
        let repeated =
          Scratch.prune_quarantine reopened
          |> require_ok Scratch.error_to_string
        in
        Alcotest.(check int)
          (label ^ " repeat prune is idempotent")
          (List.length candidates) repeated.Scratch.already_pruned_objects)
  in
  List.iter
    (fun index ->
      run
        (Printf.sprintf "before-%d" index)
        (Scratch.Fault.before_candidate index);
      run
        (Printf.sprintf "after-%d" index)
        (Scratch.Fault.after_candidate index))
    (List.init 4 Fun.id)

let prune_refuses_candidates_that_are_not_quarantined () =
  with_repository (fun _root _bootstrap_repository scratch ->
      let _plan, _publication, _retained, _ = compact_cleanup_fixture scratch in
      let live_object_prune_refusal =
       (function
       | Scratch.Object_store_error
           (Object_store.Quarantine_source_still_present _) ->
           true
       | _ -> false)
       [@warning "-4"]
      in
      match Scratch.prune_quarantine scratch with
      | Error error when live_object_prune_refusal error -> ()
      | Error error ->
          Alcotest.failf "wrong live-object prune refusal: %s"
            (Scratch.error_to_string error)
      | Ok _ -> Alcotest.fail "prune deleted a live cleanup candidate")

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
          Alcotest.test_case
            "compaction activates selected exact snapshots after interruption"
            `Quick
            compaction_activation_preserves_selected_snapshots_and_retries;
          Alcotest.test_case "compaction folds persisted protection claims"
            `Quick compaction_folds_persisted_protection_claims;
          Alcotest.test_case
            "protection frame interruption remains inert and resumes" `Quick
            protection_frame_interruption_is_inert_and_resumes;
          Alcotest.test_case "protection plan refuses stale claim head" `Quick
            protection_plan_refuses_a_stale_claim_head;
          Alcotest.test_case "compaction refuses stale source activation" `Quick
            compaction_refuses_to_activate_a_stale_source_plan;
          Alcotest.test_case "compaction refuses stale protection activation"
            `Quick compaction_refuses_to_activate_after_protection_changes;
          Alcotest.test_case
            "quarantine interruption retries retain exact compact snapshots"
            `Quick
            quarantine_interruptions_resume_without_losing_retained_snapshots;
          Alcotest.test_case
            "quarantine resumes after a durable link before source removal"
            `Quick quarantine_resumes_a_durable_link_before_source_unlink;
          Alcotest.test_case
            "prune interruption retries are separate from live-object cleanup"
            `Quick
            prune_interruptions_are_separate_and_never_delete_live_objects;
          Alcotest.test_case "prune refuses live cleanup candidates" `Quick
            prune_refuses_candidates_that_are_not_quarantined;
          Alcotest.test_case "exact scan service publishes only changes" `Quick
            exact_scan_service_publishes_only_changes;
        ] );
    ]
