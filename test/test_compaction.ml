module Compaction = Yeokcham_compaction
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

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
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> run path)

let write_file path bytes =
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel bytes)

let checkpoint_id value =
  let raw = Bytes.make 32 '\000' in
  Bytes.set raw 0 (Char.chr value);
  Store.Stored_object_id.of_raw_bytes (Bytes.unsafe_to_string raw)
  |> Option.get |> Scratch.Checkpoint_id.of_stored_object_id

let content_id value =
  let raw = Bytes.make 32 '\000' in
  Bytes.set raw 0 (Char.chr value);
  Store.Stored_object_id.of_raw_bytes (Bytes.unsafe_to_string raw)
  |> Option.get |> Snapshot.Content.of_stored_object_id

let checkpoint ?(storage_bytes = 0L) value created_at effective_retention =
  {
    Compaction.Policy.id = checkpoint_id value;
    created_at;
    effective_retention;
    storage_bytes;
  }

let policy ~recent ~periodic =
  Compaction.Policy.create ~recent_window_seconds:recent
    ~periodic_interval_seconds:periodic ~storage_budget_bytes:None
  |> require_ok Compaction.Policy.error_to_string

let policy_with_budget ~budget ~recent ~periodic =
  Compaction.Policy.create ~recent_window_seconds:recent
    ~periodic_interval_seconds:periodic ~storage_budget_bytes:(Some budget)
  |> require_ok Compaction.Policy.error_to_string

let selection_for identity selections =
  List.find
    (fun selection ->
      Scratch.Checkpoint_id.equal
        (Compaction.Policy.checkpoint selection).Compaction.Policy.id identity)
    selections

let policy_retain_recent_periodic_and_pinned () =
  let recent = checkpoint 1 999L [] in
  let pinned = checkpoint 2 800L [ Scratch.User_pinned ] in
  let newer_same_bucket = checkpoint 3 850L [] in
  let older_same_bucket = checkpoint 4 810L [] in
  let periodic = checkpoint 5 705L [] in
  let selections =
    Compaction.Policy.select
      (policy ~recent:10L ~periodic:100L)
      ~now:1_000L
      [ recent; pinned; newer_same_bucket; older_same_bucket; periodic ]
  in
  (match
     Compaction.Policy.decision
       (selection_for recent.Compaction.Policy.id selections)
   with
  | Compaction.Policy.Recent_window -> ()
  | Compaction.Policy.Protected_by _ | Compaction.Policy.Periodic_bucket _
  | Compaction.Policy.Required_for_replay | Compaction.Policy.Budget_excluded
  | Compaction.Policy.Expired ->
      Alcotest.fail "recent checkpoint expired");
  (match
     Compaction.Policy.decision
       (selection_for pinned.Compaction.Policy.id selections)
   with
  | Compaction.Policy.Protected_by reason ->
      Alcotest.(check string)
        "pin reason" "user pinned"
        (Scratch.retention_reason_to_string reason)
  | Compaction.Policy.Recent_window | Compaction.Policy.Periodic_bucket _
  | Compaction.Policy.Required_for_replay | Compaction.Policy.Budget_excluded
  | Compaction.Policy.Expired ->
      Alcotest.fail "pin did not override expiry");
  (match
     Compaction.Policy.decision
       (selection_for newer_same_bucket.Compaction.Policy.id selections)
   with
  | Compaction.Policy.Periodic_bucket 8L -> ()
  | Compaction.Policy.Protected_by _ | Compaction.Policy.Recent_window
  | Compaction.Policy.Periodic_bucket _ | Compaction.Policy.Required_for_replay
  | Compaction.Policy.Budget_excluded | Compaction.Policy.Expired ->
      Alcotest.fail "newest checkpoint was not selected for periodic bucket");
  (match
     Compaction.Policy.decision
       (selection_for older_same_bucket.Compaction.Policy.id selections)
   with
  | Compaction.Policy.Expired -> ()
  | Compaction.Policy.Protected_by _ | Compaction.Policy.Recent_window
  | Compaction.Policy.Periodic_bucket _ | Compaction.Policy.Required_for_replay
  | Compaction.Policy.Budget_excluded ->
      Alcotest.fail "older checkpoint survived periodic thinning");
  match
    Compaction.Policy.decision
      (selection_for periodic.Compaction.Policy.id selections)
  with
  | Compaction.Policy.Periodic_bucket 7L -> ()
  | Compaction.Policy.Protected_by _ | Compaction.Policy.Recent_window
  | Compaction.Policy.Periodic_bucket _ | Compaction.Policy.Required_for_replay
  | Compaction.Policy.Budget_excluded | Compaction.Policy.Expired ->
      Alcotest.fail "periodic checkpoint expired"

