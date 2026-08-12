module Address = Yeokcham_v2_address
module Bootstrap = Yeokcham_v2_bootstrap
module Bootstrap_store = Yeokcham_v2_bootstrap_store
module Capsule = Yeokcham_v2_capsule
module Capsule_store = Yeokcham_v2_capsule_store
module Envelope = Yeokcham_v2_envelope
module Inspection = Yeokcham_v2_inspection
module Model = Yeokcham_model
module Release_record = Yeokcham_v2_release_record
module Release_store = Yeokcham_v2_release_store
module Scratch = Yeokcham_v2_scratch_store
module Store = Yeokcham_store
module V2_model = Yeokcham_v2_model
module Workspace_record = Yeokcham_v2_workspace_record
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

let () = Printf.printf "v2 release-store property base seed: %d\n%!" base_seed

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

let workspace_nonces =
  {
    Workspace_store.create_workspace_nonce = nonce 'q';
    create_revision_nonce = nonce 'r';
    create_binding_nonce = nonce 's';
  }

let attempt_nonces =
  {
    Workspace_store.attempt_result_nonce = nonce 't';
    conflict_nonces = [];
    attempt_nonce = nonce 'u';
    attempt_binding_nonce = nonce 'v';
  }

let release_nonces first =
  {
    Release_store.release_nonce = nonce first;
    binding_nonce = nonce (Char.chr (Char.code first + 1));
  }

let workspace_id =
  V2_model.Workspace_id.of_bytes (String.make 32 'w')
  |> require_ok V2_model.identity_error_to_string

let capsule_id =
  V2_model.Capsule_id.of_bytes (String.make 32 'c')
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
  let root = Filename.temp_file "yeokcham-v2-release-store-" "" in
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
      let releases =
        Release_store.open_repository ~root ~bootstrap_repository
        |> require_ok Release_store.error_to_string
      in
      run root bootstrap_repository scratch capsules workspaces releases)

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
    ~target =
  Capsule_store.create capsules ~id ~title:"exact change"
    ~description:"release input" ~created_at:17L
    ~source_event:source_checkpoint.Scratch.event_id
    ~target_event:target_checkpoint.Scratch.event_id
    ~selected_indices:(full_selection source target)
    ~nonces:(capsule_nonces 'A')
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

type inputs = {
  target : Model.Snapshot.t;
  workspace : Workspace_record.workspace_revision_link;
  attempt : Release_record.workspace_attempt_link;
  attempt_record : Workspace_record.workspace_attempt;
}

let release_inputs scratch capsules workspaces ~before ~after =
  let source = snapshot before in
  let target = snapshot after in
  let source_checkpoint = publish scratch source 'K' 'L' in
  let target_checkpoint = publish scratch target 'M' 'N' in
  let capsule =
    create_capsule capsules ~id:capsule_id ~source_checkpoint ~target_checkpoint
      ~source ~target
  in
  let current =
    Workspace_store.create workspaces ~id:workspace_id ~title:"release tray"
      ~description:"one exact capsule"
      ~base:(Capsule.revision_declared_base capsule.Capsule_store.revision)
      ~selected:[ revision_link capsule ]
      ~precedence:[] ~created_at:19L ~nonces:workspace_nonces
    |> require_ok Workspace_store.error_to_string
    |> function
    | Workspace_store.Published current
    | Workspace_store.Already_published current ->
        current
  in
  let attempted =
    Workspace_store.attempt workspaces ~id:workspace_id
      ~expected_revision:
        (Workspace_record.workspace_revision_id current.Workspace_store.revision)
      ~expected_binding:current.Workspace_store.workspace_binding_event_id
      ~created_at:20L ~nonces:attempt_nonces
    |> require_ok Workspace_store.error_to_string
    |> function
    | Workspace_store.Attempt_published attempted
    | Workspace_store.Attempt_already_published attempted ->
        attempted
  in
  {
    target;
    workspace =
      Workspace_record.make_workspace_revision_link ~workspace_id
        ~revision_id:
          (Workspace_record.workspace_revision_id
             current.Workspace_store.revision)
        ~revision_ref:current.Workspace_store.revision_ref;
    attempt =
      Release_record.make_workspace_attempt_link
        ~id:
          (Workspace_record.workspace_attempt_id
             attempted.Workspace_store.attempt)
        ~object_ref:attempted.Workspace_store.attempt_ref;
    attempt_record = attempted.Workspace_store.attempt;
  }

