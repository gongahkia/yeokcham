module Model = Yeokcham_v4_model
module Journal = Yeokcham_v4_restore_journal
module Proof = Yeokcham_v4_restore_proof
module Service = Yeokcham_v4_local_service
module Store = Yeokcham_v4_store
module Trust = Yeokcham_v4_trust
module Recovery = Yeokcham_v4_recovery
module Package = Yeokcham_v4_package
module Proposal = Yeokcham_v4_proposal
module Transport = Yeokcham_v4_transport

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

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

let with_directory prefix run =
  let root = Filename.temp_file prefix "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> run root)

let with_external_directory prefix run =
  let directory = Filename.temp_file prefix "" in
  Unix.unlink directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree directory)
    (fun () -> run directory)

let write_file root name contents =
  Out_channel.with_open_bin (Filename.concat root name) (fun channel ->
      Out_channel.output_string channel contents)

let read_file root name =
  In_channel.with_open_bin (Filename.concat root name) In_channel.input_all

let object_path root hex =
  Filename.concat
    (Filename.concat
       (Filename.concat (Filename.concat root ".yeokcham") "objects")
       (String.sub hex 0 2))
    (Filename.concat (String.sub hex 2 2) (String.sub hex 4 60))

let id parser value = parser value |> Result.get_ok
let device value = id Model.Device_id.of_string value
let draft value = id Model.Draft_id.of_string value
let change value = id Model.Change_id.of_string value
let revision value = id Model.Revision_id.of_string value
let delivery value = id Model.Delivery_id.of_string value
let username value = id Model.Username.of_string value

let signing_capability byte =
  String.make 32 byte |> Trust.signing_capability_of_private_key
  |> require_ok Trust.error_to_string

let trust_device signing_capability =
  Trust.signing_public_key signing_capability
  |> Trust.device_of_public_key
  |> require_ok Trust.error_to_string

let repository =
  Trust.Repository_id.of_string
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  |> Result.get_ok

let initialize root =
  Service.init ~root ~creator:(device "device-alice")
    ~username:(username "alice") ~initial_draft:(draft "draft-one")
    ~title:"first work"
  |> require_ok Service.error_to_string

let init_captures_the_initial_tree_and_save_observes_no_change () =
  with_directory "yeokcham-v4-service-init-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initialized = initialize root in
      Alcotest.(check bool)
        "initial checkpoint identity is nonempty" true
        (String.length
           (Model.Snapshot_id.to_string initialized.Service.checkpoint)
        > 0);
      match Service.save ~root |> require_ok Service.error_to_string with
      | Service.Unchanged status ->
          Alcotest.(check string)
            "unchanged save retains checkpoint"
            (Model.Snapshot_id.to_string initialized.Service.checkpoint)
            (Model.Snapshot_id.to_string status.Service.checkpoint)
      | Service.Saved _ -> Alcotest.fail "unchanged tree created a state write")

let username_registration_persists_across_a_repository_reload () =
  with_directory "yeokcham-v4-service-usernames-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      let registered =
        Service.register_username ~root ~device:(device "device-bob")
          ~username:(username "bob")
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "registration is visible after its immutable state save" 2
        (List.length registered.Service.usernames);
      let reloaded =
        Service.status ~root |> require_ok Service.error_to_string
      in
      Alcotest.(check (list string))
        "the local display registry survives reopening the repository"
        [ "device-alice:alice"; "device-bob:bob" ]
        (reloaded.Service.usernames
        |> List.map (fun registration ->
            Model.Device_id.to_string registration.Model.username_device
            ^ ":"
            ^ Model.Username.to_string registration.Model.username)
        |> List.sort String.compare))

let changed_save_creates_a_new_checkpoint () =
  with_directory "yeokcham-v4-service-save-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      write_file root "main.ml" "let version = 2\n";
      match Service.save ~root |> require_ok Service.error_to_string with
      | Service.Saved status ->
          Alcotest.(check bool)
            "changed file has a new exact snapshot" false
            (Model.Snapshot_id.equal initial.Service.checkpoint
               status.Service.checkpoint)
      | Service.Unchanged _ -> Alcotest.fail "changed tree did not save")

let status_warns_about_uncaptured_edits () =
  with_directory "yeokcham-v4-service-uncaptured-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      write_file root "main.ml" "let version = 2\n";
      let status = Service.status ~root |> require_ok Service.error_to_string in
      Alcotest.(check bool)
        "uncaptured edit is visible" true status.Service.uncaptured;
      ignore (Service.save ~root |> require_ok Service.error_to_string);
      let status = Service.status ~root |> require_ok Service.error_to_string in
      Alcotest.(check bool)
        "save clears the uncaptured warning" false status.Service.uncaptured)

let compact_drops_extra_saves_and_keeps_a_pin () =
  with_directory "yeokcham-v4-service-compact-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      write_file root "main.ml" "let version = 2\n";
      let first =
        match Service.save ~root |> require_ok Service.error_to_string with
        | Service.Saved status -> status.Service.checkpoint
        | Service.Unchanged _ -> Alcotest.fail "first save did not record"
      in
      write_file root "main.ml" "let version = 3\n";
      ignore (Service.save ~root |> require_ok Service.error_to_string);
      write_file root "main.ml" "let version = 4\n";
      ignore (Service.save ~root |> require_ok Service.error_to_string);
      ignore
        (Service.pin ~root ~checkpoint:first
        |> require_ok Service.error_to_string);
      let report =
        Service.compact ~root ~keep_recent:0 ~dry_run:false
        |> require_ok Service.error_to_string
      in
      let retained =
        report.Service.status.Service.checkpoints
        |> List.map (fun checkpoint -> checkpoint.Model.checkpoint_snapshot)
      in
      Alcotest.(check bool)
        "pinned checkpoint remains" true
        (List.exists (Model.Snapshot_id.equal first) retained);
      Alcotest.(check bool)
        "compaction dropped at least one scratch checkpoint" true
        (List.length report.Service.dropped > 0))

let capture_window_uses_quiet_and_max_delay () =
  let window = Service.Capture_window.empty in
  let window = Service.Capture_window.observe window ~now:0.0 in
  Alcotest.(check bool)
    "quiet period waits" false
    (Service.Capture_window.due window ~now:0.5);
  Alcotest.(check bool)
    "quiet period elapses" true
    (Service.Capture_window.due window ~now:1.0);
  let window = Service.Capture_window.observe window ~now:29.5 in
  Alcotest.(check bool)
    "max delay captures during sustained writes" true
    (Service.Capture_window.due window ~now:30.0)

let new_draft_closes_the_previous_draft_without_losing_saved_state () =
  with_directory "yeokcham-v4-service-draft-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      let next =
        Service.new_draft ~root ~id:(draft "draft-two") ~title:"second work"
        |> require_ok Service.error_to_string
      in
      Alcotest.(check string)
        "new draft becomes active" "draft-two"
        (Model.Draft_id.to_string next.Service.active_draft.Model.draft_id);
      Alcotest.(check string)
        "new draft inherits the saved checkpoint"
        (Model.Snapshot_id.to_string initial.Service.checkpoint)
        (Model.Snapshot_id.to_string next.Service.checkpoint))

let restore_materializes_a_prior_checkpoint_without_touching_the_project () =
  with_directory "yeokcham-v4-service-restore-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      write_file root "main.ml" "let version = 2\n";
      ignore (Service.save ~root |> require_ok Service.error_to_string);
      let destination = Filename.concat root "recovered" in
      Unix.mkdir destination 0o700;
      Service.restore ~root ~checkpoint:initial.Service.checkpoint ~destination
      |> require_ok Service.error_to_string;
      Alcotest.(check string)
        "restored directory has the prior bytes" "let version = 1\n"
        (read_file destination "main.ml");
      Alcotest.(check string)
        "active project remains untouched" "let version = 2\n"
        (read_file root "main.ml"))

let restore_rejects_a_nonempty_destination () =
  with_directory "yeokcham-v4-service-restore-failure-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      let destination = Filename.concat root "occupied" in
      Unix.mkdir destination 0o700;
      write_file destination "already-here" "keep this\n";
      match
        Service.restore ~root ~checkpoint:initial.Service.checkpoint
          ~destination
      with
      | Error error ->
          Alcotest.(check bool)
            "destination safety error is explicit" true
            (String.starts_with
               ~prefix:"materialisation destination is not empty:"
               (Service.error_to_string error))
      | Ok () -> Alcotest.fail "restore wrote into a nonempty destination")

let v4_capture_excludes_git_metadata () =
  with_directory "yeokcham-v4-service-git-metadata-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let git = Filename.concat root ".git" in
      Unix.mkdir git 0o700;
      write_file git "config" "private metadata\n";
      let initial = initialize root in
      let destination = Filename.concat root "recovered" in
      Unix.mkdir destination 0o700;
      Service.restore ~root ~checkpoint:initial.Service.checkpoint ~destination
      |> require_ok Service.error_to_string;
      Alcotest.(check bool)
        "restored snapshot excludes the Git directory" false
        (Sys.file_exists (Filename.concat destination ".git")))

let in_place_restore_retains_and_recovers_unsaved_bytes () =
  with_directory "yeokcham-v4-service-in-place-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      write_file root "main.ml" "let unsaved = 2\n";
      let restored =
        Service.restore_in_place ~root ~checkpoint:initial.Service.checkpoint
        |> require_ok Service.error_to_string
      in
      Alcotest.(check string)
        "live project contains target bytes" "let version = 1\n"
        (read_file root "main.ml");
      let safety_destination = Filename.concat root "safety-copy" in
      Unix.mkdir safety_destination 0o700;
      Service.restore ~root ~checkpoint:restored.Service.safety_checkpoint
        ~destination:safety_destination
      |> require_ok Service.error_to_string;
      Alcotest.(check string)
        "pre-restore unsaved bytes are recoverable" "let unsaved = 2\n"
        (read_file safety_destination "main.ml");
      let status = Service.status ~root |> require_ok Service.error_to_string in
      Alcotest.(check bool)
        "safety checkpoint remains retained" true
        (List.exists
           (fun checkpoint ->
             Model.Snapshot_id.equal checkpoint.Model.checkpoint_snapshot
               restored.Service.safety_checkpoint)
           status.Service.checkpoints))