let budget_selection_keeps_required_and_trims_deterministically () =
  let pinned = checkpoint ~storage_bytes:70L 1 1L [ Scratch.User_pinned ] in
  let head = checkpoint ~storage_bytes:40L 2 95L [] in
  let newer = checkpoint ~storage_bytes:30L 3 90L [] in
  let periodic = checkpoint ~storage_bytes:10L 4 10L [] in
  let policy = policy_with_budget ~budget:120L ~recent:20L ~periodic:10L in
  let select checkpoints =
    Compaction.Policy.select
      ~required:[ head.Compaction.Policy.id ]
      policy ~now:100L checkpoints
  in
  let selections = select [ pinned; head; newer; periodic ] in
  let reordered = select [ periodic; newer; head; pinned ] in
  let decision identity values =
    Compaction.Policy.decision (selection_for identity values)
  in
  (match decision pinned.Compaction.Policy.id selections with
  | Compaction.Policy.Protected_by reason
    when String.equal (Scratch.retention_reason_to_string reason) "user pinned"
    ->
      ()
  | Compaction.Policy.Protected_by _ | Compaction.Policy.Recent_window
  | Compaction.Policy.Periodic_bucket _ | Compaction.Policy.Required_for_replay
  | Compaction.Policy.Budget_excluded | Compaction.Policy.Expired ->
      Alcotest.fail "pinned checkpoint was budget-evicted");
  (match decision head.Compaction.Policy.id selections with
  | Compaction.Policy.Recent_window -> ()
  | Compaction.Policy.Protected_by _ | Compaction.Policy.Periodic_bucket _
  | Compaction.Policy.Required_for_replay | Compaction.Policy.Budget_excluded
  | Compaction.Policy.Expired ->
      Alcotest.fail "required head was not retained");
  (match decision newer.Compaction.Policy.id selections with
  | Compaction.Policy.Budget_excluded -> ()
  | Compaction.Policy.Protected_by _ | Compaction.Policy.Recent_window
  | Compaction.Policy.Periodic_bucket _ | Compaction.Policy.Required_for_replay
  | Compaction.Policy.Expired ->
      Alcotest.fail "newer optional checkpoint survived the budget");
  (match decision periodic.Compaction.Policy.id selections with
  | Compaction.Policy.Periodic_bucket _ -> ()
  | Compaction.Policy.Protected_by _ | Compaction.Policy.Recent_window
  | Compaction.Policy.Required_for_replay | Compaction.Policy.Budget_excluded
  | Compaction.Policy.Expired ->
      Alcotest.fail "periodic checkpoint did not use remaining budget");
  List.iter
    (fun checkpoint ->
      Alcotest.(check string)
        "permutation keeps budget decision"
        (match decision checkpoint selections with
        | Compaction.Policy.Protected_by reason ->
            "protected=" ^ Scratch.retention_reason_to_string reason
        | Compaction.Policy.Recent_window -> "recent"
        | Compaction.Policy.Periodic_bucket bucket -> Int64.to_string bucket
        | Compaction.Policy.Required_for_replay -> "required"
        | Compaction.Policy.Budget_excluded -> "budget-excluded"
        | Compaction.Policy.Expired -> "expired")
        (match decision checkpoint reordered with
        | Compaction.Policy.Protected_by reason ->
            "protected=" ^ Scratch.retention_reason_to_string reason
        | Compaction.Policy.Recent_window -> "recent"
        | Compaction.Policy.Periodic_bucket bucket -> Int64.to_string bucket
        | Compaction.Policy.Required_for_replay -> "required"
        | Compaction.Policy.Budget_excluded -> "budget-excluded"
        | Compaction.Policy.Expired -> "expired"))
    [
      pinned.Compaction.Policy.id;
      head.Compaction.Policy.id;
      newer.Compaction.Policy.id;
      periodic.Compaction.Policy.id;
    ]

let exact_inverse_reducer_preserves_unmatched_operations () =
  let first = content_id 11 in
  let second = content_id 12 in
  let third = content_id 13 in
  let entry = Scratch.File { mode = Snapshot.Regular; content = first } in
  let create_delete =
    [
      Scratch.Create { path = [ "temporary" ]; entry };
      Scratch.Delete { path = [ "temporary" ]; prior = entry };
    ]
  in
  let modify_inverse =
    [
      Scratch.Modify_content
        { path = [ "file" ]; expected = first; replacement = second };
      Scratch.Modify_content
        { path = [ "file" ]; expected = second; replacement = first };
    ]
  in
  let unmatched =
    Scratch.Modify_content
      { path = [ "other" ]; expected = first; replacement = third }
  in
  let reduced, eliminated =
    Compaction.eliminate_exact_inverse_pairs
      (create_delete @ modify_inverse @ [ unmatched ])
  in
  Alcotest.(check int) "exact adjacent pairs are removed" 2 eliminated;
  Alcotest.(check int) "unmatched operation remains" 1 (List.length reduced);
  match reduced with
  | [ Scratch.Modify_content { path; expected; replacement } ] ->
      Alcotest.(check (list string)) "unmatched path" [ "other" ] path;
      Alcotest.(check bool)
        "unmatched precondition is unchanged" true
        (Snapshot.Content.equal_id expected first);
      Alcotest.(check bool)
        "unmatched replacement is unchanged" true
        (Snapshot.Content.equal_id replacement third)
  | [
      ( Scratch.Create _ | Scratch.Delete _ | Scratch.Change_mode _
      | Scratch.Move _ );
    ]
  | [] | _ :: _ :: _ ->
      Alcotest.fail "inverse reducer changed an unmatched operation"

let budget_plan_preserves_required_history_with with_history assert_retained ()
    =
  with_history (fun root store scratch initial middle head ->
      let baseline =
        Compaction.analyze ~store scratch
          ~policy:(policy ~recent:30L ~periodic:0L)
          ~now:25L
        |> require_ok Compaction.error_to_string
      in
      let selected_bytes identity =
        Compaction.selections baseline
        |> selection_for identity |> Compaction.Policy.checkpoint
        |> fun checkpoint -> checkpoint.Compaction.Policy.storage_bytes
      in
      let budget =
        Int64.add
          (selected_bytes (Scratch.Checkpoint.id initial))
          (selected_bytes (Scratch.Checkpoint.id head))
      in
      let policy = policy_with_budget ~budget ~recent:30L ~periodic:0L in
      let plan =
        Compaction.analyze ~store scratch ~policy ~now:25L
        |> require_ok Compaction.error_to_string
      in
      (match
         Compaction.Policy.decision
           (selection_for
              (Scratch.Checkpoint.id initial)
              (Compaction.selections plan))
       with
      | Compaction.Policy.Protected_by reason
        when String.equal
               (Scratch.retention_reason_to_string reason)
               "user pinned" ->
          ()
      | Compaction.Policy.Protected_by _ | Compaction.Policy.Recent_window
      | Compaction.Policy.Periodic_bucket _
      | Compaction.Policy.Required_for_replay
      | Compaction.Policy.Budget_excluded | Compaction.Policy.Expired ->
          Alcotest.fail "pin was not retained by budget plan");
      (match
         Compaction.Policy.decision
           (selection_for
              (Scratch.Checkpoint.id head)
              (Compaction.selections plan))
       with
      | Compaction.Policy.Recent_window -> ()
      | Compaction.Policy.Protected_by _ | Compaction.Policy.Periodic_bucket _
      | Compaction.Policy.Required_for_replay
      | Compaction.Policy.Budget_excluded | Compaction.Policy.Expired ->
          Alcotest.fail "scratch head was not retained by budget plan");
      (match
         Compaction.Policy.decision
           (selection_for
              (Scratch.Checkpoint.id middle)
              (Compaction.selections plan))
       with
      | Compaction.Policy.Budget_excluded -> ()
      | Compaction.Policy.Protected_by _ | Compaction.Policy.Recent_window
      | Compaction.Policy.Periodic_bucket _
      | Compaction.Policy.Required_for_replay | Compaction.Policy.Expired ->
          Alcotest.fail "optional checkpoint was not budget-evicted");
      Alcotest.(check int64)
        "retained checkpoint bytes meet the budget" budget
        (Compaction.budget_retained_checkpoint_bytes plan);
      Alcotest.(check int64)
        "mandatory checkpoint bytes meet the budget" budget
        (Compaction.budget_protected_checkpoint_bytes plan);
      Alcotest.(check (option int64))
        "budget has no mandatory overrun" None
        (Compaction.budget_exceeded_by plan);
      Alcotest.(check bool)
        "dry-run explains budget exclusion" true
        (List.mem "budget-excluded-checkpoints=1"
           (Compaction.render_explain plan));
      ignore
        (Compaction.activate ~store scratch ~policy ~now:25L
        |> require_ok Compaction.error_to_string);
      (match
         Scratch.resolve_checkpoint scratch (Scratch.Checkpoint.id middle)
       with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "budget-evicted checkpoint still resolves");
      assert_retained root scratch initial head)

