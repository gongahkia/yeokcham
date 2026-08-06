module Compaction = Paengi_compaction
module Retention = Paengi_validation_retention
module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store
module Validation = Paengi_validation

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let rec remove path =
  try
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
        Sys.readdir path
        |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path
    | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
    | Unix.S_SOCK ->
        Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_repository run =
  let root = Filename.temp_file "paengi-validation-retention-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () -> run root)

let write path contents =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel contents)

let digest value =
  Paengi_hash.Sha256.digest_string value |> Paengi_hash.Sha256.to_raw_string

let stream = { Validation.digest = digest ""; retained = ""; truncated = false }

let command =
  {
    Validation.executable = "/usr/bin/true";
    arguments = [];
    working_directory = [];
    timeout_ms = 1_000L;
    max_stdout_bytes = 32;
    max_stderr_bytes = 32;
    environment_policy = Validation.Empty;
    environment = [];
    retain_output = false;
    format_version = 1L;
    mandatory_features = 0L;
  }

let result status =
  {
    Validation.runner_status = status;
    runner_exit_code = (if status = Validation.Passed then Some 0 else Some 1);
    runner_signal = None;
    runner_execution_error = None;
    runner_duration_ms = 0L;
    runner_stdout = stream;
    runner_stderr = stream;
    runner_environment_fingerprint = None;
  }

let next_result = ref (result Validation.Passed)

module Runner : Validation.Process_runner = struct
  let run _ ~working_directory:_ = !next_result
end

let created = function
  | Scratch.Created checkpoint -> checkpoint
  | Scratch.Unchanged _ ->
      Alcotest.fail "fixture checkpoint unexpectedly unchanged"

let checkpoint store scratch root contents timestamp =
  write (Filename.concat root "tracked") contents;
  let snapshot, _ =
    Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
  in
  let checkpoint =
    Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
      ~observed_at:timestamp ~created_at:timestamp
    |> require_ok Scratch.error_to_string
    |> created
  in
  (snapshot, checkpoint)

let has_validation entry evidence =
  List.exists
    (function
      | Scratch.Validation_passed existing ->
          Paengi_id.Validation_id.equal existing evidence
      | Scratch.User_pinned | Scratch.Capsule_boundary _
      | Scratch.Release_boundary _ | Scratch.Periodic_retention
      | Scratch.Recent_window | Scratch.Conflict_reference _ ->
          false)
    entry.Scratch.effective_retention