let restore_proof_survives_journal_pruning_until_explicit_forget () =
  with_directory "yeokcham-v4-service-restore-proof-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      write_file root "main.ml" "let unsaved = 2\n";
      let restored =
        Service.restore_in_place ~root ~checkpoint:initial.Service.checkpoint
        |> require_ok Service.error_to_string
      in
      let compacted =
        Service.compact ~root ~keep_recent:0 ~dry_run:false
        |> require_ok Service.error_to_string
      in
      Alcotest.(check (list string))
        "the completed journal is pruned"
        [ restored.Service.restore_operation ]
        compacted.Service.pruned_journals;
      Alcotest.(check int)
        "one durable restore proof remains" 1
        (Service.restore_proofs ~root
        |> require_ok Service.error_to_string
        |> List.length);
      Alcotest.(check int)
        "published journal is gone only after proof exists" 0
        (Journal.scan ~root |> require_ok Journal.error_to_string |> List.length);
      let roots =
        Service.storage_roots ~root |> require_ok Service.error_to_string
      in
      Alcotest.(check bool)
        "safety root is explained as a restore proof" true
        (List.exists
           (fun root ->
             Model.Snapshot_id.equal root.Service.root_snapshot
               restored.Service.safety_checkpoint
             && List.mem Model.Restore_proof root.Service.root_reasons)
           roots);
      let retained =
        Service.status ~root |> require_ok Service.error_to_string
        |> fun status -> status.Service.checkpoints
      in
      Alcotest.(check bool)
        "safety survives bounded scratch compaction" true
        (List.exists
           (fun checkpoint ->
             Model.Snapshot_id.equal checkpoint.Model.checkpoint_snapshot
               restored.Service.safety_checkpoint)
           retained);
      Service.forget_restore_proof ~root
        ~operation:restored.Service.restore_operation
      |> require_ok Service.error_to_string;
      ignore
        (Service.compact ~root ~keep_recent:0 ~dry_run:false
        |> require_ok Service.error_to_string);
      let retained =
        Service.status ~root |> require_ok Service.error_to_string
        |> fun status -> status.Service.checkpoints
      in
      Alcotest.(check bool)
        "forget permits later scratch compaction" false
        (List.exists
           (fun checkpoint ->
             Model.Snapshot_id.equal checkpoint.Model.checkpoint_snapshot
               restored.Service.safety_checkpoint)
           retained))

let legacy_published_journal_remains_a_root_until_explicit_retain () =
  with_directory "yeokcham-v4-service-legacy-restore-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      write_file root "main.ml" "let version = 2\n";
      let saved =
        match Service.save ~root |> require_ok Service.error_to_string with
        | Service.Saved status -> status
        | Service.Unchanged _ -> Alcotest.fail "changed tree was not saved"
      in
      let prepared =
        Journal.make_prepared ~operation_id:(String.make 64 'c')
          ~safety:saved.Service.checkpoint ~target:initial.Service.checkpoint
        |> require_ok Journal.error_to_string
      in
      let materialized =
        Journal.advance prepared Journal.Applying
        |> require_ok Journal.error_to_string
        |> fun applying ->
        Journal.advance applying Journal.Materialized
        |> require_ok Journal.error_to_string
      in
      let published =
        Journal.advance materialized Journal.Published
        |> require_ok Journal.error_to_string
      in
      List.iter
        (fun journal ->
          Journal.append ~root journal |> require_ok Journal.error_to_string)
        [
          prepared;
          Journal.advance prepared Journal.Applying
          |> require_ok Journal.error_to_string;
          materialized;
          published;
        ];
      let compacted =
        Service.compact ~root ~keep_recent:0 ~dry_run:false
        |> require_ok Service.error_to_string
      in
      Alcotest.(check (list string))
        "unproven legacy journal is not pruned" []
        compacted.Service.pruned_journals;
      Alcotest.(check int)
        "journal remains available for explicit retain" 4
        (Journal.scan ~root |> require_ok Journal.error_to_string |> List.length);
      let proof =
        Service.retain_restore_proof ~root ~operation:(String.make 64 'c')
        |> require_ok Service.error_to_string
      in
      Alcotest.(check string)
        "retain names the legacy operation" (String.make 64 'c')
        proof.Service.proof_operation;
      let compacted =
        Service.compact ~root ~keep_recent:0 ~dry_run:false
        |> require_ok Service.error_to_string
      in
      Alcotest.(check (list string))
        "verified legacy journal is now pruned"
        [ String.make 64 'c' ]
        compacted.Service.pruned_journals)

let corrupt_restore_proof_blocks_compaction_before_state_change () =
  with_directory "yeokcham-v4-service-corrupt-proof-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      write_file root "main.ml" "let unsaved = 2\n";
      let restored =
        Service.restore_in_place ~root ~checkpoint:initial.Service.checkpoint
        |> require_ok Service.error_to_string
      in
      let path =
        Filename.concat
          (Filename.concat (Filename.concat root ".yeokcham") "restore-proofs")
          ("v4-restore-proof-" ^ restored.Service.restore_operation ^ ".cbor")
      in
      let before =
        Store.open_repository ~root |> require_ok Store.error_to_string
        |> fun repository ->
        Store.load repository |> require_ok Store.error_to_string
        |> fun loaded -> loaded.Store.object_id
      in
      Out_channel.with_open_bin path (fun channel ->
          Out_channel.output_string channel "bad");
      (match Service.compact ~root ~keep_recent:0 ~dry_run:false with
      | Error _ -> ()
      | Ok _ ->
          Alcotest.fail "compaction accepted corrupt durable recovery proof");
      let after =
        Store.open_repository ~root |> require_ok Store.error_to_string
        |> fun repository ->
        Store.load repository |> require_ok Store.error_to_string
        |> fun loaded -> loaded.Store.object_id
      in
      Alcotest.(check string)
        "rejected proof leaves the state head unchanged"
        (Yeokcham_store.Stored_object_id.to_hex before)
        (Yeokcham_store.Stored_object_id.to_hex after))

let missing_restore_proof_object_blocks_compaction_before_state_change () =
  with_directory "yeokcham-v4-service-missing-proof-object-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      let repository =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let loaded = Store.load repository |> require_ok Store.error_to_string in
      let missing =
        Model.Snapshot_id.of_string "snapshot-missing" |> Result.get_ok
      in
      let project = Model.checkpoint loaded.Store.project ~snapshot:missing in
      let saved =
        Store.save repository ~expected:loaded.Store.head ~project
        |> require_ok Store.error_to_string
      in
      let proof =
        Proof.make ~operation_id:(String.make 64 'd') ~safety:missing
          ~target:initial.Service.checkpoint
        |> require_ok Proof.error_to_string
      in
      Proof.append ~root proof |> require_ok Proof.error_to_string;
      (match Service.compact ~root ~keep_recent:0 ~dry_run:false with
      | Error _ -> ()
      | Ok _ ->
          Alcotest.fail "compaction accepted a proof naming a missing snapshot");
      let after = Store.load repository |> require_ok Store.error_to_string in
      Alcotest.(check string)
        "missing proof object leaves the state head unchanged"
        (Yeokcham_store.Stored_object_id.to_hex saved.Store.object_id)
        (Yeokcham_store.Stored_object_id.to_hex after.Store.object_id))

let in_place_restore_preserves_repository_metadata () =
  with_directory "yeokcham-v4-service-in-place-metadata-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let git = Filename.concat root ".git" in
      Unix.mkdir git 0o700;
      write_file git "config" "preserve me\n";
      let initial = initialize root in
      write_file root "main.ml" "let version = 2\n";
      ignore
        (Service.restore_in_place ~root ~checkpoint:initial.Service.checkpoint
        |> require_ok Service.error_to_string);
      Alcotest.(check string)
        "Git metadata is not part of source replacement" "preserve me\n"
        (read_file git "config");
      Alcotest.(check bool)
        "Yeokcham metadata remains present" true
        (Sys.file_exists (Filename.concat root ".yeokcham")))

let interrupted_applying_restore_is_resumable () =
  with_directory "yeokcham-v4-service-resume-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      write_file root "main.ml" "let version = 2\n";
      let saved =
        match Service.save ~root |> require_ok Service.error_to_string with
        | Service.Saved status -> status
        | Service.Unchanged _ -> Alcotest.fail "changed tree was not saved"
      in
      let prepared =
        Journal.make_prepared ~operation_id:(String.make 64 'b')
          ~safety:saved.Service.checkpoint ~target:initial.Service.checkpoint
        |> require_ok Journal.error_to_string
      in
      Journal.append ~root prepared |> require_ok Journal.error_to_string;
      let applying =
        Journal.advance prepared Journal.Applying
        |> require_ok Journal.error_to_string
      in
      Journal.append ~root applying |> require_ok Journal.error_to_string;
      write_file root "main.ml" "partial restore bytes\n";
      let recovered =
        Service.recover_in_place ~root |> require_ok Service.error_to_string
      in
      let recovered =
        match recovered with
        | Some recovered -> recovered
        | None -> Alcotest.fail "pending restore was not recovered"
      in
      Alcotest.(check bool)
        "recovery is reported as resumed" true recovered.Service.resumed;
      Alcotest.(check string)
        "recovery re-derives the exact target" "let version = 1\n"
        (read_file root "main.ml");
      Alcotest.(check bool)
        "published journal is no longer pending" true
        (Option.is_none
           (Service.recover_in_place ~root |> require_ok Service.error_to_string)))

let share_records_a_shared_change_and_amend_appends_a_revision () =
  with_directory "yeokcham-v4-service-share-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      write_file root "main.ml" "let version = 2\n";
      let shared =
        Service.share ~root ~change:(change "change-a")
          ~revision:(revision "revision-a1")
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "first share is visible" 1 shared.Service.shared_change_count;
      write_file root "main.ml" "let version = 3\n";
      let amended =
        Service.share ~root ~change:(change "change-a")
          ~revision:(revision "revision-a2")
        |> require_ok Service.error_to_string
      in
      let recorded = List.hd amended.Service.shared_changes in
      Alcotest.(check int)
        "second share appends an immutable revision" 2
        (List.length recorded.Model.revisions))

let share_without_a_tree_delta_fails () =
  with_directory "yeokcham-v4-service-share-empty-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      match
        Service.share ~root ~change:(change "change-a")
          ~revision:(revision "revision-a")
      with
      | Error error ->
          Alcotest.(check string)
            "empty share is an empty-edit failure"
            "a change revision needs at least one edit"
            (Service.error_to_string error)
      | Ok _ -> Alcotest.fail "shared an unchanged tree against the baseline")

let overlapping_shared_drafts_are_a_decision () =
  with_directory "yeokcham-v4-service-overlap-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let initial = initialize root in
      write_file root "main.ml" "let version = 2\n";
      ignore
        (Service.share ~root ~change:(change "change-a")
           ~revision:(revision "../outside")
        |> require_ok Service.error_to_string);
      ignore
        (Service.new_draft ~root ~id:(draft "draft-two") ~title:"second work"
        |> require_ok Service.error_to_string);
      write_file root "main.ml" "let version = 3\n";
      let overlapping =
        Service.share ~root ~change:(change "change-b")
          ~revision:(revision "revision-b")
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "overlapping whole-path edits are a decision" 1
        (List.length overlapping.Service.open_decisions);
      Alcotest.(check string)
        "working tree is not rewritten by the decision" "let version = 3\n"
        (read_file root "main.ml");
      Alcotest.(check bool)
        "active checkpoint remains the captured tree" false
        (Model.Snapshot_id.equal initial.Service.checkpoint
           overlapping.Service.checkpoint))