let invalid_policy_values_are_rejected () =
  (match
     Compaction.Policy.create ~recent_window_seconds:(-1L)
       ~periodic_interval_seconds:0L ~storage_budget_bytes:None
   with
  | Error error -> (
      match error with
      | Compaction.Policy.Negative_recent_window -1L -> ()
      | Compaction.Policy.Negative_recent_window _
      | Compaction.Policy.Negative_periodic_interval _
      | Compaction.Policy.Negative_storage_budget _ ->
          Alcotest.fail "negative recent window was misclassified")
  | Ok _ -> Alcotest.fail "negative recent window was accepted");
  match
    Compaction.Policy.create ~recent_window_seconds:0L
      ~periodic_interval_seconds:0L ~storage_budget_bytes:(Some (-1L))
  with
  | Error error -> (
      match error with
      | Compaction.Policy.Negative_storage_budget -1L -> ()
      | Compaction.Policy.Negative_recent_window _
      | Compaction.Policy.Negative_periodic_interval _
      | Compaction.Policy.Negative_storage_budget _ ->
          Alcotest.fail "negative storage budget was misclassified")
  | Ok _ -> Alcotest.fail "negative storage budget was accepted"

let with_history run =
  with_directory "yeokcham-compaction-" (fun root ->
      write_file (Filename.concat root "file") "zero";
      let store = Store.init ~root |> require_ok Store.error_to_string in
      let scratch = Scratch.open_repository store in
      let snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let initial =
        Scratch.create_initial scratch ~snapshot ~created_at:0L
        |> require_ok Scratch.error_to_string
      in
      write_file (Filename.concat root "file") "one";
      let snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let middle =
        Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
          ~observed_at:10L ~created_at:10L
        |> require_ok Scratch.error_to_string
      in
      let middle =
        match middle with
        | Scratch.Created checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "middle checkpoint was unchanged"
      in
      write_file (Filename.concat root "file") "two";
      let snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let head =
        Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
          ~observed_at:20L ~created_at:20L
        |> require_ok Scratch.error_to_string
      in
      let head =
        match head with
        | Scratch.Created checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "head checkpoint was unchanged"
      in
      Scratch.pin scratch (Scratch.Checkpoint.id initial) ~changed_at:30L
      |> require_ok Scratch.error_to_string;
      run root store scratch initial middle head)

let with_cleanup_fixture run =
  with_history (fun root store scratch initial middle head ->
      Scratch.unpin scratch (Scratch.Checkpoint.id initial) ~changed_at:31L
      |> require_ok Scratch.error_to_string;
      Scratch.pin scratch (Scratch.Checkpoint.id initial) ~changed_at:32L
      |> require_ok Scratch.error_to_string;
      run root store scratch initial middle head)

let cleanup_reports_exact_candidate_progress () =
  with_history (fun _root store scratch _initial _middle _head ->
      let observed = ref [] in
      let execution =
        Compaction.activate
          ~on_progress:(fun ~completed ~total ->
            observed := (completed, total) :: !observed)
          ~store scratch
          ~policy:(policy ~recent:6L ~periodic:0L)
          ~now:25L
        |> require_ok Compaction.error_to_string
      in
      let cleanup = Compaction.execution_cleanup execution in
      let total =
        cleanup.Compaction.quarantined_objects
        + cleanup.Compaction.already_quarantined_objects
      in
      Alcotest.(check (list (pair int int)))
        "cleanup candidate sequence"
        (List.init (total + 1) (fun completed -> (completed, total)))
        (List.rev !observed))

let metrics_equal left right =
  List.length left = List.length right
  && List.for_all2
       (fun left right ->
         Store.Stored_object_id.equal left.Compaction.metric_object_id
           right.Compaction.metric_object_id
         && left.Compaction.metric_expected_type
            = right.Compaction.metric_expected_type
         && Int64.equal left.Compaction.stored_bytes
              right.Compaction.stored_bytes)
       left right

let metric_bytes metrics =
  List.fold_left
    (fun total metric -> Int64.add total metric.Compaction.stored_bytes)
    0L metrics

let metric_ids_are_unique metrics =
  let ids =
    List.map (fun metric -> metric.Compaction.metric_object_id) metrics
  in
  List.length ids
  = List.length (List.sort_uniq Store.Stored_object_id.compare ids)

let generation_trash root generation =
  Filename.concat
    (Filename.concat root ".yeokcham/trash")
    (Store.Stored_object_id.to_hex
       (Scratch.Generation_id.stored_object_id generation))

let candidate_paths store trash metric =
  ( Store.object_path store metric.Compaction.metric_object_id,
    Filename.concat trash
      (Store.Stored_object_id.to_hex metric.Compaction.metric_object_id) )

let active_generation_id scratch =
  Scratch.active_generation scratch
  |> require_ok Scratch.error_to_string
  |> Option.map Scratch.Generation.id
  |> Option.get

let assert_retained_resolution_and_restore root scratch initial head =
  List.iter
    (fun checkpoint ->
      let resolved =
        Scratch.resolve_checkpoint scratch (Scratch.Checkpoint.id checkpoint)
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check bool)
        "retained logical snapshot is unchanged" true
        (Snapshot.Snapshot.equal_id
           (Scratch.Checkpoint.snapshot checkpoint)
           (Scratch.Checkpoint.snapshot (Scratch.resolved_checkpoint resolved))))
    [ initial; head ];
  Scratch.Restore.restore scratch ~root
    ~target:(Scratch.Checkpoint.id initial)
    ~observed_at:50L ~created_at:50L
  |> require_ok Scratch.error_to_string
  |> ignore;
  Alcotest.(check string)
    "retained initial checkpoint restores" "zero"
    (In_channel.with_open_bin
       (Filename.concat root "file")
       In_channel.input_all);
  Scratch.Restore.restore scratch ~root
    ~target:(Scratch.Checkpoint.id head)
    ~observed_at:51L ~created_at:51L
  |> require_ok Scratch.error_to_string
  |> ignore;
  Alcotest.(check string)
    "retained head checkpoint restores" "two"
    (In_channel.with_open_bin
       (Filename.concat root "file")
       In_channel.input_all)