let matching_passed_snapshot_persists_and_compacts () =
  with_repository (fun root ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let scratch = Scratch.open_repository store in
      write (Filename.concat root "tracked") "base\n";
      let base, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let initial =
        Scratch.create_initial scratch ~snapshot:base ~created_at:0L
        |> require_ok Scratch.error_to_string
      in
      ignore (checkpoint store scratch root "changed\n" 1L);
      let _, current = checkpoint store scratch root "base\n" 2L in
      next_result := result Validation.Passed;
      let evidence, evidence_object =
        Validation.run
          ~runner:(module Runner)
          ~store ~snapshot:base ~command ~command_index:0 ~observed_at:3L ()
        |> require_ok Validation.error_to_string
      in
      let scratch_head_before =
        Store.read_ref store ~name:"scratch-head"
        |> require_ok Store.error_to_string
      in
      let workspace_before =
        Store.read_ref store ~name:"workspaces"
        |> require_ok Store.error_to_string
      in
      let release_before =
        Store.read_ref store ~name:"releases"
        |> require_ok Store.error_to_string
      in
      let applied =
        Retention.apply Retention.Pin_all_exact_snapshot_checkpoints ~store
          ~scratch ~evidence_object ~changed_at:3L
        |> require_ok Retention.error_to_string
      in
      (match applied.Retention.decision with
      | Retention.Retain checkpoints ->
          Alcotest.(check int)
            "all exact snapshot checkpoints match" 2 (List.length checkpoints)
      | Retention.Evidence_not_passed | Retention.No_matching_checkpoint ->
          Alcotest.fail "passing matching evidence was not retained");
      Alcotest.(check int)
        "both matches were newly retained" 2 applied.Retention.newly_retained;
      Alcotest.(check int)
        "no match was already retained" 0 applied.Retention.already_retained;
      Alcotest.(check bool)
        "validation does not move scratch head" true
        (Option.equal Store.Mutable_ref.equal scratch_head_before
           (Store.read_ref store ~name:"scratch-head"
           |> require_ok Store.error_to_string));
      Alcotest.(check bool)
        "validation retention does not create workspace ref" true
        (Option.equal Store.Mutable_ref.equal workspace_before
           (Store.read_ref store ~name:"workspaces"
           |> require_ok Store.error_to_string));
      Alcotest.(check bool)
        "validation retention does not create release ref" true
        (Option.equal Store.Mutable_ref.equal release_before
           (Store.read_ref store ~name:"releases"
           |> require_ok Store.error_to_string));
      let reopened_store =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let reopened = Scratch.open_repository reopened_store in
      let retained =
        Scratch.timeline reopened ~limit:max_int ()
        |> require_ok Scratch.error_to_string
      in
      let evidence_id = Validation.evidence_id evidence in
      let expected =
        [ Scratch.Checkpoint.id initial; Scratch.Checkpoint.id current ]
      in
      List.iter
        (fun checkpoint ->
          let entry =
            List.find
              (fun entry ->
                Scratch.Checkpoint_id.equal entry.Scratch.logical_id checkpoint)
              retained
          in
          Alcotest.(check bool)
            "validation reason survives reopen" true
            (has_validation entry evidence_id))
        expected;
      let retention_before_retry =
        Store.read_ref reopened_store ~name:"retention-head"
        |> require_ok Store.error_to_string
      in
      let retried =
        Retention.apply Retention.Pin_all_exact_snapshot_checkpoints
          ~store:reopened_store ~scratch:reopened ~evidence_object
          ~changed_at:4L
        |> require_ok Retention.error_to_string
      in
      Alcotest.(check int)
        "retry does not append a duplicate reason" 0
        retried.Retention.newly_retained;
      Alcotest.(check int)
        "retry reports existing reasons" 2 retried.Retention.already_retained;
      Alcotest.(check bool)
        "retry does not move retention head" true
        (Option.equal Store.Mutable_ref.equal retention_before_retry
           (Store.read_ref reopened_store ~name:"retention-head"
           |> require_ok Store.error_to_string));
      let policy =
        Compaction.Policy.create ~recent_window_seconds:0L
          ~periodic_interval_seconds:0L ~storage_budget_bytes:None
        |> require_ok Compaction.Policy.error_to_string
      in
      let plan =
        Compaction.analyze ~store:reopened_store reopened ~policy ~now:100L
        |> require_ok Compaction.error_to_string
      in
      let selection checkpoint =
        List.find
          (fun selection ->
            Scratch.Checkpoint_id.equal
              (Compaction.Policy.checkpoint selection).Compaction.Policy.id
              checkpoint)
          (Compaction.selections plan)
      in
      Alcotest.(check bool)
        "validation boundary survives compaction planning" true
        (Compaction.Policy.retained (selection (Scratch.Checkpoint.id initial)));
      ignore
        (Compaction.activate ~cleanup:false ~store:reopened_store reopened
           ~policy ~now:100L
        |> require_ok Compaction.error_to_string);
      let resolved =
        Scratch.resolve_checkpoint reopened (Scratch.Checkpoint.id initial)
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check bool)
        "validation boundary survives compaction activation" true
        (Snapshot.Snapshot.equal_id base
           (Scratch.Checkpoint.snapshot (Scratch.resolved_checkpoint resolved))))

let failed_or_unmatched_evidence_does_not_write_retention () =
  with_repository (fun root ->
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let scratch = Scratch.open_repository store in
      write (Filename.concat root "tracked") "base\n";
      let base, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      ignore
        (Scratch.create_initial scratch ~snapshot:base ~created_at:0L
        |> require_ok Scratch.error_to_string);
      next_result := result Validation.Failed;
      let _, evidence_object =
        Validation.run
          ~runner:(module Runner)
          ~store ~snapshot:base ~command ~command_index:0 ~observed_at:1L ()
        |> require_ok Validation.error_to_string
      in
      let outcome =
        Retention.apply Retention.Pin_all_exact_snapshot_checkpoints ~store
          ~scratch ~evidence_object ~changed_at:1L
        |> require_ok Retention.error_to_string
      in
      (match outcome.Retention.decision with
      | Retention.Evidence_not_passed -> ()
      | Retention.No_matching_checkpoint | Retention.Retain _ ->
          Alcotest.fail "failed evidence changed retention policy outcome");
      Alcotest.(check int)
        "failed evidence adds no retention" 0 outcome.Retention.newly_retained;
      Alcotest.(check bool)
        "failed evidence leaves retention ref absent" true
        (Option.is_none
           (Store.read_ref store ~name:"retention-head"
           |> require_ok Store.error_to_string)))

let () =
  Alcotest.run "validation retention"
    [
      ( "policy",
        [
          Alcotest.test_case "passed matching checkpoints persist and compact"
            `Quick matching_passed_snapshot_persists_and_compacts;
          Alcotest.test_case "failed evidence leaves retention unchanged" `Quick
            failed_or_unmatched_evidence_does_not_write_retention;
        ] );
    ]