let isolated_resolve_does_not_rewrite_the_live_tree () =
  with_directory "yeokcham-v4-service-isolated-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      write_file root "main.ml" "let version = 2\n";
      ignore
        (Service.share ~root ~change:(change "change-a")
           ~revision:(revision "../outside")
        |> require_ok Service.error_to_string);
      ignore
        (Service.new_draft ~root ~id:(draft "draft-two") ~title:"second work"
        |> require_ok Service.error_to_string);
      write_file root "main.ml" "let version = 3\n";
      let overlapping =
        Service.share ~root ~change:(change "change-b")
          ~revision:(revision "revision-b")
        |> require_ok Service.error_to_string
      in
      let decision = List.hd overlapping.Service.open_decisions in
      let destination = Filename.concat root "isolated" in
      Unix.mkdir destination 0o700;
      let candidates =
        Service.materialize_decision ~root ~decision:decision.Model.decision_id
          ~destination
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int) "two candidate trees" 2 (List.length candidates);
      Alcotest.(check (list string))
        "candidate directories use safe display handles"
        [ "alice-001"; "alice-002" ]
        (List.map
           (fun candidate -> Filename.basename candidate.Service.directory)
           candidates);
      Alcotest.(check string)
        "logical revision identifier remains inspectable" "../outside"
        (Model.Revision_id.to_string (List.hd candidates).Service.revision);
      Alcotest.(check bool)
        "revision identifier cannot escape the requested destination" false
        (Sys.file_exists (Filename.concat root "outside"));
      let occupied = Filename.concat root "occupied" in
      Unix.mkdir occupied 0o700;
      write_file occupied "stale" "not empty\n";
      (match
         Service.materialize_decision ~root ~decision:decision.Model.decision_id
           ~destination:occupied
       with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "materialized into a nonempty destination");
      let chosen = (List.hd candidates).Service.directory in
      let resolved =
        Service.resolve ~root ~decision:decision.Model.decision_id
          ~change:(change "change-resolution")
          ~revision:(revision "revision-resolution")
          ~tree:(Some chosen)
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "isolated resolve clears the decision" 0
        (List.length resolved.Service.open_decisions);
      Alcotest.(check string)
        "live tree is unchanged" "let version = 3\n" (read_file root "main.ml"))

let isolated_inspection_compares_exact_candidate_snapshots () =
  with_directory "yeokcham-v4-service-inspect-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      write_file root "main.ml" "let version = 2\n";
      ignore
        (Service.share ~root ~change:(change "change-a")
           ~revision:(revision "revision-a")
        |> require_ok Service.error_to_string);
      ignore
        (Service.new_draft ~root ~id:(draft "draft-two") ~title:"second work"
        |> require_ok Service.error_to_string);
      write_file root "main.ml" "let version = 3\n";
      let overlapping =
        Service.share ~root ~change:(change "change-b")
          ~revision:(revision "revision-b")
        |> require_ok Service.error_to_string
      in
      let decision = List.hd overlapping.Service.open_decisions in
      let before = Service.status ~root |> require_ok Service.error_to_string in
      let inspection =
        Service.inspect_decision ~root ~decision:decision.Model.decision_id
        |> require_ok Service.error_to_string
      in
      Alcotest.(check (list string))
        "inspection includes canonical local display names" [ "alice"; "alice" ]
        (List.map
           (fun candidate ->
             candidate.Service.inspected_username
             |> Option.map Model.Username.to_string
             |> Option.value ~default:"missing")
           inspection.Service.inspected_candidates);
      let comparison =
        Service.compare_decision ~root ~decision:decision.Model.decision_id
          ~candidate:(revision "revision-b")
          ~against:(Service.Candidate (revision "revision-a"))
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "candidate comparison reports the exact changed file" 1
        (List.length comparison.Service.differences);
      let difference = List.hd comparison.Service.differences in
      Alcotest.(check string)
        "difference names the changed path" "main.ml"
        (Model.Path.to_string difference.Service.path);
      Alcotest.(check bool)
        "comparison has both snapshot states" true
        (Option.is_some difference.Service.before
        && Option.is_some difference.Service.after);
      let after = Service.status ~root |> require_ok Service.error_to_string in
      Alcotest.(check string)
        "inspection does not publish a state transition"
        (Model.Snapshot_id.to_string before.Service.checkpoint)
        (Model.Snapshot_id.to_string after.Service.checkpoint);
      Alcotest.(check string)
        "inspection does not rewrite live bytes" "let version = 3\n"
        (read_file root "main.ml");
      match
        Service.compare_decision ~root ~decision:decision.Model.decision_id
          ~candidate:(revision "not-a-candidate")
          ~against:Service.Baseline
      with
      | Error error ->
          Alcotest.(check string)
            "inspection rejects a non-candidate revision" "unknown revision"
            (Service.error_to_string error)
      | Ok _ -> Alcotest.fail "inspection accepted a non-candidate revision")

let exact_proposal_materializes_without_accepting_or_rewriting () =
  with_directory "yeokcham-v4-service-proposal-ready-" (fun root ->
      with_external_directory "yeokcham-v4-proposal-output-" (fun output_root ->
          write_file root "main.ml" "let version = 1\n";
          write_file root "left.txt" "base-left\n";
          write_file root "right.txt" "base-right\n";
          ignore (initialize root);
          write_file root "main.ml" "let version = 2\n";
          write_file root "left.txt" "left-change\n";
          ignore
            (Service.share ~root ~change:(change "change-a")
               ~revision:(revision "revision-a")
            |> require_ok Service.error_to_string);
          ignore
            (Service.new_draft ~root ~id:(draft "draft-two")
               ~title:"second work"
            |> require_ok Service.error_to_string);
          write_file root "left.txt" "base-left\n";
          write_file root "right.txt" "right-change\n";
          let conflicting =
            Service.share ~root ~change:(change "change-b")
              ~revision:(revision "revision-b")
            |> require_ok Service.error_to_string
          in
          let decision = List.hd conflicting.Service.open_decisions in
          let pairs =
            Service.proposal_pairs ~root ~decision:decision.Model.decision_id
            |> require_ok Service.error_to_string
          in
          Alcotest.(check (list (pair string string)))
            "one canonical candidate pair"
            [ ("revision-a", "revision-b") ]
            (List.map
               (fun (left, right) ->
                 ( Model.Revision_id.to_string left,
                   Model.Revision_id.to_string right ))
               pairs);
          let proposal =
            Service.propose_decision ~root ~decision:decision.Model.decision_id
              ~left:(revision "revision-b") ~right:(revision "revision-a")
            |> require_ok Service.error_to_string
          in
          Alcotest.(check bool)
            "all unambiguous paths form an exact proposal" true
            (match proposal.Proposal.readiness with
            | Proposal.Ready -> true
            | Proposal.Refused _ -> false);
          Alcotest.(check (list string))
            "each source is explicit per path"
            [ "left.txt:left"; "main.ml:left"; "right.txt:right" ]
            (Proposal.selected proposal |> Option.get
            |> List.map (fun (path, source, _) ->
                Model.Path.to_string path ^ ":"
                ^ Proposal.source_to_string source));
          let before =
            Service.status ~root |> require_ok Service.error_to_string
          in
          let inside_worktree = Filename.concat root "forbidden-proposal" in
          Unix.mkdir inside_worktree 0o700;
          let[@warning "-4"] reject_inside_worktree = function
            | Error (Service.Proposal_destination_inside_worktree _) -> ()
            | Error error ->
                Alcotest.fail
                  ("wrong inside-worktree refusal: "
                  ^ Service.error_to_string error)
            | Ok _ -> Alcotest.fail "proposal materialized inside the worktree"
          in
          reject_inside_worktree
            (Service.materialize_decision_proposal ~root
               ~decision:decision.Model.decision_id
               ~left:(revision "revision-a") ~right:(revision "revision-b")
               ~destination:inside_worktree);
          Alcotest.(check int)
            "inside-worktree rejection wrote no bytes" 0
            (Array.length (Sys.readdir inside_worktree));
          let destination = Filename.concat output_root "proposal" in
          Unix.mkdir destination 0o700;
          let materialized =
            Service.materialize_decision_proposal ~root
              ~decision:decision.Model.decision_id ~left:(revision "revision-a")
              ~right:(revision "revision-b") ~destination
            |> require_ok Service.error_to_string
          in
          Alcotest.(check string)
            "proposal is materialized at the requested path" destination
            materialized.Service.proposal_directory;
          Alcotest.(check string)
            "materialized common bytes are exact" "let version = 2\n"
            (read_file destination "main.ml");
          Alcotest.(check string)
            "materialized left selection is exact" "left-change\n"
            (read_file destination "left.txt");
          Alcotest.(check string)
            "materialized right selection is exact" "right-change\n"
            (read_file destination "right.txt");
          let after_materialize =
            Service.status ~root |> require_ok Service.error_to_string
          in
          Alcotest.(check int)
            "proposal did not resolve the decision" 1
            (List.length after_materialize.Service.open_decisions);
          Alcotest.(check string)
            "proposal did not advance the project checkpoint"
            (Model.Snapshot_id.to_string before.Service.checkpoint)
            (Model.Snapshot_id.to_string after_materialize.Service.checkpoint);
          Alcotest.(check string)
            "proposal did not rewrite live bytes" "base-left\n"
            (read_file root "left.txt");
          let resolved =
            Service.resolve ~root ~decision:decision.Model.decision_id
              ~change:(change "change-resolution")
              ~revision:(revision "revision-resolution")
              ~tree:(Some destination)
            |> require_ok Service.error_to_string
          in
          Alcotest.(check int)
            "separate explicit resolve records the choice" 0
            (List.length resolved.Service.open_decisions);
          let stale_destination =
            Filename.concat output_root "stale-proposal"
          in
          Unix.mkdir stale_destination 0o700;
          let[@warning "-4"] check_stale = function
            | Error
                (Service.Stale_proposal
                   { reason = Service.Decision_not_open; _ }) ->
                Alcotest.(check int)
                  "stale proposal wrote no destination bytes" 0
                  (Array.length (Sys.readdir stale_destination))
            | Error error ->
                Alcotest.fail
                  ("wrong stale proposal failure: "
                  ^ Service.error_to_string error)
            | Ok _ ->
                Alcotest.fail
                  "a resolved decision materialized a stale proposal"
          in
          check_stale
            (Service.materialize_decision_proposal ~root
               ~decision:decision.Model.decision_id
               ~left:(revision "revision-a") ~right:(revision "revision-b")
               ~destination:stale_destination)))