let budget_plan_preserves_required_history () =
  budget_plan_preserves_required_history_with with_history
    assert_retained_resolution_and_restore ()

let compaction_eliminates_exact_inverse_gap () =
  with_history (fun root store scratch initial middle _head ->
      write_file (Filename.concat root "file") "one";
      let snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let head =
        Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
          ~observed_at:30L ~created_at:30L
        |> require_ok Scratch.error_to_string
      in
      let head =
        match head with
        | Scratch.Created checkpoint -> checkpoint
        | Scratch.Unchanged _ -> Alcotest.fail "inverse head was unchanged"
      in
      let policy = policy ~recent:0L ~periodic:0L in
      let plan =
        Compaction.analyze ~store scratch ~policy ~now:40L
        |> require_ok Compaction.error_to_string
      in
      Alcotest.(check int)
        "one adjacent inverse pair is proven" 1
        (Compaction.inverse_pairs_eliminated plan);
      Alcotest.(check bool)
        "dry-run explains inverse reduction" true
        (List.mem "inverse-pairs-eliminated=1" (Compaction.render_explain plan));
      let execution =
        Compaction.activate ~store scratch ~policy ~now:40L
        |> require_ok Compaction.error_to_string
      in
      let generation =
        Scratch.active_generation scratch
        |> require_ok Scratch.error_to_string
        |> Option.get
      in
      let physical_head =
        Scratch.Generation.entries generation
        |> List.rev |> List.hd |> Scratch.Generation.physical
      in
      let checkpoint =
        Scratch.Checkpoint.load store physical_head
        |> require_ok Scratch.error_to_string
      in
      let event =
        Scratch.Checkpoint.event checkpoint
        |> Option.get |> Scratch.Event.load store
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check int)
        "generated event keeps only the unreversed edit" 1
        (List.length (Scratch.Event.operations event));
      (match
         Scratch.resolve_checkpoint scratch (Scratch.Checkpoint.id middle)
       with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "unretained intermediate checkpoint resolves");
      Scratch.Restore.restore scratch ~root
        ~target:(Scratch.Checkpoint.id initial)
        ~observed_at:41L ~created_at:41L
      |> require_ok Scratch.error_to_string
      |> ignore;
      Alcotest.(check string)
        "initial snapshot remains exact" "zero"
        (In_channel.with_open_bin
           (Filename.concat root "file")
           In_channel.input_all);
      Scratch.Restore.restore scratch ~root
        ~target:(Scratch.Checkpoint.id head)
        ~observed_at:42L ~created_at:42L
      |> require_ok Scratch.error_to_string
      |> ignore;
      Alcotest.(check string)
        "reduced head snapshot remains exact" "one"
        (In_channel.with_open_bin
           (Filename.concat root "file")
           In_channel.input_all);
      Alcotest.(check int)
        "activation reports the dry-run inverse count" 1
        (Compaction.execution_plan execution
        |> Compaction.inverse_pairs_eliminated))

let assert_quarantined store root generation planned =
  let trash = generation_trash root generation in
  List.iter
    (fun metric ->
      let source, destination = candidate_paths store trash metric in
      Alcotest.(check bool)
        "candidate is absent from main object store" false
        (Sys.file_exists source);
      Alcotest.(check bool)
        "candidate is present once in active quarantine" true
        (Sys.file_exists destination))
    planned

let assert_pruned store root generation planned =
  let trash = generation_trash root generation in
  List.iter
    (fun metric ->
      let source, destination = candidate_paths store trash metric in
      Alcotest.(check bool)
        "candidate is absent from main object store" false
        (Sys.file_exists source);
      Alcotest.(check bool)
        "candidate is absent from active quarantine" false
        (Sys.file_exists destination))
    planned

let planner_is_read_only_and_explains_exact_cleanup () =
  with_history (fun root store scratch initial middle head ->
      let head_path = Filename.concat root ".yeokcham/refs/scratch-head" in
      let before = In_channel.with_open_bin head_path In_channel.input_all in
      let plan =
        Compaction.analyze ~store scratch
          ~policy:(policy ~recent:6L ~periodic:0L)
          ~now:25L
        |> require_ok Compaction.error_to_string
      in
      let after = In_channel.with_open_bin head_path In_channel.input_all in
      Alcotest.(check string)
        "dry-run leaves scratch-head unchanged" before after;
      Alcotest.(check bool)
        "all reachable objects counted" true
        (Compaction.reachable_object_count plan > 0);
      Alcotest.(check int64)
        "reachable estimate uses stored object lengths"
        (Compaction.estimated_before_bytes plan)
        (Compaction.estimated_after_bytes plan);
      Alcotest.(check int)
        "obsolete source checkpoints are removable" 2
        (List.length (Compaction.removable_checkpoints plan));
      Alcotest.(check int)
        "candidate set contains checkpoints and events" 4
        (Compaction.planned_cleanup_count plan);
      Alcotest.(check bool)
        "planned stored bytes are nonzero" true
        (Int64.compare (Compaction.planned_cleanup_bytes plan) 0L > 0);
      Alcotest.(check int)
        "generation rewrite removes ancestry blocks" 0
        (List.length (Compaction.blocked_removals plan));
      let selected = Compaction.selections plan in
      (match
         Compaction.Policy.decision
           (selection_for (Scratch.Checkpoint.id initial) selected)
       with
      | Compaction.Policy.Protected_by reason ->
          Alcotest.(check string)
            "pinned checkpoint reason" "user pinned"
            (Scratch.retention_reason_to_string reason)
      | Compaction.Policy.Recent_window | Compaction.Policy.Periodic_bucket _
      | Compaction.Policy.Required_for_replay
      | Compaction.Policy.Budget_excluded | Compaction.Policy.Expired ->
          Alcotest.fail "pinned checkpoint was not protected");
      (match
         Compaction.Policy.decision
           (selection_for (Scratch.Checkpoint.id middle) selected)
       with
      | Compaction.Policy.Expired -> ()
      | Compaction.Policy.Protected_by _ | Compaction.Policy.Recent_window
      | Compaction.Policy.Periodic_bucket _
      | Compaction.Policy.Required_for_replay
      | Compaction.Policy.Budget_excluded ->
          Alcotest.fail "expired checkpoint was retained");
      (match
         Compaction.Policy.decision
           (selection_for (Scratch.Checkpoint.id head) selected)
       with
      | Compaction.Policy.Recent_window -> ()
      | Compaction.Policy.Protected_by _ | Compaction.Policy.Periodic_bucket _
      | Compaction.Policy.Required_for_replay
      | Compaction.Policy.Budget_excluded | Compaction.Policy.Expired ->
          Alcotest.fail "head was not retained");
      let explanation = Compaction.render_explain plan in
      Alcotest.(check bool)
        "explanation reports planned candidate count" true
        (List.mem "planned-cleanup-objects=4" explanation);
      Alcotest.(check bool)
        "explanation lists stored candidate bytes" true
        (List.exists
           (String.starts_with ~prefix:"planned-cleanup-object ")
           explanation))