let conflict_attempt_nonces =
  {
    Workspace_store.attempt_result_nonce = nonce 'g';
    conflict_nonces = [ nonce 'h' ];
    attempt_nonce = nonce 'i';
    attempt_binding_nonce = nonce 'j';
  }

let conflicting_release_inputs scratch capsules workspaces =
  let source = snapshot "before" in
  let first = snapshot "first" in
  let second = snapshot "second" in
  let source_checkpoint = publish scratch source 'A' 'B' in
  let first_checkpoint = publish scratch first 'C' 'D' in
  let second_checkpoint = publish scratch second 'E' 'F' in
  let first_capsule =
    create_capsule capsules ~id:capsule_id ~source_checkpoint
      ~target_checkpoint:first_checkpoint ~source ~target:first
  in
  let second_capsule =
    create_capsule capsules
      ~id:
        (V2_model.Capsule_id.of_bytes (String.make 32 'd')
        |> require_ok V2_model.identity_error_to_string)
      ~source_checkpoint ~target_checkpoint:second_checkpoint ~source
      ~target:second
  in
  let current =
    Workspace_store.create workspaces ~id:workspace_id ~title:"conflict tray"
      ~description:"two conflicting capsules"
      ~base:
        (Capsule.revision_declared_base first_capsule.Capsule_store.revision)
      ~selected:[ revision_link first_capsule; revision_link second_capsule ]
      ~precedence:[] ~created_at:19L ~nonces:workspace_nonces
    |> require_ok Workspace_store.error_to_string
    |> function
    | Workspace_store.Published current
    | Workspace_store.Already_published current ->
        current
  in
  let attempted =
    Workspace_store.attempt workspaces ~id:workspace_id
      ~expected_revision:
        (Workspace_record.workspace_revision_id current.Workspace_store.revision)
      ~expected_binding:current.Workspace_store.workspace_binding_event_id
      ~created_at:20L ~nonces:conflict_attempt_nonces
    |> require_ok Workspace_store.error_to_string
    |> function
    | Workspace_store.Attempt_published attempted
    | Workspace_store.Attempt_already_published attempted ->
        attempted
  in
  {
    target = first;
    workspace =
      Workspace_record.make_workspace_revision_link ~workspace_id
        ~revision_id:
          (Workspace_record.workspace_revision_id
             current.Workspace_store.revision)
        ~revision_ref:current.Workspace_store.revision_ref;
    attempt =
      Release_record.make_workspace_attempt_link
        ~id:
          (Workspace_record.workspace_attempt_id
             attempted.Workspace_store.attempt)
        ~object_ref:attempted.Workspace_store.attempt_ref;
    attempt_record = attempted.Workspace_store.attempt;
  }

let published_evidence = function
  | Release_store.Evidence_published { evidence; evidence_ref }
  | Release_store.Evidence_already_published { evidence; evidence_ref } ->
      (evidence, evidence_ref)

let evidence_link evidence evidence_ref =
  Release_record.make_validation_evidence_link
    ~id:(Release_record.validation_evidence_id evidence)
    ~object_ref:evidence_ref

let published_release = function
  | Release_store.Published release | Release_store.Already_published release ->
      release

let release inputs evidence ~message ~created_at =
  Release_record.make_release ~parents:[] ~workspace:inputs.workspace
    ~attempt:inputs.attempt
    ~base:(Workspace_record.workspace_attempt_base inputs.attempt_record)
    ~capsules:(Workspace_record.workspace_attempt_ordered inputs.attempt_record)
    ~resolutions:[]
    ~final_snapshot:
      (Workspace_record.workspace_attempt_resulting_snapshot
         inputs.attempt_record)
    ~evidence:[ evidence ] ~message ~created_at
  |> require_ok Release_record.error_to_string

