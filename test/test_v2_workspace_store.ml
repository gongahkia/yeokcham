module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Capsule = Yeokcham_v2_capsule
module Capsule_store = Yeokcham_v2_capsule_store
module Envelope = Yeokcham_v2_envelope
module Inspection = Yeokcham_v2_inspection
module Model = Yeokcham_model
module Record = Yeokcham_v2_workspace_record
module Scratch = Yeokcham_v2_scratch_store
module Store = Yeokcham_store
module V2_model = Yeokcham_v2_model
module Workspace = Yeokcham_v2_workspace
module Workspace_store = Yeokcham_v2_workspace_store

let default_seed = 20_260_812

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let state_for name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  Random.State.make [| !value |]

let () = Printf.printf "v2 workspace-store property base seed: %d\n%!" base_seed

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
      Model.File_path
        (path [ "tracked" ], { Model.mode = Model.Regular; content });
    ]
  |> require_ok Model.construction_error_to_string

let nonce character =
  Envelope.nonce_of_bytes (String.make 12 character)
  |> require_ok Envelope.error_to_string

let capsule_nonces first =
  let at offset = nonce (Char.chr (Char.code first + offset)) in
  {
    Capsule_store.capsule_nonce = at 0;
    selected_result_nonce = at 1;
    revision_nonce = at 2;
    source_protection_nonce = at 3;
    source_protection_ledger_nonce = at 4;
    target_protection_nonce = at 5;
    target_protection_ledger_nonce = at 6;
    binding_ledger_nonce = at 7;
  }

let create_nonces () =
  {
    Workspace_store.create_workspace_nonce = nonce 'q';
    create_revision_nonce = nonce 'r';
    create_binding_nonce = nonce 's';
  }

let attempt_nonces () =
  {
    Workspace_store.attempt_result_nonce = nonce 't';
    conflict_nonces = [ nonce 'u' ];
    attempt_nonce = nonce 'v';
    attempt_binding_nonce = nonce 'w';
  }

let resolution_nonces () =
  {
    Workspace_store.resolve_resolution_nonce = nonce 'x';
    resolve_revision_nonce = nonce 'y';
    resolve_binding_nonce = nonce 'z';
  }

let workspace_id =
  V2_model.Workspace_id.of_bytes (String.make 32 'w')
  |> require_ok V2_model.identity_error_to_string

let capsule_id character =
  V2_model.Capsule_id.of_bytes (String.make 32 character)
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
  let root = Filename.temp_file "yeokcham-v2-workspace-store-" "" in
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
      let capsules =
        Capsule_store.open_repository ~root ~bootstrap_repository
        |> require_ok Capsule_store.error_to_string
      in
      let workspaces =
        Workspace_store.open_repository ~root ~bootstrap_repository
        |> require_ok Workspace_store.error_to_string
      in
      run root scratch capsules workspaces)

let publish scratch snapshot snapshot_nonce ledger_nonce =
  Scratch.publish scratch ~snapshot ~snapshot_nonce:(nonce snapshot_nonce)
    ~ledger_nonce:(nonce ledger_nonce)
  |> require_ok Scratch.error_to_string
  |> function
  | Scratch.Published checkpoint | Scratch.Unchanged checkpoint -> checkpoint

let full_selection source target =
  Capsule.propose ~from:source ~to_:target
  |> require_ok Capsule.proposal_error_to_string
  |> Capsule.proposal_operations
  |> List.mapi (fun index _ -> index)

let create_capsule capsules ~id ~source_checkpoint ~target_checkpoint ~source
    ~target ~nonces =
  Capsule_store.create capsules ~id ~title:"exact change"
    ~description:"workspace input" ~created_at:17L
    ~source_event:source_checkpoint.Scratch.event_id
    ~target_event:target_checkpoint.Scratch.event_id
    ~selected_indices:(full_selection source target)
    ~nonces
  |> require_ok Capsule_store.error_to_string
  |> function
  | Capsule_store.Published resolved | Capsule_store.Already_published resolved
    ->
      resolved

let revision_link (resolved : Capsule_store.resolved) =
  Capsule.make_revision_link
    ~capsule_id:(Capsule.revision_capsule_id resolved.Capsule_store.revision)
    ~revision_id:(Capsule.revision_id resolved.Capsule_store.revision)
    ~revision_ref:resolved.Capsule_store.revision_ref