let planner_rejects_missing_reachable_record () =
  with_history (fun _root store scratch _initial _middle head ->
      let event =
        match Scratch.Checkpoint.event head with
        | Some event -> event
        | None -> Alcotest.fail "non-initial checkpoint lacks event"
      in
      Unix.unlink
        (Store.object_path store (Scratch.Event_id.stored_object_id event));
      match
        Compaction.analyze ~store scratch
          ~policy:(policy ~recent:0L ~periodic:0L)
          ~now:100L
      with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "planner accepted missing reachable event")

let planner_matches_actual_quarantine_and_prune () =
  with_cleanup_fixture (fun root store scratch initial _middle head ->
      let policy = policy ~recent:6L ~periodic:0L in
      let plan =
        Compaction.analyze ~store scratch ~policy ~now:25L
        |> require_ok Compaction.error_to_string
      in
      let planned = Compaction.planned_cleanup plan in
      Alcotest.(check int)
        "fixture has six cleanup candidates" 6
        (Compaction.planned_cleanup_count plan);
      Alcotest.(check int64)
        "planned bytes equal planned metric sum" (metric_bytes planned)
        (Compaction.planned_cleanup_bytes plan);
      Alcotest.(check bool)
        "planned IDs are unique" true
        (metric_ids_are_unique planned);
      Alcotest.(check int)
        "planned candidates cover three scratch types" 3
        (List.length
           (List.sort_uniq compare
              (List.map
                 (fun metric -> metric.Compaction.metric_expected_type)
                 planned)));
      let checkpoint_objects checkpoint =
        let snapshot =
          Snapshot.Snapshot.load store (Scratch.Checkpoint.snapshot checkpoint)
          |> require_ok Snapshot.error_to_string
        in
        ignore
          (Snapshot.Tree.load store (Snapshot.Snapshot.root snapshot)
          |> require_ok Snapshot.error_to_string);
        [
          Snapshot.Snapshot.stored_object_id
            (Scratch.Checkpoint.snapshot checkpoint);
          Snapshot.Tree.stored_object_id (Snapshot.Snapshot.root snapshot);
        ]
      in
      let keep_objects =
        checkpoint_objects initial @ checkpoint_objects head
        |> List.sort_uniq Store.Stored_object_id.compare
      in
      let execution =
        Compaction.activate ~cleanup:false ~store scratch ~policy ~now:25L
        |> require_ok Compaction.error_to_string
      in
      Alcotest.(check bool)
        "activation plan matches dry run" true
        (metrics_equal planned
           (Compaction.planned_cleanup (Compaction.execution_plan execution)));
      let generation = Compaction.execution_generation execution in
      let cleanup =
        Compaction.resume_cleanup ~store scratch
        |> require_ok Compaction.error_to_string
      in
      Alcotest.(check bool)
        "actual quarantine matches dry run exactly" true
        (metrics_equal planned cleanup.Compaction.quarantined_candidates);
      Alcotest.(check int)
        "actual quarantine count matches dry run"
        (Compaction.planned_cleanup_count plan)
        cleanup.Compaction.quarantined_objects;
      Alcotest.(check int64)
        "actual quarantine bytes match dry run"
        (Compaction.planned_cleanup_bytes plan)
        cleanup.Compaction.quarantined_bytes;
      let trash = generation_trash root generation in
      List.iter
        (fun metric ->
          let source, destination = candidate_paths store trash metric in
          Alcotest.(check bool)
            "candidate leaves main object store" false (Sys.file_exists source);
          Alcotest.(check bool)
            "candidate enters generation quarantine" true
            (Sys.file_exists destination))
        planned;
      List.iter
        (fun identity ->
          Alcotest.(check bool)
            "cross-domain object remains in main store" true
            (Sys.file_exists (Store.object_path store identity)))
        keep_objects;
      let pruned =
        Compaction.prune ~store scratch |> require_ok Compaction.error_to_string
      in
      Alcotest.(check bool)
        "actual prune matches dry-run metrics" true
        (metrics_equal planned pruned.Compaction.pruned_candidates);
      Alcotest.(check int)
        "actual prune count matches dry run"
        (Compaction.planned_cleanup_count plan)
        pruned.Compaction.pruned_objects;
      Alcotest.(check int64)
        "actual prune bytes match dry run"
        (Compaction.planned_cleanup_bytes plan)
        pruned.Compaction.pruned_bytes;
      List.iter
        (fun metric ->
          let source, destination = candidate_paths store trash metric in
          Alcotest.(check bool)
            "pruned candidate is absent from main store" false
            (Sys.file_exists source);
          Alcotest.(check bool)
            "pruned candidate is absent from quarantine" false
            (Sys.file_exists destination))
        planned;
      List.iter
        (fun identity ->
          Alcotest.(check bool)
            "unrelated object remains after prune" true
            (Sys.file_exists (Store.object_path store identity)))
        keep_objects;
      List.iter
        (fun checkpoint ->
          Scratch.resolve_checkpoint scratch (Scratch.Checkpoint.id checkpoint)
          |> require_ok Scratch.error_to_string
          |> ignore)
        [ initial; head ];
      Scratch.Restore.restore scratch ~root
        ~target:(Scratch.Checkpoint.id initial)
        ~observed_at:40L ~created_at:40L
      |> require_ok Scratch.error_to_string
      |> ignore;
      Alcotest.(check string)
        "retained initial checkpoint restores" "zero"
        (In_channel.with_open_bin
           (Filename.concat root "file")
           In_channel.input_all);
      Scratch.Restore.restore scratch ~root
        ~target:(Scratch.Checkpoint.id head)
        ~observed_at:41L ~created_at:41L
      |> require_ok Scratch.error_to_string
      |> ignore;
      Alcotest.(check string)
        "retained head checkpoint restores" "two"
        (In_channel.with_open_bin
           (Filename.concat root "file")
           In_channel.input_all))