let proposal_refusal_and_missing_closure_leave_every_destination_untouched () =
  with_directory "yeokcham-v4-service-proposal-refusal-" (fun root ->
      with_external_directory "yeokcham-v4-proposal-output-" (fun output_root ->
          write_file root "main.ml" "let version = 1\n";
          ignore (initialize root);
          write_file root "main.ml" "let version = 2\n";
          ignore
            (Service.share ~root ~change:(change "change-a")
               ~revision:(revision "revision-a")
            |> require_ok Service.error_to_string);
          ignore
            (Service.new_draft ~root ~id:(draft "draft-two")
               ~title:"second work"
            |> require_ok Service.error_to_string);
          write_file root "main.ml" "let version = 3\n";
          let conflicting =
            Service.share ~root ~change:(change "change-b")
              ~revision:(revision "revision-b")
            |> require_ok Service.error_to_string
          in
          let decision = List.hd conflicting.Service.open_decisions in
          let before =
            Service.status ~root |> require_ok Service.error_to_string
          in
          let refused_destination =
            Filename.concat output_root "refused-proposal"
          in
          Unix.mkdir refused_destination 0o700;
          let[@warning "-4"] has_conflicting_paths = function
            | Proposal.Conflicting_paths _ -> true
            | _ -> false
          in
          let[@warning "-4"] check_refusal = function
            | Error (Service.Proposal_refused refusals) ->
                Alcotest.(check bool)
                  "content conflict is named" true
                  (List.exists has_conflicting_paths refusals)
            | Error error ->
                Alcotest.fail
                  ("wrong proposal refusal: " ^ Service.error_to_string error)
            | Ok _ -> Alcotest.fail "conflicting proposal was materialized"
          in
          check_refusal
            (Service.materialize_decision_proposal ~root
               ~decision:decision.Model.decision_id
               ~left:(revision "revision-a") ~right:(revision "revision-b")
               ~destination:refused_destination);
          Alcotest.(check int)
            "refused proposal wrote no destination bytes" 0
            (Array.length (Sys.readdir refused_destination));
          let after_refusal =
            Service.status ~root |> require_ok Service.error_to_string
          in
          Alcotest.(check int)
            "refusal leaves the decision open" 1
            (List.length after_refusal.Service.open_decisions);
          Alcotest.(check string)
            "refusal leaves live bytes alone" "let version = 3\n"
            (read_file root "main.ml");
          Alcotest.(check string)
            "refusal leaves the state checkpoint alone"
            (Model.Snapshot_id.to_string before.Service.checkpoint)
            (Model.Snapshot_id.to_string after_refusal.Service.checkpoint);
          let candidate =
            decision.Model.candidates |> List.hd |> fun candidate ->
            candidate.Model.candidate_revision
          in
          Unix.unlink
            (object_path root
               (Model.Snapshot_id.to_string candidate.Model.result_snapshot));
          let missing_destination =
            Filename.concat output_root "missing-closure"
          in
          Unix.mkdir missing_destination 0o700;
          let[@warning "-4"] check_missing_closure = function
            | Error (Service.Snapshot_error _) -> ()
            | Error error ->
                Alcotest.fail
                  ("wrong missing-closure failure: "
                  ^ Service.error_to_string error)
            | Ok _ -> Alcotest.fail "missing proposal closure was materialized"
          in
          check_missing_closure
            (Service.materialize_decision_proposal ~root
               ~decision:decision.Model.decision_id
               ~left:(revision "revision-a") ~right:(revision "revision-b")
               ~destination:missing_destination);
          Alcotest.(check int)
            "missing closure wrote no destination bytes" 0
            (Array.length (Sys.readdir missing_destination));
          Alcotest.(check string)
            "missing closure still did not rewrite live bytes"
            "let version = 3\n" (read_file root "main.ml")))

let proposal_pair_overview_lists_every_competing_pair_once () =
  with_directory "yeokcham-v4-service-proposal-pairs-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      write_file root "main.ml" "let version = 2\n";
      ignore
        (Service.share ~root ~change:(change "change-a")
           ~revision:(revision "revision-a")
        |> require_ok Service.error_to_string);
      ignore
        (Service.new_draft ~root ~id:(draft "draft-two") ~title:"second work"
        |> require_ok Service.error_to_string);
      write_file root "main.ml" "let version = 3\n";
      ignore
        (Service.share ~root ~change:(change "change-b")
           ~revision:(revision "revision-b")
        |> require_ok Service.error_to_string);
      ignore
        (Service.new_draft ~root ~id:(draft "draft-three") ~title:"third work"
        |> require_ok Service.error_to_string);
      write_file root "main.ml" "let version = 4\n";
      let status =
        Service.share ~root ~change:(change "change-c")
          ~revision:(revision "revision-c")
        |> require_ok Service.error_to_string
      in
      let decision = List.hd status.Service.open_decisions in
      let pairs =
        Service.proposal_pairs ~root ~decision:decision.Model.decision_id
        |> require_ok Service.error_to_string
      in
      Alcotest.(check (list (pair string string)))
        "all unordered candidate pairs are listed in canonical order"
        [
          ("revision-a", "revision-b");
          ("revision-a", "revision-c");
          ("revision-b", "revision-c");
        ]
        (List.map
           (fun (left, right) ->
             ( Model.Revision_id.to_string left,
               Model.Revision_id.to_string right ))
           pairs))

let exact_proposal_preserves_binary_bytes_and_symlink_targets () =
  with_directory "yeokcham-v4-service-proposal-bytes-" (fun root ->
      with_external_directory "yeokcham-v4-proposal-output-" (fun output_root ->
          write_file root "binary.dat" "\000initial\255";
          Unix.symlink "target-initial" (Filename.concat root "link");
          ignore (initialize root);
          write_file root "binary.dat" "\000shared\255";
          Unix.unlink (Filename.concat root "link");
          Unix.symlink "target-shared" (Filename.concat root "link");
          ignore
            (Service.share ~root ~change:(change "change-a")
               ~revision:(revision "revision-a")
            |> require_ok Service.error_to_string);
          ignore
            (Service.new_draft ~root ~id:(draft "draft-two")
               ~title:"second work"
            |> require_ok Service.error_to_string);
          let conflicting =
            Service.share ~root ~change:(change "change-b")
              ~revision:(revision "revision-b")
            |> require_ok Service.error_to_string
          in
          let decision = List.hd conflicting.Service.open_decisions in
          let destination = Filename.concat output_root "binary-proposal" in
          Unix.mkdir destination 0o700;
          ignore
            (Service.materialize_decision_proposal ~root
               ~decision:decision.Model.decision_id
               ~left:(revision "revision-a") ~right:(revision "revision-b")
               ~destination
            |> require_ok Service.error_to_string);
          Alcotest.(check string)
            "binary content is not parsed or altered" "\000shared\255"
            (read_file destination "binary.dat");
          Alcotest.(check string)
            "symlink target bytes are exact" "target-shared"
            (Unix.readlink (Filename.concat destination "link"))))

let withdraw_protects_the_active_shared_change () =
  with_directory "yeokcham-v4-service-withdraw-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      write_file root "main.ml" "let version = 2\n";
      ignore
        (Service.share ~root ~change:(change "change-a")
           ~revision:(revision "revision-a")
        |> require_ok Service.error_to_string);
      (match Service.withdraw ~root ~change:(change "change-a") with
      | Error error ->
          Alcotest.(check string)
            "active shared change cannot be withdrawn"
            "close the active draft before withdrawing its shared change"
            (Service.error_to_string error)
      | Ok _ -> Alcotest.fail "withdrew the active shared change");
      ignore
        (Service.new_draft ~root ~id:(draft "draft-two") ~title:"follow-up"
        |> require_ok Service.error_to_string);
      let withdrawn =
        Service.withdraw ~root ~change:(change "change-a")
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "withdrawn change leaves the projection" 0
        (List.length withdrawn.Service.open_decisions);
      Alcotest.(check int)
        "shared change remains inspectable" 1
        withdrawn.Service.shared_change_count)

let resolve_clears_the_open_decision () =
  with_directory "yeokcham-v4-service-resolve-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      write_file root "main.ml" "let version = 2\n";
      ignore
        (Service.share ~root ~change:(change "change-a")
           ~revision:(revision "revision-a")
        |> require_ok Service.error_to_string);
      ignore
        (Service.new_draft ~root ~id:(draft "draft-two") ~title:"second work"
        |> require_ok Service.error_to_string);
      write_file root "main.ml" "let version = 3\n";
      let overlapping =
        Service.share ~root ~change:(change "change-b")
          ~revision:(revision "revision-b")
        |> require_ok Service.error_to_string
      in
      let decision = List.hd overlapping.Service.open_decisions in
      let resolved =
        Service.resolve ~root ~decision:decision.Model.decision_id
          ~change:(change "change-resolution")
          ~revision:(revision "revision-resolution")
          ~tree:None
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "resolution removes the open decision" 0
        (List.length resolved.Service.open_decisions))

let deliver_requires_a_decision_free_shared_draft () =
  with_directory "yeokcham-v4-service-deliver-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      ignore (initialize root);
      write_file root "main.ml" "let version = 2\n";
      ignore
        (Service.share ~root ~change:(change "change-a")
           ~revision:(revision "revision-a")
        |> require_ok Service.error_to_string);
      ignore
        (Service.new_draft ~root ~id:(draft "draft-two") ~title:"second work"
        |> require_ok Service.error_to_string);
      write_file root "main.ml" "let version = 3\n";
      let overlapping =
        Service.share ~root ~change:(change "change-b")
          ~revision:(revision "revision-b")
        |> require_ok Service.error_to_string
      in
      (match
         Service.deliver ~root ~id:(delivery "delivery-one")
           ~next_draft:(draft "draft-after") ~next_title:"after delivery"
       with
      | Error error ->
          Alcotest.(check string)
            "open decisions block delivery"
            "cannot deliver while decisions are open"
            (Service.error_to_string error)
      | Ok _ -> Alcotest.fail "delivered through an open decision");
      let decision = List.hd overlapping.Service.open_decisions in
      ignore
        (Service.resolve ~root ~decision:decision.Model.decision_id
           ~change:(change "change-resolution")
           ~revision:(revision "revision-resolution")
           ~tree:None
        |> require_ok Service.error_to_string);
      let delivered =
        Service.deliver ~root ~id:(delivery "delivery-one")
          ~next_draft:(draft "draft-after") ~next_title:"after delivery"
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "delivery is inspectable" 1 delivered.Service.delivery_count;
      Alcotest.(check string)
        "delivery starts a new active draft" "draft-after"
        (Model.Draft_id.to_string delivered.Service.active_draft.Model.draft_id))