let conflicting_inputs scratch capsules () =
  let source = snapshot "before" in
  let first = snapshot "first" in
  let second = snapshot "second" in
  let source_checkpoint = publish scratch source 'A' 'B' in
  let first_checkpoint = publish scratch first 'C' 'D' in
  let second_checkpoint = publish scratch second 'E' 'F' in
  let first_capsule =
    create_capsule capsules ~id:(capsule_id 'c') ~source_checkpoint
      ~target_checkpoint:first_checkpoint ~source ~target:first
      ~nonces:(capsule_nonces 'G')
  in
  let second_capsule =
    create_capsule capsules ~id:(capsule_id 'd') ~source_checkpoint
      ~target_checkpoint:second_checkpoint ~source ~target:second
      ~nonces:(capsule_nonces 'O')
  in
  (source, first_capsule, second_capsule)

let create_workspace workspaces ~base ~selected ?fault () =
  Workspace_store.create ?fault workspaces ~id:workspace_id ~title:"merge tray"
    ~description:"explicit capsule order" ~base ~selected ~precedence:[]
    ~created_at:19L ~nonces:(create_nonces ())

let published_workspace = function
  | Workspace_store.Published current
  | Workspace_store.Already_published current ->
      current

let durable_attempt_conflict_and_skip_resolution_reopen () =
  with_repository (fun root scratch capsules workspaces ->
      let source, first, second = conflicting_inputs scratch capsules () in
      let current =
        create_workspace workspaces
          ~base:(Capsule.revision_declared_base first.Capsule_store.revision)
          ~selected:[ revision_link first; revision_link second ]
          ()
        |> require_ok Workspace_store.error_to_string
        |> published_workspace
      in
      Alcotest.(check int)
        "one localized conflict remains inspectable" 1
        (List.length current.Workspace_store.application.Workspace.conflicts);
      let attempt =
        Workspace_store.attempt workspaces ~id:workspace_id
          ~expected_revision:
            (Record.workspace_revision_id current.Workspace_store.revision)
          ~expected_binding:current.Workspace_store.workspace_binding_event_id
          ~created_at:20L ~nonces:(attempt_nonces ())
        |> require_ok Workspace_store.error_to_string
        |> function
        | Workspace_store.Attempt_published attempt
        | Workspace_store.Attempt_already_published attempt ->
            attempt
      in
      let conflict =
        Record.workspace_attempt_conflicts attempt.Workspace_store.attempt
        |> List.hd
      in
      let resolved =
        Workspace_store.resolve_skip workspaces ~id:workspace_id
          ~expected_revision:
            (Record.workspace_revision_id current.Workspace_store.revision)
          ~expected_binding:current.Workspace_store.workspace_binding_event_id
          ~conflict ~created_at:21L ~nonces:(resolution_nonces ())
        |> require_ok Workspace_store.error_to_string
        |> published_workspace
      in
      Alcotest.(check int)
        "explicit skip removes only its named conflict" 0
        (List.length resolved.Workspace_store.application.Workspace.conflicts);
      let reopened_bootstrap =
        Bootstrap_store.open_repository ~root ~capability
        |> require_ok Bootstrap_store.error_to_string
      in
      let reopened =
        Workspace_store.open_repository ~root
          ~bootstrap_repository:reopened_bootstrap
        |> require_ok Workspace_store.error_to_string
      in
      let replayed =
        Workspace_store.resolve reopened ~id:workspace_id
        |> require_ok Workspace_store.error_to_string
        |> Option.get
      in
      Alcotest.(check bool)
        "reopened resolved workspace replays exactly" true
        (Model.Snapshot.equal
           resolved.Workspace_store.application.Workspace.resulting_snapshot
           replayed.Workspace_store.application.Workspace.resulting_snapshot);
      let storage =
        Inspection.storage ~root ~bootstrap_repository:reopened_bootstrap
        |> require_ok Inspection.error_to_string
      in
      Alcotest.(check int)
        "one V2 workspace frame is inspectable" 1
        storage.Inspection.workspace_frames;
      Alcotest.(check int)
        "two V2 workspace revisions are inspectable" 2
        storage.Inspection.workspace_revision_frames;
      Alcotest.(check int)
        "one V2 workspace attempt is inspectable" 1
        storage.Inspection.workspace_attempt_frames;
      Alcotest.(check int)
        "one V2 conflict is inspectable" 1 storage.Inspection.conflict_frames;
      Alcotest.(check int)
        "one V2 resolution is inspectable" 1
        storage.Inspection.resolution_frames;
      ignore source)