let quarantine_interruptions_resume_at_every_candidate_boundary () =
  let candidate_count = 6 in
  let run label fault =
    with_cleanup_fixture (fun root store scratch initial _middle head ->
        let policy = policy ~recent:6L ~periodic:0L in
        let plan =
          Compaction.analyze ~store scratch ~policy ~now:25L
          |> require_ok Compaction.error_to_string
        in
        let planned = Compaction.planned_cleanup plan in
        Alcotest.(check int)
          (label ^ " candidate count")
          candidate_count (List.length planned);
        let execution =
          Compaction.activate ~cleanup:false ~store scratch ~policy ~now:25L
          |> require_ok Compaction.error_to_string
        in
        let generation = Compaction.execution_generation execution in
        let source, _ =
          candidate_paths store
            (generation_trash root generation)
            (List.hd planned)
        in
        Alcotest.(check bool)
          (label ^ " starts in object store")
          true (Sys.file_exists source);
        (match Compaction.resume_cleanup ~fault ~store scratch with
        | Error _ -> ()
        | Ok _ -> Alcotest.fail (label ^ " did not interrupt cleanup"));
        let reopened_store =
          Store.open_repository ~root |> require_ok Store.error_to_string
        in
        let reopened = Scratch.open_repository reopened_store in
        let resumed =
          Compaction.resume_cleanup ~store:reopened_store reopened
          |> require_ok Compaction.error_to_string
        in
        assert_quarantined reopened_store root generation planned;
        Alcotest.(check bool)
          (label ^ " active generation remains unchanged")
          true
          (Scratch.Generation_id.equal generation
             (active_generation_id reopened));
        Alcotest.(check bool)
          (label ^ " no unrelated snapshot moved")
          true
          (Sys.file_exists
             (Store.object_path reopened_store
                (Snapshot.Snapshot.stored_object_id
                   (Scratch.Checkpoint.snapshot head))));
        Alcotest.(check int)
          (label ^ " resumed report only moves candidates")
          (candidate_count
          - List.length resumed.Compaction.already_quarantined_candidates)
          resumed.Compaction.quarantined_objects;
        let repeated =
          Compaction.resume_cleanup ~store:reopened_store reopened
          |> require_ok Compaction.error_to_string
        in
        Alcotest.(check int)
          (label ^ " repeat resume is idempotent")
          candidate_count repeated.Compaction.already_quarantined_objects;
        assert_retained_resolution_and_restore root reopened initial head)
  in
  List.iter
    (fun index ->
      run
        (Printf.sprintf "before-%d" index)
        (Compaction.Fault.before_candidate index);
      run
        (Printf.sprintf "after-%d" index)
        (Compaction.Fault.after_candidate index))
    (List.init candidate_count Fun.id)

let prune_interruptions_resume_at_every_candidate_boundary () =
  let candidate_count = 6 in
  let run label fault =
    with_cleanup_fixture (fun root store scratch initial _middle head ->
        let policy = policy ~recent:6L ~periodic:0L in
        let plan =
          Compaction.analyze ~store scratch ~policy ~now:25L
          |> require_ok Compaction.error_to_string
        in
        let planned = Compaction.planned_cleanup plan in
        let execution =
          Compaction.activate ~cleanup:false ~store scratch ~policy ~now:25L
          |> require_ok Compaction.error_to_string
        in
        let generation = Compaction.execution_generation execution in
        ignore
          (Compaction.resume_cleanup ~store scratch
          |> require_ok Compaction.error_to_string);
        (match Compaction.prune ~fault ~store scratch with
        | Error _ -> ()
        | Ok _ -> Alcotest.fail (label ^ " did not interrupt prune"));
        let reopened_store =
          Store.open_repository ~root |> require_ok Store.error_to_string
        in
        let reopened = Scratch.open_repository reopened_store in
        let resumed =
          Compaction.prune ~store:reopened_store reopened
          |> require_ok Compaction.error_to_string
        in
        assert_pruned reopened_store root generation planned;
        Alcotest.(check bool)
          (label ^ " active generation remains unchanged")
          true
          (Scratch.Generation_id.equal generation
             (active_generation_id reopened));
        Alcotest.(check bool)
          (label ^ " no unrelated snapshot deleted")
          true
          (Sys.file_exists
             (Store.object_path reopened_store
                (Snapshot.Snapshot.stored_object_id
                   (Scratch.Checkpoint.snapshot head))));
        Alcotest.(check int)
          (label ^ " resumed prune only deletes candidates")
          (candidate_count
          - List.length resumed.Compaction.already_pruned_candidates)
          resumed.Compaction.pruned_objects;
        let repeated =
          Compaction.prune ~store:reopened_store reopened
          |> require_ok Compaction.error_to_string
        in
        Alcotest.(check int)
          (label ^ " repeat prune is idempotent")
          candidate_count repeated.Compaction.already_pruned_objects;
        assert_retained_resolution_and_restore root reopened initial head)
  in
  List.iter
    (fun index ->
      run
        (Printf.sprintf "before-%d" index)
        (Compaction.Fault.before_candidate index);
      run
        (Printf.sprintf "after-%d" index)
        (Compaction.Fault.after_candidate index))
    (List.init candidate_count Fun.id)