let signed_offline_receive_is_atomic_and_preserves_the_live_tree () =
  with_directory "yeokcham-v4-signed-receive-" (fun root ->
      let source = Filename.concat root "source" in
      let destination = Filename.concat root "destination" in
      Unix.mkdir source 0o700;
      Unix.mkdir destination 0o700;
      write_file source "main.ml" "let version = 1\n";
      write_file destination "main.ml" "let version = 1\n";
      let administrator_capability = signing_capability 'a' in
      let administrator = trust_device administrator_capability in
      let recovery_capability = signing_capability 'r' in
      let recovery_device = trust_device recovery_capability in
      ignore
        (Service.init_signed_with_recovery ~root:source
           ~username:(username "alice") ~initial_draft:(draft "draft-source")
           ~title:"source" ~repository ~device:administrator
           ~signing_capability:administrator_capability ~recovery_device
           ~recovery_capability
        |> require_ok Service.error_to_string);
      write_file source "main.ml" "let version = 2\n";
      ignore
        (Service.share_signed ~authority_epoch:None ~root:source
           ~change:(change "change-source")
           ~revision:(revision "revision-source")
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      let package = Filename.concat root "source-package" in
      Service.create_package ~root:source ~destination:package
      |> require_ok Service.error_to_string;
      let member_capability = signing_capability 'b' in
      let member = trust_device member_capability in
      let root_certificate =
        Trust.root_certificate ~repository ~device:administrator
          administrator_capability
        |> require_ok Trust.error_to_string
      in
      let root_membership =
        Trust.verify_membership ~repository [ root_certificate ]
        |> require_ok Trust.error_to_string
      in
      let member_certificate =
        Trust.enroll root_membership
          ~issuer:(Trust.certificate_id root_certificate)
          administrator_capability ~subject:member ~role:Trust.Member
        |> require_ok Trust.error_to_string
      in
      let membership =
        Trust.verify_membership ~repository
          [ root_certificate; member_certificate ]
        |> require_ok Trust.error_to_string
      in
      let root_epoch =
        Trust.root_epoch ~membership
          ~root_certificate:(Trust.certificate_id root_certificate)
          ~recovery_device administrator_capability
        |> require_ok Trust.error_to_string
      in
      let root_authority =
        Trust.verify_authority ~membership [ root_epoch ]
        |> require_ok Trust.error_to_string
      in
      let member_epoch =
        Trust.successor_epoch root_authority
          ~parents:[ Trust.epoch_id root_epoch ]
          ~certificates:(Trust.certificates membership)
          ~revoked:[] ~frontier:[] ~recovery_device
          ~issuer:(Trust.certificate_id root_certificate)
          administrator_capability
        |> require_ok Trust.error_to_string
      in
      let authority =
        Trust.extend_authority root_authority [ member_epoch ]
        |> require_ok Trust.error_to_string
      in
      ignore
        (Service.init_authority_collaboration ~root:destination
           ~username:(username "bob")
           ~initial_draft:(draft "draft-destination")
           ~title:"destination" ~device:member ~authority
           ~local_certificate:(Trust.certificate_id member_certificate)
        |> require_ok Service.error_to_string);
      let received =
        Service.receive_package ~root:destination ~package
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "verified receive makes the shared change visible" 1
        received.Service.shared_change_count;
      Alcotest.(check string)
        "receive leaves the receiver working tree untouched" "let version = 1\n"
        (read_file destination "main.ml");
      let repeated =
        Service.receive_package ~root:destination ~package
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "repeating receive is model-idempotent" 1
        repeated.Service.shared_change_count;
      write_file destination "main.ml" "let version = 3\n";
      let after_member_share =
        Service.share_signed ~authority_epoch:None ~root:destination
          ~change:(change "change-member")
          ~revision:(revision "revision-member")
          ~signing_capability:member_capability
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "an enrolled local device can author its own signed revision" 2
        after_member_share.Service.shared_change_count;
      let destination_repository =
        Store.open_repository ~root:destination
        |> require_ok Store.error_to_string
      in
      let destination_state =
        Store.load destination_repository |> require_ok Store.error_to_string
      in
      let signed_member_revision =
        match destination_state.Store.collaboration with
        | None ->
            Alcotest.fail "signed destination lost its collaboration state"
        | Some collaboration -> (
            Store.signed_revisions collaboration
            |> List.find_opt (fun signed ->
                Model.Revision_id.equal
                  (Trust.signed_revision_id signed)
                  (revision "revision-member"))
            |> function
            | Some signed -> signed
            | None -> Alcotest.fail "member revision is unsigned")
      in
      Alcotest.(check bool)
        "the signature binds the enrolled device" true
        (Model.Device_id.equal
           (Trust.signed_revision_value signed_member_revision)
             .Model.revision_author (Trust.device_id member));
      let forwarded = Filename.concat root "forwarded-package" in
      Service.create_package ~root:destination ~destination:forwarded
      |> require_ok Service.error_to_string;
      Alcotest.(check bool)
        "a receiver retains signed proof for later offline forwarding" true
        (Sys.file_exists (Filename.concat forwarded "manifest.cbor")))

let administrator_enrollment_persists_a_public_member_and_local_username () =
  with_directory "yeokcham-v4-enrollment-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let administrator_capability = signing_capability 'a' in
      let administrator = trust_device administrator_capability in
      let recovery_capability = signing_capability 'r' in
      let recovery_device = trust_device recovery_capability in
      ignore
        (Service.init_signed_with_recovery ~root ~username:(username "alice")
           ~initial_draft:(draft "draft-one") ~title:"admin" ~repository
           ~device:administrator ~signing_capability:administrator_capability
           ~recovery_device ~recovery_capability
        |> require_ok Service.error_to_string);
      let member = trust_device (signing_capability 'b') in
      let enrolled =
        Service.enroll_device ~parent:None ~root ~subject:member
          ~role:Trust.Member ~username:(username "bob")
          ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string
      in
      Alcotest.(check (list string))
        "the local username registry records the new display name" [ "bob" ]
        (enrolled.Service.usernames
        |> List.filter_map (fun registration ->
            if
              Model.Device_id.equal registration.Model.username_device
                (Trust.device_id member)
            then Some (Model.Username.to_string registration.Model.username)
            else None));
      let repository =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let loaded = Store.load repository |> require_ok Store.error_to_string in
      let membership =
        match loaded.Store.collaboration with
        | Some collaboration -> Store.membership collaboration
        | None -> Alcotest.fail "signed project lost collaboration state"
      in
      Alcotest.(check bool)
        "member is present in public membership" true
        (Trust.is_authorized membership member))