let interruption_stays_unbound_and_stale_resolution_rejects () =
  with_repository (fun _root scratch capsules workspaces ->
      let _source, first, second = conflicting_inputs scratch capsules () in
      let base = Capsule.revision_declared_base first.Capsule_store.revision in
      ((match
          create_workspace workspaces ~base
            ~selected:[ revision_link first; revision_link second ]
            ~fault:
              (Workspace_store.Fault.at
                 Workspace_store.Fault.After_workspace_revision)
            ()
        with
      | Error
          (Workspace_store.Fault_injected
             Workspace_store.Fault.After_workspace_revision) ->
          ()
      | Error error -> Alcotest.fail (Workspace_store.error_to_string error)
      | Ok _ -> Alcotest.fail "interrupted workspace unexpectedly bound")
      [@warning "-4"]);
      Alcotest.(check bool)
        "interruption exposes no workspace head" true
        (Option.is_none
           (Workspace_store.resolve workspaces ~id:workspace_id
           |> require_ok Workspace_store.error_to_string));
      let current =
        create_workspace workspaces ~base
          ~selected:[ revision_link first; revision_link second ]
          ()
        |> require_ok Workspace_store.error_to_string
        |> published_workspace
      in
      let attempt =
        Workspace_store.attempt workspaces ~id:workspace_id
          ~expected_revision:
            (Record.workspace_revision_id current.Workspace_store.revision)
          ~expected_binding:current.Workspace_store.workspace_binding_event_id
          ~created_at:20L ~nonces:(attempt_nonces ())
        |> require_ok Workspace_store.error_to_string
      in
      let attempt =
        match attempt with
        | Workspace_store.Attempt_published attempt
        | Workspace_store.Attempt_already_published attempt ->
            attempt
      in
      let conflict =
        Record.workspace_attempt_conflicts attempt.Workspace_store.attempt
        |> List.hd
      in
      ignore
        (Workspace_store.resolve_skip workspaces ~id:workspace_id
           ~expected_revision:
             (Record.workspace_revision_id current.Workspace_store.revision)
           ~expected_binding:current.Workspace_store.workspace_binding_event_id
           ~conflict ~created_at:21L ~nonces:(resolution_nonces ())
        |> require_ok Workspace_store.error_to_string);
      (match
         Workspace_store.resolve_skip workspaces ~id:workspace_id
           ~expected_revision:
             (Record.workspace_revision_id current.Workspace_store.revision)
           ~expected_binding:current.Workspace_store.workspace_binding_event_id
           ~conflict ~created_at:21L ~nonces:(resolution_nonces ())
       with
      | Error (Workspace_store.Concurrent_current_update _) -> ()
      | Error error -> Alcotest.fail (Workspace_store.error_to_string error)
      | Ok _ -> Alcotest.fail "stale resolution unexpectedly advanced workspace")
      [@warning "-4"])

let generated_workspace_create_reopens =
  QCheck2.Test.make ~count:24
    ~name:"V2 workspace replay persists generated exact bytes"
    QCheck2.Gen.(
      pair (string_size (int_range 0 256)) (string_size (int_range 0 256)))
    (fun (before, after) ->
      try
        with_repository (fun _root scratch capsules workspaces ->
            let source = snapshot before in
            let target = snapshot after in
            let source_checkpoint = publish scratch source 'A' 'B' in
            let target_checkpoint = publish scratch target 'C' 'D' in
            let capsule =
              create_capsule capsules ~id:(capsule_id 'c') ~source_checkpoint
                ~target_checkpoint ~source ~target ~nonces:(capsule_nonces 'G')
            in
            match
              create_workspace workspaces
                ~base:
                  (Capsule.revision_declared_base capsule.Capsule_store.revision)
                ~selected:[ revision_link capsule ]
                ()
            with
            | Error _ -> false
            | Ok publication ->
                let current = published_workspace publication in
                Model.Snapshot.equal target
                  current.Workspace_store.application
                    .Workspace.resulting_snapshot)
      with _ -> false)

let () =
  Alcotest.run "V2 durable workspaces"
    [
      ( "unit",
        [
          Alcotest.test_case
            "attempts retain conflicts and skip resolutions reopen" `Quick
            durable_attempt_conflict_and_skip_resolution_reopen;
          Alcotest.test_case
            "interruption stays unbound and stale resolution rejects" `Quick
            interruption_stays_unbound_and_stale_resolution_rejects;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "workspace-create-reopen")
            generated_workspace_create_reopens;
        ] );
    ]