let cleanup_rejects_invalid_resume_states () =
  let policy = policy ~recent:6L ~periodic:0L in
  let expect_error setup =
    with_cleanup_fixture (fun root store scratch _initial _middle _head ->
        let plan =
          Compaction.analyze ~store scratch ~policy ~now:25L
          |> require_ok Compaction.error_to_string
        in
        let execution =
          Compaction.activate ~cleanup:false ~store scratch ~policy ~now:25L
          |> require_ok Compaction.error_to_string
        in
        setup root store scratch execution
          (List.hd (Compaction.planned_cleanup plan));
        let reopened_store =
          Store.open_repository ~root |> require_ok Store.error_to_string
        in
        let reopened = Scratch.open_repository reopened_store in
        match Compaction.resume_cleanup ~store:reopened_store reopened with
        | Error _ -> ()
        | Ok _ -> Alcotest.fail "invalid cleanup state was accepted")
  in
  expect_error (fun root store _scratch execution metric ->
      Unix.unlink (Store.object_path store metric.Compaction.metric_object_id);
      ignore root;
      ignore execution);
  expect_error (fun _root store scratch _execution metric ->
      let checkpoint =
        Scratch.head scratch |> require_ok Scratch.error_to_string |> Option.get
      in
      let wrong_object =
        Store.object_path store
          (Snapshot.Snapshot.stored_object_id
             (Scratch.Checkpoint.snapshot checkpoint))
      in
      let bytes = In_channel.with_open_bin wrong_object In_channel.input_all in
      write_file
        (Store.object_path store metric.Compaction.metric_object_id)
        bytes);
  expect_error (fun root store _scratch execution metric ->
      let trash_root = Filename.concat root ".yeokcham/trash" in
      Unix.mkdir trash_root 0o700;
      let other = Filename.concat trash_root "other-generation" in
      Unix.mkdir other 0o700;
      Unix.rename
        (Store.object_path store metric.Compaction.metric_object_id)
        (Filename.concat other
           (Store.Stored_object_id.to_hex metric.Compaction.metric_object_id));
      ignore execution);
  with_cleanup_fixture (fun _root store scratch initial _middle _head ->
      let first =
        Compaction.activate ~cleanup:false ~store scratch ~policy ~now:25L
        |> require_ok Compaction.error_to_string
      in
      Scratch.pin scratch (Scratch.Checkpoint.id initial) ~changed_at:60L
      |> require_ok Scratch.error_to_string;
      ignore
        (Compaction.activate ~cleanup:false ~store scratch ~policy ~now:25L
        |> require_ok Compaction.error_to_string);
      match
        Compaction.resume_cleanup
          ~expected_generation:(Compaction.execution_generation first)
          ~store scratch
      with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "stale generation resume was accepted");
  with_cleanup_fixture (fun _root store scratch _initial _middle _head ->
      let execution =
        Compaction.activate ~cleanup:false ~store scratch ~policy ~now:25L
        |> require_ok Compaction.error_to_string
      in
      let manifest =
        Scratch.Generation.cleanup_manifest
          (Scratch.active_generation scratch
          |> require_ok Scratch.error_to_string
          |> Option.get)
      in
      write_file
        (Store.object_path store
           (Scratch.Cleanup_manifest_id.stored_object_id manifest))
        "corrupt cleanup manifest";
      ignore execution;
      match Compaction.resume_cleanup ~store scratch with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "corrupt cleanup manifest was accepted");
  with_cleanup_fixture (fun _root store scratch _initial _middle _head ->
      ignore
        (Compaction.activate ~cleanup:false ~store scratch ~policy ~now:25L
        |> require_ok Compaction.error_to_string);
      let generation =
        Scratch.active_generation scratch
        |> require_ok Scratch.error_to_string
        |> Option.get
      in
      let checkpoint =
        Scratch.head scratch |> require_ok Scratch.error_to_string |> Option.get
      in
      let snapshot_path =
        Store.object_path store
          (Snapshot.Snapshot.stored_object_id
             (Scratch.Checkpoint.snapshot checkpoint))
      in
      let bytes = In_channel.with_open_bin snapshot_path In_channel.input_all in
      write_file
        (Store.object_path store
           (Scratch.Cleanup_manifest_id.stored_object_id
              (Scratch.Generation.cleanup_manifest generation)))
        bytes;
      match Compaction.resume_cleanup ~store scratch with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "wrong-type cleanup manifest was accepted")

let activated_generation_preserves_logical_history_and_allows_new_work () =
  with_history (fun root store scratch initial middle head ->
      let logical_snapshot checkpoint =
        Scratch.Checkpoint.snapshot checkpoint
      in
      let before =
        [
          (Scratch.Checkpoint.id head, logical_snapshot head);
          (Scratch.Checkpoint.id initial, logical_snapshot initial);
        ]
      in
      let execution =
        Compaction.activate ~store scratch
          ~policy:(policy ~recent:6L ~periodic:0L)
          ~now:25L
        |> require_ok Compaction.error_to_string
      in
      let cleanup = Compaction.execution_cleanup execution in
      Alcotest.(check int)
        "superseded checkpoint and event objects quarantined" 4
        cleanup.Compaction.quarantined_objects;
      let generation =
        Scratch.active_generation scratch
        |> require_ok Scratch.error_to_string
        |> Option.get
      in
      let entries = Scratch.Generation.entries generation in
      Alcotest.(check int)
        "only retained aliases are active" 2 (List.length entries);
      let timeline =
        Scratch.timeline scratch ~limit:8 ()
        |> require_ok Scratch.error_to_string
      in
      ignore
        (Compaction.analyze ~store scratch
           ~policy:(policy ~recent:6L ~periodic:0L)
           ~now:25L
        |> require_ok Compaction.error_to_string);
      Alcotest.(check int) "compacted timeline length" 2 (List.length timeline);
      List.iter2
        (fun (logical, snapshot) entry ->
          Alcotest.(check bool)
            "logical timeline ID is stable" true
            (Scratch.Checkpoint_id.equal logical entry.Scratch.logical_id);
          Alcotest.(check bool)
            "retained snapshot is stable" true
            (Snapshot.Snapshot.equal_id snapshot
               (Scratch.Checkpoint.snapshot entry.Scratch.checkpoint)))
        before timeline;
      (match
         Scratch.resolve_checkpoint scratch (Scratch.Checkpoint.id middle)
       with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "quarantined unretained checkpoint still resolves");
      let resumed =
        Compaction.resume_cleanup ~store scratch
        |> require_ok Compaction.error_to_string
      in
      Alcotest.(check int)
        "cleanup resume accepts every quarantined candidate" 4
        resumed.Compaction.already_quarantined_objects;
      let reopened_store =
        Store.open_repository ~root |> require_ok Store.error_to_string
      in
      let reopened = Scratch.open_repository reopened_store in
      let reopened_timeline =
        Scratch.timeline reopened ~limit:8 ()
        |> require_ok Scratch.error_to_string
      in
      Alcotest.(check int)
        "reopen resolves compacted timeline" 2
        (List.length reopened_timeline);
      Scratch.Restore.restore scratch ~root
        ~target:(Scratch.Checkpoint.id initial)
        ~observed_at:26L ~created_at:26L
      |> require_ok Scratch.error_to_string
      |> ignore;
      Alcotest.(check string)
        "restore by retained logical ID remains exact" "zero"
        (In_channel.with_open_bin
           (Filename.concat root "file")
           In_channel.input_all);
      write_file (Filename.concat root "file") "three";
      let snapshot, _ =
        Snapshot.scan ~root ~store |> require_ok Snapshot.error_to_string
      in
      let created =
        Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
          ~observed_at:27L ~created_at:27L
        |> require_ok Scratch.error_to_string
      in
      (match created with
      | Scratch.Created _ -> ()
      | Scratch.Unchanged _ ->
          Alcotest.fail "new checkpoint after compaction is unchanged");
      Scratch.pin scratch (Scratch.Checkpoint.id initial) ~changed_at:28L
      |> require_ok Scratch.error_to_string;
      Scratch.unpin scratch (Scratch.Checkpoint.id initial) ~changed_at:29L
      |> require_ok Scratch.error_to_string;
      let initial_entry =
        Scratch.timeline scratch
          ~start:(Scratch.Checkpoint.id initial)
          ~limit:1 ()
        |> require_ok Scratch.error_to_string
        |> List.hd
      in
      Alcotest.(check bool)
        "post-compaction unpin applies after generation retention cutoff" false
        (List.mem Scratch.User_pinned initial_entry.Scratch.effective_retention);
      let second =
        Compaction.activate ~store scratch
          ~policy:(policy ~recent:6L ~periodic:0L)
          ~now:32L
        |> require_ok Compaction.error_to_string
      in
      Alcotest.(check bool)
        "second generation differs" true
        (not
           (Scratch.Generation_id.equal
              (Compaction.execution_generation execution)
              (Compaction.execution_generation second)));
      let pruned =
        Compaction.prune ~store scratch |> require_ok Compaction.error_to_string
      in
      Alcotest.(check int)
        "prune reports actual quarantined objects"
        (Compaction.execution_cleanup second).Compaction.quarantined_objects
        pruned.Compaction.pruned_objects;
      let after_prune =
        Compaction.prune ~store scratch |> require_ok Compaction.error_to_string
      in
      Alcotest.(check int)
        "prune accepts every permanently pruned candidate"
        pruned.Compaction.pruned_objects
        after_prune.Compaction.already_pruned_objects)