let durable_release_reopens_and_is_inspectable () =
  with_repository
    (fun root _bootstrap_repository scratch capsules workspaces releases ->
      let inputs =
        release_inputs scratch capsules workspaces ~before:"before"
          ~after:"after"
      in
      let final_snapshot =
        Workspace_record.workspace_attempt_resulting_snapshot
          inputs.attempt_record
      in
      let evidence, evidence_ref =
        Release_store.publish_evidence releases ~snapshot:final_snapshot
          ~check_name:"unit" ~status:Release_record.Passed ~observed_at:23L
          ~nonce:(nonce 'E')
        |> require_ok Release_store.error_to_string
        |> published_evidence
      in
      ((match
          Release_store.publish_evidence releases ~snapshot:final_snapshot
            ~check_name:"unit" ~status:Release_record.Passed ~observed_at:23L
            ~nonce:(nonce 'E')
        with
      | Ok (Release_store.Evidence_already_published _) -> ()
      | Ok _ -> Alcotest.fail "identical evidence did not report idempotency"
      | Error error -> Alcotest.fail (Release_store.error_to_string error))
      [@warning "-4"]);
      let evidence = evidence_link evidence evidence_ref in
      let published =
        Release_store.create releases ~parents:[] ~workspace:inputs.workspace
          ~attempt:inputs.attempt ~evidence:[ evidence ] ~message:(Some "ready")
          ~created_at:24L ~nonces:(release_nonces 'F')
        |> require_ok Release_store.error_to_string
        |> published_release
      in
      let reopened_bootstrap =
        Bootstrap_store.open_repository ~root ~capability
        |> require_ok Bootstrap_store.error_to_string
      in
      let reopened =
        Release_store.open_repository ~root
          ~bootstrap_repository:reopened_bootstrap
        |> require_ok Release_store.error_to_string
      in
      let replayed =
        Release_store.resolve reopened
          ~id:(Release_record.release_id published.Release_store.release)
        |> require_ok Release_store.error_to_string
        |> Option.get
      in
      Alcotest.(check string)
        "reopened release retains its logical identity"
        (V2_model.Release_id.to_hex
           (Release_record.release_id published.Release_store.release))
        (V2_model.Release_id.to_hex
           (Release_record.release_id replayed.Release_store.release));
      Alcotest.(check string)
        "release final snapshot is the attempted result"
        (Yeokcham_id.Snapshot_id.to_hex (Model.Snapshot.id inputs.target))
        (Yeokcham_id.Snapshot_id.to_hex
           (Workspace_record.workspace_attempt_resulting_snapshot
              inputs.attempt_record)
             .Capsule.snapshot_id);
      let storage =
        Inspection.storage ~root ~bootstrap_repository:reopened_bootstrap
        |> require_ok Inspection.error_to_string
      in
      Alcotest.(check int)
        "one validation frame is inspectable" 1
        storage.Inspection.validation_evidence_frames;
      Alcotest.(check int)
        "one release frame is inspectable" 1 storage.Inspection.release_frames;
      let wrong_parent =
        Release_record.make_release_link
          ~id:(Release_record.release_id published.Release_store.release)
          ~object_ref:
            (V2_model.Opaque_object_ref.of_bytes (String.make 32 'z')
            |> require_ok V2_model.identity_error_to_string)
      in
      (match
         Release_store.create releases ~parents:[ wrong_parent ]
           ~workspace:inputs.workspace ~attempt:inputs.attempt
           ~evidence:[ evidence ] ~message:(Some "bad parent") ~created_at:25L
           ~nonces:(release_nonces 'H')
       with
      | Error (Release_store.Release_link_mismatch _) -> ()
      | Error error -> Alcotest.fail (Release_store.error_to_string error)
      | Ok _ -> Alcotest.fail "mismatched parent physical link was accepted")
      [@warning "-4"])