let authority_initialized_repositories_exchange_verified_epoch_bound_work () =
  with_directory "yeokcham-v4-authority-source-" (fun parent ->
      let source = Filename.concat parent "source" in
      let destination = Filename.concat parent "destination" in
      Unix.mkdir source 0o700;
      Unix.mkdir destination 0o700;
      write_file source "main.ml" "let version = 1\n";
      write_file destination "main.ml" "let version = 1\n";
      let administrator_capability = signing_capability 'a' in
      let administrator = trust_device administrator_capability in
      let recovery_capability = signing_capability 'r' in
      let recovery_device = trust_device recovery_capability in
      let _status, ceremony =
        Service.init_signed_with_recovery ~root:source
          ~username:(username "alice") ~initial_draft:(draft "draft-source")
          ~title:"source" ~repository ~device:administrator
          ~signing_capability:administrator_capability ~recovery_device
          ~recovery_capability
        |> require_ok Service.error_to_string
      in
      let recovery_package =
        In_channel.with_open_bin
          (Service.recovery_package_path source)
          In_channel.input_all
        |> Recovery.decode
        |> require_ok Recovery.error_to_string
      in
      let recovered =
        Recovery.recover ~mnemonic:ceremony.Recovery.mnemonic
          ~package:recovery_package
        |> require_ok Recovery.error_to_string
      in
      Alcotest.(check int)
        "initial recovery package carries the root closure" 1
        (List.length
           (Trust.authority_heads (Recovery.recovered_authority recovered)));
      let member_capability = signing_capability 'b' in
      let member = trust_device member_capability in
      ignore
        (Service.enroll_device ~parent:None ~root:source ~subject:member
           ~role:Trust.Member ~username:(username "bob")
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      let source_repository =
        Store.open_repository ~root:source |> require_ok Store.error_to_string
      in
      let source_loaded =
        Store.load source_repository |> require_ok Store.error_to_string
      in
      let source_authority =
        match source_loaded.Store.collaboration with
        | Some collaboration -> (
            match Store.authority collaboration with
            | Some authority -> authority
            | None ->
                Alcotest.fail "new signed initialization wrote a legacy state")
        | None ->
            Alcotest.fail "new signed initialization lost collaboration state"
      in
      ignore
        (Service.init_authority_collaboration ~root:destination
           ~username:(username "bob")
           ~initial_draft:(draft "draft-destination")
           ~title:"destination" ~device:member ~authority:source_authority
           ~local_certificate:
             (Trust.certificates (Trust.authority_membership source_authority)
             |> List.find (fun certificate ->
                 Model.Device_id.equal
                   (Trust.device_id (Trust.certificate_subject certificate))
                   (Trust.device_id member))
             |> Trust.certificate_id)
        |> require_ok Service.error_to_string);
      write_file source "main.ml" "let version = 2\n";
      ignore
        (Service.share_signed ~authority_epoch:None ~root:source
           ~change:(change "change-source")
           ~revision:(revision "revision-source")
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      let package = Filename.concat parent "authority-package" in
      Service.create_package ~root:source ~destination:package
      |> require_ok Service.error_to_string;
      let received =
        Service.receive_package ~root:destination ~package
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "epoch-bound revision becomes visible after receive" 1
        received.Service.shared_change_count;
      Alcotest.(check string)
        "receive does not materialize incoming bytes" "let version = 1\n"
        (read_file destination "main.ml"))

let signed_transport_receive_is_atomic_and_idempotent () =
  with_directory "yeokcham-v4-transport-receive-" (fun parent ->
      let source = Filename.concat parent "source" in
      let destination = Filename.concat parent "destination" in
      Unix.mkdir source 0o700;
      Unix.mkdir destination 0o700;
      write_file source "main.ml" "let version = 1\n";
      write_file destination "main.ml" "let version = 1\n";
      let administrator_capability = signing_capability 'a' in
      let administrator = trust_device administrator_capability in
      let recovery_capability = signing_capability 'r' in
      let recovery_device = trust_device recovery_capability in
      ignore
        (Service.init_signed_with_recovery ~root:source
           ~username:(username "alice") ~initial_draft:(draft "draft-source")
           ~title:"source" ~repository ~device:administrator
           ~signing_capability:administrator_capability ~recovery_device
           ~recovery_capability
        |> require_ok Service.error_to_string);
      let member_capability = signing_capability 'b' in
      let member = trust_device member_capability in
      ignore
        (Service.enroll_device ~parent:None ~root:source ~subject:member
           ~role:Trust.Member ~username:(username "bob")
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      let source_repository =
        Store.open_repository ~root:source |> require_ok Store.error_to_string
      in
      let source_loaded =
        Store.load source_repository |> require_ok Store.error_to_string
      in
      let authority =
        match source_loaded.Store.collaboration with
        | Some collaboration -> (
            match Store.authority collaboration with
            | Some authority -> authority
            | None -> Alcotest.fail "transport source has no authority")
        | None -> Alcotest.fail "transport source lost collaboration"
      in
      let member_certificate =
        Trust.certificates (Trust.authority_membership authority)
        |> List.find (fun certificate ->
            Trust.device_equal (Trust.certificate_subject certificate) member)
        |> Trust.certificate_id
      in
      ignore
        (Service.init_authority_collaboration ~root:destination
           ~username:(username "bob")
           ~initial_draft:(draft "draft-destination")
           ~title:"destination" ~device:member ~authority
           ~local_certificate:member_certificate
        |> require_ok Service.error_to_string);
      write_file source "main.ml" "let version = 2\n";
      ignore
        (Service.share_signed ~authority_epoch:None ~root:source
           ~change:(change "change-transport")
           ~revision:(revision "revision-transport")
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      let outbound =
        Service.prepare_transport_outbound ~root:source ~remote:"team"
          ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string
      in
      let outbound =
        match outbound with
        | Some outbound -> outbound
        | None ->
            Alcotest.fail "new signed revision produced no transport package"
      in
      let package = Filename.concat parent "transport-package" in
      Package.materialize_artifact ~destination:package
        outbound.Service.outbound_artifact
      |> require_ok Package.error_to_string;
      let source_identity =
        Service.identity ~root:source |> require_ok Service.error_to_string
      in
      let mismatched_publication =
        Transport.create_publication ~repository
          ~publisher:source_identity.Service.device
          ~certificate:
            (Transport.publication_certificate
               outbound.Service.outbound_publication)
          ~parents:[]
          ~manifest:(Transport.sha256 "different manifest")
          ~signing_capability:administrator_capability
        |> require_ok Transport.error_to_string
      in
      (match
         Service.receive_transport_batch ~root:destination ~remote:"team"
           ~cursor:None
           [ { Service.publication = mismatched_publication; package } ]
       with
      | Error error ->
          Alcotest.(check string)
            "publication/package binding is explicit"
            "invalid V4 transport publication: publication manifest does not \
             match staged package"
            (Service.error_to_string error)
      | Ok _ -> Alcotest.fail "transport accepted an unrelated package manifest");
      let before_receive =
        Service.status ~root:destination |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "mismatched package changes no model state" 0
        before_receive.Service.shared_change_count;
      let arrival =
        { Service.publication = outbound.Service.outbound_publication; package }
      in
      let received =
        Service.receive_transport_batch ~root:destination ~remote:"team"
          ~cursor:
            (Some
               (Yeokcham_v4_transport.publication_id
                  outbound.Service.outbound_publication))
          [ arrival ]
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "one publication is received" 1 received.Service.discovered_publications;
      Alcotest.(check int)
        "one signed revision is received" 1 received.Service.received_revisions;
      Alcotest.(check int)
        "shared work appears in the destination model" 1
        received.Service.transport_status.Service.shared_change_count;
      Alcotest.(check string)
        "transport never materializes package bytes" "let version = 1\n"
        (read_file destination "main.ml");
      let replay =
        Service.receive_transport_batch ~root:destination ~remote:"team"
          ~cursor:None [ arrival ]
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "known publication is idempotent" 0
        replay.Service.discovered_publications;
      Alcotest.(check int)
        "idempotent replay does not duplicate work" 1
        replay.Service.transport_status.Service.shared_change_count)

let signed_resolution_is_persisted_with_its_decision_purpose () =
  with_directory "yeokcham-v4-signed-resolution-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let administrator_capability = signing_capability 'a' in
      let administrator = trust_device administrator_capability in
      let recovery_capability = signing_capability 'r' in
      let recovery_device = trust_device recovery_capability in
      ignore
        (Service.init_signed_with_recovery ~root ~username:(username "alice")
           ~initial_draft:(draft "draft-one") ~title:"authority" ~repository
           ~device:administrator ~signing_capability:administrator_capability
           ~recovery_device ~recovery_capability
        |> require_ok Service.error_to_string);
      write_file root "main.ml" "let version = 2\n";
      ignore
        (Service.share_signed ~authority_epoch:None ~root
           ~change:(change "change-a") ~revision:(revision "revision-a")
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      ignore
        (Service.new_draft ~root ~id:(draft "draft-two") ~title:"second work"
        |> require_ok Service.error_to_string);
      write_file root "main.ml" "let version = 3\n";
      let conflicting =
        Service.share_signed ~authority_epoch:None ~root
          ~change:(change "change-b") ~revision:(revision "revision-b")
          ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string
      in
      let decision = List.hd conflicting.Service.open_decisions in
      ignore
        (Service.resolve_signed ~authority_epoch:None ~root
           ~decision:decision.Model.decision_id
           ~change:(change "change-resolution")
           ~revision:(revision "revision-resolution")
           ~tree:None ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      let repository =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let loaded = Store.load repository |> require_ok Store.error_to_string in
      let collaboration =
        match loaded.Store.collaboration with
        | Some collaboration -> collaboration
        | None -> Alcotest.fail "signed resolution lost collaboration state"
      in
      let signed_resolution =
        Store.signed_revisions collaboration
        |> List.find_opt (fun signed ->
            Option.is_some (Trust.signed_revision_resolution signed))
      in
      match signed_resolution with
      | Some signed ->
          Alcotest.(check (option string))
            "persisted signed resolution names its exact decision"
            (Some (Model.Decision_id.to_string decision.Model.decision_id))
            (Trust.signed_revision_resolution signed
            |> Option.map Model.Decision_id.to_string)
      | None -> Alcotest.fail "resolution was persisted as ordinary shared work")

let authority_lifecycle_revokes_rotates_and_recovers_a_replacement_device () =
  with_directory "yeokcham-v4-authority-lifecycle-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let administrator_capability = signing_capability 'a' in
      let administrator = trust_device administrator_capability in
      let recovery_capability = signing_capability 'r' in
      let recovery_device = trust_device recovery_capability in
      let _status, first_ceremony =
        Service.init_signed_with_recovery ~root ~username:(username "alice")
          ~initial_draft:(draft "draft-one") ~title:"authority" ~repository
          ~device:administrator ~signing_capability:administrator_capability
          ~recovery_device ~recovery_capability
        |> require_ok Service.error_to_string
      in
      let member_capability = signing_capability 'b' in
      let member = trust_device member_capability in
      ignore
        (Service.enroll_device ~parent:None ~root ~subject:member
           ~role:Trust.Member ~username:(username "bob")
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      ignore
        (Service.revoke_device ~parent:None ~root
           ~device:(Trust.device_id member)
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      let replacement_capability = signing_capability 'c' in
      let replacement = trust_device replacement_capability in
      let output = Filename.concat root "rotated-recovery.cbor" in
      let _status, second_ceremony =
        Service.recover_authority ~root
          ~package:(Service.recovery_package_path root)
          ~mnemonic:first_ceremony.Recovery.mnemonic ~output ~replacement
          ~replaced:(Trust.device_id administrator)
        |> require_ok Service.error_to_string
      in
      let repository_store =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let loaded =
        Store.load repository_store |> require_ok Store.error_to_string
      in
      let collaboration =
        match loaded.Store.collaboration with
        | Some collaboration -> collaboration
        | None -> Alcotest.fail "authority state was not retained"
      in
      let authority =
        match Store.authority collaboration with
        | Some authority -> authority
        | None -> Alcotest.fail "authority state was downgraded to legacy"
      in
      let head =
        match Trust.authority_heads authority with
        | [ head ] -> head
        | _ -> Alcotest.fail "recovery did not leave one current authority head"
      in
      Alcotest.(check bool)
        "recovered replacement is an administrator" true
        (Trust.authority_device_administrator authority ~epoch:head replacement);
      Alcotest.(check bool)
        "replaced administrator is revoked" false
        (Trust.authority_device_active authority ~epoch:head administrator);
      Alcotest.(check bool)
        "ordinary member remains revoked" false
        (Trust.authority_device_active authority ~epoch:head member);
      let recovery_package =
        In_channel.with_open_bin output In_channel.input_all
        |> Recovery.decode
        |> require_ok Recovery.error_to_string
      in
      let recovered =
        Recovery.recover ~mnemonic:second_ceremony.Recovery.mnemonic
          ~package:recovery_package
        |> require_ok Recovery.error_to_string
      in
      Alcotest.(check (list string))
        "rotated package holds the successor closure" [ head ]
        (Trust.authority_heads (Recovery.recovered_authority recovered));
      write_file root "main.ml" "let version = 2\n";
      ignore
        (Service.share_signed ~authority_epoch:None ~root
           ~change:(change "change-recovered")
           ~revision:(revision "revision-recovered")
           ~signing_capability:replacement_capability
        |> require_ok Service.error_to_string))

let normal_device_rotation_replaces_the_local_signing_identity_atomically () =
  with_directory "yeokcham-v4-device-rotation-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let administrator_capability = signing_capability 'a' in
      let administrator = trust_device administrator_capability in
      let recovery_capability = signing_capability 'r' in
      let recovery_device = trust_device recovery_capability in
      ignore
        (Service.init_signed_with_recovery ~root ~username:(username "alice")
           ~initial_draft:(draft "draft-one") ~title:"authority" ~repository
           ~device:administrator ~signing_capability:administrator_capability
           ~recovery_device ~recovery_capability
        |> require_ok Service.error_to_string);
      let replacement_capability = signing_capability 'c' in
      let replacement = trust_device replacement_capability in
      ignore
        (Service.rotate_local_device ~parent:None ~root ~replacement
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      let identity =
        Service.identity ~root |> require_ok Service.error_to_string
      in
      Alcotest.(check bool)
        "the local certificate switches to the replacement" true
        (Trust.device_equal identity.Service.device replacement);
      let heads =
        Service.authority_heads ~root |> require_ok Service.error_to_string
      in
      let head =
        match heads with
        | [ head ] -> head
        | _ -> Alcotest.fail "rotation did not leave one authority head"
      in
      let repository_store =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let loaded =
        Store.load repository_store |> require_ok Store.error_to_string
      in
      let authority =
        match loaded.Store.collaboration with
        | Some collaboration -> (
            match Store.authority collaboration with
            | Some authority -> authority
            | None -> Alcotest.fail "rotation downgraded the authority state")
        | None -> Alcotest.fail "rotation lost collaboration state"
      in
      Alcotest.(check bool)
        "old local device is revoked" false
        (Trust.authority_device_active authority ~epoch:head administrator);
      Alcotest.(check bool)
        "replacement is active" true
        (Trust.authority_device_active authority ~epoch:head replacement);
      write_file root "main.ml" "let version = 2\n";
      ignore
        (Service.share_signed ~authority_epoch:None ~root
           ~change:(change "change-rotated")
           ~revision:(revision "revision-rotated")
           ~signing_capability:replacement_capability
        |> require_ok Service.error_to_string))

let authority_forks_require_named_branch_actions_and_explicit_reconciliation ()
    =
  with_directory "yeokcham-v4-authority-fork-" (fun root ->
      write_file root "main.ml" "let version = 1\n";
      let administrator_capability = signing_capability 'a' in
      let administrator = trust_device administrator_capability in
      let recovery_capability = signing_capability 'r' in
      let recovery_device = trust_device recovery_capability in
      ignore
        (Service.init_signed_with_recovery ~root ~username:(username "alice")
           ~initial_draft:(draft "draft-one") ~title:"authority" ~repository
           ~device:administrator ~signing_capability:administrator_capability
           ~recovery_device ~recovery_capability
        |> require_ok Service.error_to_string);
      let repository_store =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let loaded =
        Store.load repository_store |> require_ok Store.error_to_string
      in
      let collaboration =
        match loaded.Store.collaboration with
        | Some collaboration -> collaboration
        | None -> Alcotest.fail "authority state was not retained"
      in
      let authority =
        match Store.authority collaboration with
        | Some authority -> authority
        | None -> Alcotest.fail "authority state was downgraded to legacy"
      in
      let root_head =
        match Trust.authority_heads authority with
        | [ head ] -> head
        | _ -> Alcotest.fail "initial authority did not have one head"
      in
      let certificates =
        Trust.certificates (Trust.authority_membership authority)
      in
      let left =
        Trust.successor_epoch authority ~parents:[ root_head ] ~certificates
          ~revoked:[]
          ~frontier:[ revision "frontier-left" ]
          ~recovery_device
          ~issuer:(Store.local_certificate collaboration)
          administrator_capability
        |> require_ok Trust.error_to_string
      in
      let right =
        Trust.successor_epoch authority ~parents:[ root_head ] ~certificates
          ~revoked:[]
          ~frontier:[ revision "frontier-right" ]
          ~recovery_device
          ~issuer:(Store.local_certificate collaboration)
          administrator_capability
        |> require_ok Trust.error_to_string
      in
      let forked =
        Trust.extend_authority authority [ left; right ]
        |> require_ok Trust.error_to_string
      in
      let forked_collaboration =
        Store.collaboration_with_authority ~authority:forked
          ~revisions:(Store.signed_revisions collaboration)
          ~local_certificate:(Store.local_certificate collaboration)
          ~authorizations:(Store.authorizations collaboration)
          ~adoptions:(Store.adoptions collaboration)
        |> require_ok Store.error_to_string
      in
      ignore
        (Store.save_collaborative repository_store ~expected:loaded.Store.head
           ~project:loaded.Store.project ~collaboration:forked_collaboration
        |> require_ok Store.error_to_string);
      let member = trust_device (signing_capability 'b') in
      (match
         Service.enroll_device ~parent:None ~root ~subject:member
           ~role:Trust.Member ~username:(username "bob")
           ~signing_capability:administrator_capability
       with
      | Error error ->
          Alcotest.(check string)
            "an unselected fork refuses lifecycle work"
            "V4 authority fork requires an explicit authority selection or \
             reconciliation"
            (Service.error_to_string error)
      | Ok _ ->
          Alcotest.fail "forked enrollment chose authority heads implicitly");
      write_file root "main.ml" "let version = 2\n";
      (match
         Service.share_signed ~authority_epoch:None ~root
           ~change:(change "change-forked")
           ~revision:(revision "revision-forked")
           ~signing_capability:administrator_capability
       with
      | Error error ->
          Alcotest.(check string)
            "an unselected fork refuses signed work"
            "V4 authority fork requires an explicit authority selection or \
             reconciliation"
            (Service.error_to_string error)
      | Ok _ -> Alcotest.fail "forked share chose an authority head implicitly");
      ignore
        (Service.share_signed
           ~authority_epoch:(Some (Trust.epoch_id left))
           ~root ~change:(change "change-forked")
           ~revision:(revision "revision-forked")
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      ignore
        (Service.enroll_device
           ~parent:(Some (Trust.epoch_id left))
           ~root ~subject:member ~role:Trust.Member ~username:(username "bob")
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      let before_reconciliation =
        Service.authority_heads ~root |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "selected branch advancement leaves the other head active" 2
        (List.length before_reconciliation);
      Alcotest.(check bool)
        "the unselected branch remains a head" true
        (List.mem (Trust.epoch_id right) before_reconciliation);
      (match
         Service.reconcile_authority ~root
           ~parents:(List.rev before_reconciliation)
           ~signing_capability:administrator_capability
       with
      | Error error ->
          Alcotest.(check string)
            "reconciliation rejects a noncanonical parent selection"
            "invalid V4 authority epoch: reconciliation parent heads must be \
             strictly sorted and unique"
            (Service.error_to_string error)
      | Ok _ ->
          Alcotest.fail "reconciliation silently reordered explicit parents");
      ignore
        (Service.reconcile_authority ~root ~parents:before_reconciliation
           ~signing_capability:administrator_capability
        |> require_ok Service.error_to_string);
      let heads =
        Service.authority_heads ~root |> require_ok Service.error_to_string
      in
      let head =
        match heads with
        | [ head ] -> head
        | _ -> Alcotest.fail "explicit reconciliation did not close its fork"
      in
      let repository_store =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let loaded =
        Store.load repository_store |> require_ok Store.error_to_string
      in
      let authority =
        match loaded.Store.collaboration with
        | Some collaboration -> (
            match Store.authority collaboration with
            | Some authority -> authority
            | None -> Alcotest.fail "reconciliation downgraded authority state")
        | None -> Alcotest.fail "reconciliation lost authority state"
      in
      let reconciled =
        Trust.authority_epoch authority head |> require_ok Trust.error_to_string
      in
      Alcotest.(check (list string))
        "the durable reconciliation names exactly the selected heads"
        before_reconciliation
        (Trust.epoch_parents reconciled))

let late_package_review_retains_feed_forks_across_retry_before_adoption () =
  with_directory "yeokcham-v4-late-package-review-" (fun parent ->
      let source = Filename.concat parent "source" in
      let destination = Filename.concat parent "destination" in
      Unix.mkdir source 0o700;
      Unix.mkdir destination 0o700;
      write_file source "main.ml" "let version = 1\n";
      write_file destination "main.ml" "let version = 1\n";
      let root_capability = signing_capability 'a' in
      let root_device = trust_device root_capability in
      let recovery_capability = signing_capability 'r' in
      let recovery_device = trust_device recovery_capability in
      ignore
        (Service.init_signed_with_recovery ~root:source
           ~username:(username "alice") ~initial_draft:(draft "draft-source")
           ~title:"source" ~repository ~device:root_device
           ~signing_capability:root_capability ~recovery_device
           ~recovery_capability
        |> require_ok Service.error_to_string);
      let reviewer_capability = signing_capability 'b' in
      let reviewer = trust_device reviewer_capability in
      ignore
        (Service.enroll_device ~parent:None ~root:source ~subject:reviewer
           ~role:Trust.Administrator ~username:(username "bob")
           ~signing_capability:root_capability
        |> require_ok Service.error_to_string);
      let source_repository =
        Store.open_repository ~root:source |> require_ok Store.error_to_string
      in
      let source_loaded =
        Store.load source_repository |> require_ok Store.error_to_string
      in
      let source_collaboration =
        match source_loaded.Store.collaboration with
        | Some collaboration -> collaboration
        | None -> Alcotest.fail "authority source lost collaboration state"
      in
      let authority =
        match Store.authority source_collaboration with
        | Some authority -> authority
        | None -> Alcotest.fail "authority source wrote a legacy state"
      in
      let reviewer_certificate =
        Trust.certificates (Trust.authority_membership authority)
        |> List.find (fun certificate ->
            Trust.device_equal (Trust.certificate_subject certificate) reviewer)
        |> Trust.certificate_id
      in
      ignore
        (Service.init_authority_collaboration ~root:destination
           ~username:(username "bob")
           ~initial_draft:(draft "draft-destination")
           ~title:"destination" ~device:reviewer ~authority
           ~local_certificate:reviewer_certificate
        |> require_ok Service.error_to_string);
      write_file source "main.ml" "let version = 2\n";
      ignore
        (Service.share_signed ~authority_epoch:None ~root:source
           ~change:(change "change-late") ~revision:(revision "revision-late")
           ~signing_capability:root_capability
        |> require_ok Service.error_to_string);
      let source_loaded =
        Store.load source_repository |> require_ok Store.error_to_string
      in
      let source_collaboration =
        match source_loaded.Store.collaboration with
        | Some collaboration -> collaboration
        | None -> Alcotest.fail "source lost collaboration state after sharing"
      in
      let authority =
        match Store.authority source_collaboration with
        | Some authority -> authority
        | None -> Alcotest.fail "source authority was removed after sharing"
      in
      let parent_head =
        match Trust.authority_heads authority with
        | [ head ] -> head
        | _ -> Alcotest.fail "source has an unexpected authority fork"
      in
      let revoked_epoch =
        Trust.successor_epoch authority ~parents:[ parent_head ]
          ~certificates:
            (Trust.certificates (Trust.authority_membership authority))
          ~revoked:[ Trust.device_id root_device ]
          ~frontier:[] ~recovery_device ~issuer:reviewer_certificate
          reviewer_capability
        |> require_ok Trust.error_to_string
      in
      let revoked_authority =
        Trust.extend_authority authority [ revoked_epoch ]
        |> require_ok Trust.error_to_string
      in
      let package = Filename.concat parent "late-record" in
      Yeokcham_v4_package.create_with_authority
        ~source:(Store.underlying_store source_repository)
        ~destination:package ~authority:revoked_authority
        ~revisions:(Store.signed_revisions source_collaboration)
        ~authorizations:[] ~adoptions:[]
      |> require_ok Yeokcham_v4_package.error_to_string;
      write_file source "main.ml" "let version = 3\n";
      ignore
        (Service.share_signed ~authority_epoch:None ~root:source
           ~change:(change "change-late")
           ~revision:(revision "revision-late-second")
           ~signing_capability:root_capability
        |> require_ok Service.error_to_string);
      let source_loaded =
        Store.load source_repository |> require_ok Store.error_to_string
      in
      let source_collaboration =
        match source_loaded.Store.collaboration with
        | Some collaboration -> collaboration
        | None -> Alcotest.fail "source lost collaboration for second package"
      in
      let second_package = Filename.concat parent "late-record-second" in
      Yeokcham_v4_package.create_with_authority
        ~source:(Store.underlying_store source_repository)
        ~destination:second_package ~authority:revoked_authority
        ~revisions:(Store.signed_revisions source_collaboration)
        ~authorizations:[] ~adoptions:[]
      |> require_ok Yeokcham_v4_package.error_to_string;
      let artifact =
        Package.read_artifact ~package |> require_ok Package.error_to_string
      in
      let second_artifact =
        Package.read_artifact ~package:second_package
        |> require_ok Package.error_to_string
      in
      let root_publication =
        Transport.create_publication ~repository ~publisher:reviewer
          ~certificate:reviewer_certificate ~parents:[]
          ~manifest:(Transport.sha256 (Package.artifact_manifest artifact))
          ~signing_capability:reviewer_capability
        |> require_ok Transport.error_to_string
      in
      let child_publication ~artifact =
        Transport.create_publication ~repository ~publisher:reviewer
          ~certificate:reviewer_certificate
          ~parents:[ Transport.publication_id root_publication ]
          ~manifest:(Transport.sha256 (Package.artifact_manifest artifact))
          ~signing_capability:reviewer_capability
        |> require_ok Transport.error_to_string
      in
      let left_publication = child_publication ~artifact in
      let right_publication = child_publication ~artifact:second_artifact in
      let arrivals =
        [
          { Service.publication = root_publication; package };
          { Service.publication = left_publication; package };
          { Service.publication = right_publication; package = second_package };
        ]
      in
      let publication_ids =
        List.map
          (fun arrival -> Transport.publication_id arrival.Service.publication)
          arrivals
        |> List.sort String.compare
      in
      let deferred =
        Service.receive_transport_batch ~root:destination ~remote:"team"
          ~cursor:(Some (Transport.publication_id right_publication))
          arrivals
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "all late relay publications are recorded" 3
        deferred.Service.discovered_publications;
      Alcotest.(check int)
        "late relay revision is not applied" 0
        deferred.Service.received_revisions;
      Alcotest.(check int)
        "late relay feed fork is deferred for review" 3
        deferred.Service.deferred_publications;
      Alcotest.(check int)
        "late relay record leaves shared model unchanged" 0
        deferred.Service.transport_status.Service.shared_change_count;
      let destination_repository =
        Store.open_repository ~root:destination
        |> require_ok Store.error_to_string
      in
      let destination_loaded =
        Store.load destination_repository |> require_ok Store.error_to_string
      in
      let review_inbox =
        match destination_loaded.Store.collaboration with
        | Some collaboration -> (
            match
              Transport.find_remote (Store.transport collaboration) ~name:"team"
            with
            | Some state -> Transport.remote_review_inbox state
            | None ->
                Alcotest.fail
                  "deferred relay record did not create remote state")
        | None -> Alcotest.fail "deferred relay record lost collaboration"
      in
      Alcotest.(check (list string))
        "the root and both feed forks enter review inbox" publication_ids
        review_inbox;
      let retry =
        Service.receive_transport_batch ~root:destination ~remote:"team"
          ~cursor:(Some (Transport.publication_id right_publication))
          arrivals
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "retry revisits every deferred fork rather than selecting a head" 3
        retry.Service.discovered_publications;
      Alcotest.(check int)
        "retry still applies no late revision" 0
        retry.Service.received_revisions;
      Alcotest.(check int)
        "retry keeps every fork deferred" 3 retry.Service.deferred_publications;
      Alcotest.(check int)
        "retry preserves the shared model" 0
        retry.Service.transport_status.Service.shared_change_count;
      Alcotest.(check string)
        "receive-first retry leaves the working tree untouched"
        "let version = 1\n"
        (read_file destination "main.ml");
      let reviewed =
        Service.review_package ~root:destination ~package
        |> require_ok Service.error_to_string
      in
      Alcotest.(check (list string))
        "the isolated review names the late revision" [ "revision-late:true" ]
        (reviewed
        |> List.map (fun review ->
            Model.Revision_id.to_string review.Service.review_revision
            ^ ":"
            ^ string_of_bool review.Service.requires_adoption));
      ignore
        (Service.adopt_package_revision ~authority_epoch:None ~root:destination
           ~package ~revision:(revision "revision-late")
           ~signing_capability:reviewer_capability
        |> require_ok Service.error_to_string);
      let received =
        Service.receive_package ~root:destination ~package
        |> require_ok Service.error_to_string
      in
      Alcotest.(check int)
        "only the adopted record enters the local model" 1
        received.Service.shared_change_count;
      Alcotest.(check string)
        "review and receive do not materialize package bytes"
        "let version = 1\n"
        (read_file destination "main.ml"))

let () =
  Alcotest.run "V4 local service"
    [
      ( "saved work",
        [
          Alcotest.test_case "init captures and unchanged save is a no-op"
            `Quick init_captures_the_initial_tree_and_save_observes_no_change;
          Alcotest.test_case "username registration survives repository reload"
            `Quick username_registration_persists_across_a_repository_reload;
          Alcotest.test_case "changed save creates a checkpoint" `Quick
            changed_save_creates_a_new_checkpoint;
          Alcotest.test_case "status warns about uncaptured edits" `Quick
            status_warns_about_uncaptured_edits;
          Alcotest.test_case "compact keeps pins and drops extra saves" `Quick
            compact_drops_extra_saves_and_keeps_a_pin;
          Alcotest.test_case "capture window uses quiet and max delay" `Quick
            capture_window_uses_quiet_and_max_delay;
          Alcotest.test_case "new draft retains saved state" `Quick
            new_draft_closes_the_previous_draft_without_losing_saved_state;
          Alcotest.test_case "restore materializes a prior checkpoint" `Quick
            restore_materializes_a_prior_checkpoint_without_touching_the_project;
          Alcotest.test_case "restore rejects a nonempty destination" `Quick
            restore_rejects_a_nonempty_destination;
          Alcotest.test_case "capture excludes Git metadata" `Quick
            v4_capture_excludes_git_metadata;
          Alcotest.test_case
            "in-place restore retains unsaved bytes as a safety checkpoint"
            `Quick in_place_restore_retains_and_recovers_unsaved_bytes;
          Alcotest.test_case
            "restore proof remains after journal pruning until explicit forget"
            `Quick restore_proof_survives_journal_pruning_until_explicit_forget;
          Alcotest.test_case
            "legacy published restore is retained until explicit proof creation"
            `Quick legacy_published_journal_remains_a_root_until_explicit_retain;
          Alcotest.test_case
            "corrupt restore proof blocks compaction without a state write"
            `Quick corrupt_restore_proof_blocks_compaction_before_state_change;
          Alcotest.test_case
            "missing restore proof object blocks compaction without a state \
             write"
            `Quick
            missing_restore_proof_object_blocks_compaction_before_state_change;
          Alcotest.test_case "in-place restore preserves repository metadata"
            `Quick in_place_restore_preserves_repository_metadata;
          Alcotest.test_case "interrupted applying restore resumes exactly"
            `Quick interrupted_applying_restore_is_resumable;
        ] );
      ( "shared work",
        [
          Alcotest.test_case "share and amend retain linear revisions" `Quick
            share_records_a_shared_change_and_amend_appends_a_revision;
          Alcotest.test_case "share without a tree delta fails" `Quick
            share_without_a_tree_delta_fails;
          Alcotest.test_case "overlapping drafts become a decision" `Quick
            overlapping_shared_drafts_are_a_decision;
          Alcotest.test_case "isolated resolve does not rewrite the live tree"
            `Quick isolated_resolve_does_not_rewrite_the_live_tree;
          Alcotest.test_case
            "isolated inspection compares candidate snapshots without mutation"
            `Quick isolated_inspection_compares_exact_candidate_snapshots;
          Alcotest.test_case
            "exact proposal materializes without accepting or rewriting" `Quick
            exact_proposal_materializes_without_accepting_or_rewriting;
          Alcotest.test_case
            "proposal refusal and missing closure do not write destinations"
            `Quick
            proposal_refusal_and_missing_closure_leave_every_destination_untouched;
          Alcotest.test_case "proposal pair overview lists every competing pair"
            `Quick proposal_pair_overview_lists_every_competing_pair_once;
          Alcotest.test_case
            "exact proposal preserves binary bytes and symlink targets" `Quick
            exact_proposal_preserves_binary_bytes_and_symlink_targets;
          Alcotest.test_case "withdraw protects the active shared change" `Quick
            withdraw_protects_the_active_shared_change;
          Alcotest.test_case "resolve clears the open decision" `Quick
            resolve_clears_the_open_decision;
          Alcotest.test_case "deliver requires a decision-free shared draft"
            `Quick deliver_requires_a_decision_free_shared_draft;
          Alcotest.test_case
            "signed offline receive advances state without touching live files"
            `Quick signed_offline_receive_is_atomic_and_preserves_the_live_tree;
          Alcotest.test_case
            "administrator enrollment persists public membership and username"
            `Quick
            administrator_enrollment_persists_a_public_member_and_local_username;
          Alcotest.test_case
            "authority initialization exchanges epoch-bound work and recovery"
            `Quick
            authority_initialized_repositories_exchange_verified_epoch_bound_work;
          Alcotest.test_case
            "signed transport receives atomically and idempotently" `Quick
            signed_transport_receive_is_atomic_and_idempotent;
          Alcotest.test_case
            "signed resolution is persisted with its decision purpose" `Quick
            signed_resolution_is_persisted_with_its_decision_purpose;
          Alcotest.test_case
            "authority lifecycle revokes and recovery replaces control" `Quick
            authority_lifecycle_revokes_rotates_and_recovers_a_replacement_device;
          Alcotest.test_case
            "normal device rotation atomically replaces local authority" `Quick
            normal_device_rotation_replaces_the_local_signing_identity_atomically;
          Alcotest.test_case
            "forks require named branch actions and explicit reconciliation"
            `Quick
            authority_forks_require_named_branch_actions_and_explicit_reconciliation;
          Alcotest.test_case
            "late review retains feed forks across retry before adoption" `Quick
            late_package_review_retains_feed_forks_across_retry_before_adoption;
        ] );
    ]