let activation_before_cleanup_and_corrupt_alias_are_detected () =
  with_history (fun _root store scratch initial middle _head ->
      ignore
        (Compaction.activate ~cleanup:false ~store scratch
           ~policy:(policy ~recent:6L ~periodic:0L)
           ~now:25L
        |> require_ok Compaction.error_to_string);
      (match
         Scratch.resolve_checkpoint scratch (Scratch.Checkpoint.id middle)
       with
      | Ok _ -> ()
      | Error _ -> Alcotest.fail "unretained object disappeared before cleanup");
      ignore
        (Compaction.resume_cleanup ~store scratch
        |> require_ok Compaction.error_to_string);
      (match
         Scratch.resolve_checkpoint scratch (Scratch.Checkpoint.id middle)
       with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "unretained object resolves after cleanup");
      let generation =
        Scratch.active_generation scratch
        |> require_ok Scratch.error_to_string
        |> Option.get
      in
      let physical =
        Scratch.Generation.entries generation
        |> List.hd |> Scratch.Generation.physical
      in
      Unix.unlink
        (Store.object_path store
           (Scratch.Checkpoint_id.stored_object_id physical));
      match
        Scratch.resolve_checkpoint scratch (Scratch.Checkpoint.id initial)
      with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "missing active alias target was accepted")

let source_ref_race_aborts_before_generation_publication () =
  with_history (fun _root store scratch _initial _middle _head ->
      let advance name =
        let reference =
          Store.read_ref store ~name
          |> require_ok Store.error_to_string
          |> Option.get
        in
        ignore
          (Store.compare_and_swap_ref store ~name ~expected:(Some reference)
             ~target:(Store.Mutable_ref.target reference)
          |> require_ok Store.error_to_string)
      in
      (match
         Compaction.activate ~store scratch
           ~policy:(policy ~recent:6L ~periodic:0L) ~now:25L
           ~before_publish:(fun () -> advance "scratch-head")
       with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "scratch-head race activated a generation");
      Alcotest.(check bool)
        "generation ref remains absent after source race" true
        (Option.is_none
           (Store.read_ref store ~name:"scratch-generation"
           |> require_ok Store.error_to_string));
      match
        Compaction.activate ~store scratch
          ~policy:(policy ~recent:6L ~periodic:0L) ~now:25L
          ~before_publish:(fun () -> advance "retention-head")
      with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "retention-head race activated a generation")

let () =
  Alcotest.run "scratch compaction"
    [
      ( "unit",
        [
          Alcotest.test_case "policy retains recent periodic and pinned" `Quick
            policy_retain_recent_periodic_and_pinned;
          Alcotest.test_case
            "budget selection keeps required checkpoints deterministically"
            `Quick budget_selection_keeps_required_and_trims_deterministically;
          Alcotest.test_case
            "exact inverse reducer preserves unmatched operations" `Quick
            exact_inverse_reducer_preserves_unmatched_operations;
          Alcotest.test_case "budget plan preserves required history" `Quick
            budget_plan_preserves_required_history;
          Alcotest.test_case
            "compaction eliminates one exact inverse retained gap" `Quick
            compaction_eliminates_exact_inverse_gap;
          Alcotest.test_case "invalid policy values reject" `Quick
            invalid_policy_values_are_rejected;
          Alcotest.test_case "cleanup reports exact candidate progress" `Quick
            cleanup_reports_exact_candidate_progress;
          Alcotest.test_case "planner is read-only and explains exact cleanup"
            `Quick planner_is_read_only_and_explains_exact_cleanup;
          Alcotest.test_case "planner rejects missing reachable record" `Quick
            planner_rejects_missing_reachable_record;
          Alcotest.test_case
            "dry-run candidate metrics equal quarantine and prune" `Quick
            planner_matches_actual_quarantine_and_prune;
          Alcotest.test_case
            "quarantine resumes at every candidate interruption boundary" `Slow
            quarantine_interruptions_resume_at_every_candidate_boundary;
          Alcotest.test_case
            "prune resumes at every candidate interruption boundary" `Slow
            prune_interruptions_resume_at_every_candidate_boundary;
          Alcotest.test_case "cleanup rejects invalid resume states" `Quick
            cleanup_rejects_invalid_resume_states;
          Alcotest.test_case
            "generation preserves logical history and accepts subsequent work"
            `Quick
            activated_generation_preserves_logical_history_and_allows_new_work;
          Alcotest.test_case
            "activation survives pre-cleanup state and rejects corrupt aliases"
            `Quick activation_before_cleanup_and_corrupt_alias_are_detected;
          Alcotest.test_case "source ref races abort activation" `Quick
            source_ref_race_aborts_before_generation_publication;
        ] );
    ]