let failed_mismatched_and_interrupted_releases_stay_invisible () =
  with_repository (fun _root _bootstrap scratch capsules workspaces releases ->
      let inputs =
        release_inputs scratch capsules workspaces ~before:"before"
          ~after:"after"
      in
      let final_snapshot =
        Workspace_record.workspace_attempt_resulting_snapshot
          inputs.attempt_record
      in
      let failed, failed_ref =
        Release_store.publish_evidence releases ~snapshot:final_snapshot
          ~check_name:"failed" ~status:Release_record.Failed ~observed_at:26L
          ~nonce:(nonce 'I')
        |> require_ok Release_store.error_to_string
        |> published_evidence
      in
      ((match
          Release_store.create releases ~parents:[] ~workspace:inputs.workspace
            ~attempt:inputs.attempt
            ~evidence:[ evidence_link failed failed_ref ]
            ~message:(Some "failed") ~created_at:27L
            ~nonces:(release_nonces 'J')
        with
      | Error (Release_store.Evidence_not_passed _) -> ()
      | Error error -> Alcotest.fail (Release_store.error_to_string error)
      | Ok _ -> Alcotest.fail "failed validation evidence was accepted")
      [@warning "-4"]);
      let base =
        Workspace_record.workspace_attempt_base inputs.attempt_record
      in
      let mismatch, mismatch_ref =
        Release_store.publish_evidence releases ~snapshot:base
          ~check_name:"mismatch" ~status:Release_record.Passed ~observed_at:28L
          ~nonce:(nonce 'O')
        |> require_ok Release_store.error_to_string
        |> published_evidence
      in
      ((match
          Release_store.create releases ~parents:[] ~workspace:inputs.workspace
            ~attempt:inputs.attempt
            ~evidence:[ evidence_link mismatch mismatch_ref ]
            ~message:(Some "mismatch") ~created_at:29L
            ~nonces:(release_nonces 'P')
        with
      | Error (Release_store.Evidence_link_mismatch _) -> ()
      | Error error -> Alcotest.fail (Release_store.error_to_string error)
      | Ok _ -> Alcotest.fail "mismatched validation evidence was accepted")
      [@warning "-4"]);
      let passed, passed_ref =
        Release_store.publish_evidence releases ~snapshot:final_snapshot
          ~check_name:"fault" ~status:Release_record.Passed ~observed_at:30L
          ~nonce:(nonce 'R')
        |> require_ok Release_store.error_to_string
        |> published_evidence
      in
      let evidence = evidence_link passed passed_ref in
      let expected =
        release inputs evidence ~message:(Some "fault") ~created_at:31L
      in
      ((match
          Release_store.create
            ~fault:
              (Release_store.Fault.at Release_store.Fault.After_release_object)
            releases ~parents:[] ~workspace:inputs.workspace
            ~attempt:inputs.attempt ~evidence:[ evidence ]
            ~message:(Some "fault") ~created_at:31L ~nonces:(release_nonces 'S')
        with
      | Error
          (Release_store.Fault_injected Release_store.Fault.After_release_object)
        ->
          ()
      | Error error -> Alcotest.fail (Release_store.error_to_string error)
      | Ok _ -> Alcotest.fail "interrupted release unexpectedly became visible")
      [@warning "-4"]);
      Alcotest.(check bool)
        "interrupted release exposes no signed head" true
        (Option.is_none
           (Release_store.resolve releases
              ~id:(Release_record.release_id expected)
           |> require_ok Release_store.error_to_string));
      let visible =
        Release_store.create releases ~parents:[] ~workspace:inputs.workspace
          ~attempt:inputs.attempt ~evidence:[ evidence ] ~message:(Some "fault")
          ~created_at:31L ~nonces:(release_nonces 'U')
        |> require_ok Release_store.error_to_string
        |> published_release
      in
      (match
         Release_store.create releases ~parents:[] ~workspace:inputs.workspace
           ~attempt:inputs.attempt ~evidence:[ evidence ]
           ~message:(Some "fault") ~created_at:31L ~nonces:(release_nonces 'U')
       with
      | Ok (Release_store.Already_published replayed) ->
          Alcotest.(check string)
            "idempotent release preserves its identity"
            (V2_model.Release_id.to_hex
               (Release_record.release_id visible.Release_store.release))
            (V2_model.Release_id.to_hex
               (Release_record.release_id replayed.Release_store.release))
      | Ok _ -> Alcotest.fail "identical release did not report idempotency"
      | Error error -> Alcotest.fail (Release_store.error_to_string error))
      [@warning "-4"])

