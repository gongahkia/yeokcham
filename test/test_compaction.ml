module Compaction = Paengi_compaction
module Scratch = Paengi_scratch
module Snapshot = Paengi_snapshot
module Store = Paengi_store

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

let checkpoint value created_at effective_retention =
  {
    Compaction.Policy.id = checkpoint_id value;
    created_at;
    effective_retention;
  }

let policy ~recent ~periodic =
  Compaction.Policy.create ~recent_window_seconds:recent
    ~periodic_interval_seconds:periodic ~storage_budget_bytes:None
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
  | Compaction.Policy.Expired ->
      Alcotest.fail "pin did not override expiry");
  (match
     Compaction.Policy.decision
       (selection_for newer_same_bucket.Compaction.Policy.id selections)
   with
  | Compaction.Policy.Periodic_bucket 8L -> ()
  | Compaction.Policy.Protected_by _ | Compaction.Policy.Recent_window
  | Compaction.Policy.Periodic_bucket _ | Compaction.Policy.Expired ->
      Alcotest.fail "newest checkpoint was not selected for periodic bucket");
  (match
     Compaction.Policy.decision
       (selection_for older_same_bucket.Compaction.Policy.id selections)
   with
  | Compaction.Policy.Expired -> ()
  | Compaction.Policy.Protected_by _ | Compaction.Policy.Recent_window
  | Compaction.Policy.Periodic_bucket _ ->
      Alcotest.fail "older checkpoint survived periodic thinning");
  match
    Compaction.Policy.decision
      (selection_for periodic.Compaction.Policy.id selections)
  with
  | Compaction.Policy.Periodic_bucket 7L -> ()
  | Compaction.Policy.Protected_by _ | Compaction.Policy.Recent_window
  | Compaction.Policy.Periodic_bucket _ | Compaction.Policy.Expired ->
      Alcotest.fail "periodic checkpoint expired"

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
  with_directory "paengi-compaction-" (fun root ->
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

let planner_is_read_only_and_explains_blocked_removal () =
  with_history (fun root store scratch initial middle head ->
      let head_path = Filename.concat root ".paengi/refs/scratch-head" in
      let before = In_channel.with_open_bin head_path In_channel.input_all in
      let plan =
        Compaction.analyze ~store scratch
          ~policy:(policy ~recent:0L ~periodic:0L)
          ~now:100L
        |> require_ok Compaction.error_to_string
      in
      let after = In_channel.with_open_bin head_path In_channel.input_all in
      Alcotest.(check string)
        "dry-run leaves scratch-head unchanged" before after;
      Alcotest.(check bool)
        "all reachable objects counted" true
        (Compaction.reachable_object_count plan > 0);
      Alcotest.(check int64)
        "no safe rewrite keeps byte estimate"
        (Compaction.estimated_before_bytes plan)
        (Compaction.estimated_after_bytes plan);
      Alcotest.(check int)
        "no checkpoints are removable" 0
        (List.length (Compaction.removable_checkpoints plan));
      Alcotest.(check int)
        "expired checkpoints explain their block" 2
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
      | Compaction.Policy.Expired ->
          Alcotest.fail "pinned checkpoint was not protected");
      (match
         Compaction.Policy.decision
           (selection_for (Scratch.Checkpoint.id middle) selected)
       with
      | Compaction.Policy.Expired -> ()
      | Compaction.Policy.Protected_by _ | Compaction.Policy.Recent_window
      | Compaction.Policy.Periodic_bucket _ ->
          Alcotest.fail "expired checkpoint was retained");
      (match
         Compaction.Policy.decision
           (selection_for (Scratch.Checkpoint.id head) selected)
       with
      | Compaction.Policy.Expired -> ()
      | Compaction.Policy.Protected_by _ | Compaction.Policy.Recent_window
      | Compaction.Policy.Periodic_bucket _ ->
          Alcotest.fail "expired head was not reported");
      let explanation = Compaction.render_explain plan in
      Alcotest.(check bool)
        "explanation reports no removal" true
        (List.mem "removable-checkpoints=0" explanation);
      Alcotest.(check bool)
        "explanation reports blocked ancestry" true
        (List.exists
           (String.starts_with ~prefix:"blocked-removal ")
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

let () =
  Alcotest.run "scratch compaction"
    [
      ( "unit",
        [
          Alcotest.test_case "policy retains recent periodic and pinned" `Quick
            policy_retain_recent_periodic_and_pinned;
          Alcotest.test_case "invalid policy values reject" `Quick
            invalid_policy_values_are_rejected;
          Alcotest.test_case "planner is read-only and explains blocked removal"
            `Quick planner_is_read_only_and_explains_blocked_removal;
          Alcotest.test_case "planner rejects missing reachable record" `Quick
            planner_rejects_missing_reachable_record;
        ] );
    ]
