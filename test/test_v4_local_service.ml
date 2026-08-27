module Model = Yeokcham_v4_model
module Journal = Yeokcham_v4_restore_journal
module Service = Yeokcham_v4_local_service

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

let write_file root name contents =
  Out_channel.with_open_bin (Filename.concat root name) (fun channel ->
      Out_channel.output_string channel contents)

let read_file root name =
  In_channel.with_open_bin (Filename.concat root name) In_channel.input_all

let id parser value = parser value |> Result.get_ok
let device value = id Model.Device_id.of_string value
let draft value = id Model.Draft_id.of_string value
let change value = id Model.Change_id.of_string value
let revision value = id Model.Revision_id.of_string value
let delivery value = id Model.Delivery_id.of_string value
let username value = id Model.Username.of_string value

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
          Alcotest.test_case "withdraw protects the active shared change" `Quick
            withdraw_protects_the_active_shared_change;
          Alcotest.test_case "resolve clears the open decision" `Quick
            resolve_clears_the_open_decision;
          Alcotest.test_case "deliver requires a decision-free shared draft"
            `Quick deliver_requires_a_decision_free_shared_draft;
        ] );
    ]