let conflict_bearing_attempt_rejects_release () =
  with_repository (fun _root _bootstrap scratch capsules workspaces releases ->
      let inputs = conflicting_release_inputs scratch capsules workspaces in
      Alcotest.(check int)
        "conflicting attempt is retained for inspection" 1
        (List.length
           (Workspace_record.workspace_attempt_conflicts inputs.attempt_record));
      let final_snapshot =
        Workspace_record.workspace_attempt_resulting_snapshot
          inputs.attempt_record
      in
      let evidence, evidence_ref =
        Release_store.publish_evidence releases ~snapshot:final_snapshot
          ~check_name:"conflict" ~status:Release_record.Passed ~observed_at:32L
          ~nonce:(nonce 'k')
        |> require_ok Release_store.error_to_string
        |> published_evidence
      in
      (match
         Release_store.create releases ~parents:[] ~workspace:inputs.workspace
           ~attempt:inputs.attempt
           ~evidence:[ evidence_link evidence evidence_ref ]
           ~message:(Some "conflicted") ~created_at:33L
           ~nonces:(release_nonces 'l')
       with
      | Error (Release_store.Unresolved_conflicts _) -> ()
      | Error error -> Alcotest.fail (Release_store.error_to_string error)
      | Ok _ -> Alcotest.fail "conflict-bearing attempt became a release")
      [@warning "-4"])

let generated_releases_reopen =
  QCheck2.Test.make ~count:16
    ~name:"V2 durable releases replay generated exact snapshot bytes"
    QCheck2.Gen.(
      pair (string_size (int_range 0 128)) (string_size (int_range 0 128)))
    (fun (before, after) ->
      try
        with_repository
          (fun _root _bootstrap scratch capsules workspaces releases ->
            let inputs =
              release_inputs scratch capsules workspaces ~before ~after
            in
            let final_snapshot =
              Workspace_record.workspace_attempt_resulting_snapshot
                inputs.attempt_record
            in
            let evidence, evidence_ref =
              Release_store.publish_evidence releases ~snapshot:final_snapshot
                ~check_name:"generated" ~status:Release_record.Passed
                ~observed_at:1L ~nonce:(nonce 'E')
              |> require_ok Release_store.error_to_string
              |> published_evidence
            in
            match
              Release_store.create releases ~parents:[]
                ~workspace:inputs.workspace ~attempt:inputs.attempt
                ~evidence:[ evidence_link evidence evidence_ref ]
                ~message:(Some "generated") ~created_at:2L
                ~nonces:(release_nonces 'F')
            with
            | Error _ -> false
            | Ok publication ->
                let release = published_release publication in
                Release_store.resolve releases
                  ~id:(Release_record.release_id release.Release_store.release)
                |> Result.map Option.is_some
                |> Result.value ~default:false)
      with _ -> false)

let () =
  Alcotest.run "V2 durable immutable releases"
    [
      ( "unit",
        [
          Alcotest.test_case "release reopens with typed evidence and storage"
            `Quick durable_release_reopens_and_is_inspectable;
          Alcotest.test_case
            "failed, mismatched, and interrupted releases reject" `Quick
            failed_mismatched_and_interrupted_releases_stay_invisible;
          Alcotest.test_case "conflict-bearing attempts cannot release" `Quick
            conflict_bearing_attempt_rejects_release;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "release-reopen")
            generated_releases_reopen;
        ] );
    ]
