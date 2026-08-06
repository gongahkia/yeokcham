module Compaction = Yeokcham_compaction
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store

let default_seed = 20_260_730

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed
  | None -> default_seed

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  !value

let () = Printf.printf "compaction property base seed: %d\n%!" base_seed
let state_for name = Random.State.make [| stable_seed name |]

let checkpoint_id value =
  let raw = Bytes.make 32 '\000' in
  Bytes.set raw 0 (Char.chr (value land 0xff));
  Store.Stored_object_id.of_raw_bytes (Bytes.unsafe_to_string raw)
  |> Option.get |> Scratch.Checkpoint_id.of_stored_object_id

let content_id value =
  let raw = Bytes.make 32 '\000' in
  Bytes.set raw 0 (Char.chr (value land 0xff));
  Store.Stored_object_id.of_raw_bytes (Bytes.unsafe_to_string raw)
  |> Option.get |> Snapshot.Content.of_stored_object_id

let checkpoint ?(storage_bytes = 0L) value created_at pinned =
  {
    Compaction.Policy.id = checkpoint_id value;
    created_at = Int64.of_int created_at;
    effective_retention = (if pinned then [ Scratch.User_pinned ] else []);
    storage_bytes;
  }

let policy =
  Compaction.Policy.create ~recent_window_seconds:10L
    ~periodic_interval_seconds:25L ~storage_budget_bytes:None
  |> Result.get_ok

let decision_equal left right =
  match (left, right) with
  | Compaction.Policy.Protected_by left, Compaction.Policy.Protected_by right ->
      String.equal
        (Scratch.retention_reason_to_string left)
        (Scratch.retention_reason_to_string right)
  | Compaction.Policy.Recent_window, Compaction.Policy.Recent_window -> true
  | ( Compaction.Policy.Periodic_bucket left,
      Compaction.Policy.Periodic_bucket right ) ->
      Int64.equal left right
  | Compaction.Policy.Required_for_replay, Compaction.Policy.Required_for_replay
  | Compaction.Policy.Budget_excluded, Compaction.Policy.Budget_excluded ->
      true
  | Compaction.Policy.Expired, Compaction.Policy.Expired -> true
  | ( Compaction.Policy.Protected_by _,
      ( Compaction.Policy.Recent_window | Compaction.Policy.Periodic_bucket _
      | Compaction.Policy.Required_for_replay
      | Compaction.Policy.Budget_excluded | Compaction.Policy.Expired ) )
  | ( ( Compaction.Policy.Recent_window | Compaction.Policy.Periodic_bucket _
      | Compaction.Policy.Required_for_replay
      | Compaction.Policy.Budget_excluded | Compaction.Policy.Expired ),
      Compaction.Policy.Protected_by _ )
  | ( Compaction.Policy.Recent_window,
      ( Compaction.Policy.Periodic_bucket _
      | Compaction.Policy.Required_for_replay
      | Compaction.Policy.Budget_excluded | Compaction.Policy.Expired ) )
  | ( ( Compaction.Policy.Periodic_bucket _
      | Compaction.Policy.Required_for_replay
      | Compaction.Policy.Budget_excluded | Compaction.Policy.Expired ),
      Compaction.Policy.Recent_window )
  | ( Compaction.Policy.Periodic_bucket _,
      ( Compaction.Policy.Required_for_replay
      | Compaction.Policy.Budget_excluded | Compaction.Policy.Expired ) )
  | ( ( Compaction.Policy.Required_for_replay
      | Compaction.Policy.Budget_excluded | Compaction.Policy.Expired ),
      Compaction.Policy.Periodic_bucket _ )
  | ( Compaction.Policy.Required_for_replay,
      (Compaction.Policy.Budget_excluded | Compaction.Policy.Expired) )
  | ( (Compaction.Policy.Budget_excluded | Compaction.Policy.Expired),
      Compaction.Policy.Required_for_replay )
  | Compaction.Policy.Budget_excluded, Compaction.Policy.Expired
  | Compaction.Policy.Expired, Compaction.Policy.Budget_excluded ->
      false

let permutation_does_not_change_selection =
  QCheck2.Test.make ~count:100
    ~name:"retention selection is independent of timeline input order"
    QCheck2.Gen.(list_size (int_range 0 24) (pair (int_range 0 150) bool))
    (fun values ->
      let checkpoints =
        List.mapi
          (fun index (created_at, pinned) -> checkpoint index created_at pinned)
          values
      in
      let selected = Compaction.Policy.select policy ~now:100L checkpoints in
      let reversed =
        Compaction.Policy.select policy ~now:100L (List.rev checkpoints)
      in
      List.for_all
        (fun checkpoint ->
          let lookup selections =
            List.find
              (fun selection ->
                Scratch.Checkpoint_id.equal
                  (Compaction.Policy.checkpoint selection).Compaction.Policy.id
                  checkpoint.Compaction.Policy.id)
              selections
          in
          decision_equal
            (Compaction.Policy.decision (lookup selected))
            (Compaction.Policy.decision (lookup reversed)))
        checkpoints)

let budget_permutation_does_not_change_selection =
  QCheck2.Test.make ~count:100
    ~name:"budget retention selection is independent of timeline input order"
    QCheck2.Gen.(
      list_size (int_range 1 24)
        (triple (int_range 0 150) bool (int_range 0 80)))
    (fun values ->
      let checkpoints =
        List.mapi
          (fun index (created_at, pinned, bytes) ->
            checkpoint ~storage_bytes:(Int64.of_int bytes) index created_at
              pinned)
          values
      in
      let required = [ (List.hd checkpoints).Compaction.Policy.id ] in
      let policy =
        Compaction.Policy.create ~recent_window_seconds:25L
          ~periodic_interval_seconds:30L ~storage_budget_bytes:(Some 100L)
        |> Result.get_ok
      in
      let selected =
        Compaction.Policy.select ~required policy ~now:100L checkpoints
      in
      let reversed =
        Compaction.Policy.select ~required policy ~now:100L
          (List.rev checkpoints)
      in
      List.for_all
        (fun checkpoint ->
          let lookup selections =
            List.find
              (fun selection ->
                Scratch.Checkpoint_id.equal
                  (Compaction.Policy.checkpoint selection).Compaction.Policy.id
                  checkpoint.Compaction.Policy.id)
              selections
          in
          decision_equal
            (Compaction.Policy.decision (lookup selected))
            (Compaction.Policy.decision (lookup reversed)))
        checkpoints)

let pinned_checkpoints_never_expire =
  QCheck2.Test.make ~count:100
    ~name:"user-pinned checkpoints override every expiry policy"
    QCheck2.Gen.(int_range (-1_000_000) 1_000_000)
    (fun created_at ->
      let pinned = checkpoint 1 created_at true in
      match
        Compaction.Policy.select policy ~now:100L [ pinned ]
        |> List.hd |> Compaction.Policy.decision
      with
      | Compaction.Policy.Protected_by reason ->
          String.equal (Scratch.retention_reason_to_string reason) "user pinned"
      | Compaction.Policy.Recent_window | Compaction.Policy.Periodic_bucket _
      | Compaction.Policy.Required_for_replay
      | Compaction.Policy.Budget_excluded | Compaction.Policy.Expired ->
          false)

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

let compacted_logical_checkpoints_preserve_snapshots =
  QCheck2.Test.make ~count:20
    ~name:"compacted retained logical checkpoints preserve snapshots"
    QCheck2.Gen.(int_range 1 6)
    (fun count ->
      let root = Filename.temp_file "yeokcham-compaction-property-" "" in
      Unix.unlink root;
      Unix.mkdir root 0o700;
      Fun.protect
        ~finally:(fun () -> remove_tree root)
        (fun () ->
          try
            let file = Filename.concat root "file" in
            Out_channel.with_open_bin file (fun channel ->
                Out_channel.output_string channel "base");
            let store = Store.init ~root |> Result.get_ok in
            let scratch = Scratch.open_repository store in
            let base, _ = Snapshot.scan ~root ~store |> Result.get_ok in
            let initial =
              Scratch.create_initial scratch ~snapshot:base ~created_at:0L
              |> Result.get_ok
            in
            Scratch.pin scratch (Scratch.Checkpoint.id initial) ~changed_at:1L
            |> Result.get_ok;
            let head = ref initial in
            for index = 1 to count do
              Out_channel.with_open_bin file (fun channel ->
                  Out_channel.output_string channel
                    (Printf.sprintf "edit-%d" index));
              let snapshot, _ = Snapshot.scan ~root ~store |> Result.get_ok in
              match
                Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
                  ~observed_at:(Int64.of_int index)
                  ~created_at:(Int64.of_int index)
                |> Result.get_ok
              with
              | Scratch.Created checkpoint -> head := checkpoint
              | Scratch.Unchanged _ -> raise Exit
            done;
            let expected =
              [
                (Scratch.Checkpoint.id !head, Scratch.Checkpoint.snapshot !head);
                ( Scratch.Checkpoint.id initial,
                  Scratch.Checkpoint.snapshot initial );
              ]
            in
            let policy =
              Compaction.Policy.create ~recent_window_seconds:1L
                ~periodic_interval_seconds:0L ~storage_budget_bytes:None
              |> Result.get_ok
            in
            ignore
              (Compaction.activate ~store scratch ~policy
                 ~now:(Int64.of_int (count + 1))
              |> Result.get_ok);
            let actual =
              Scratch.timeline scratch ~limit:8 () |> Result.get_ok
            in
            List.length actual = List.length expected
            && List.for_all2
                 (fun (logical, snapshot) entry ->
                   Scratch.Checkpoint_id.equal logical entry.Scratch.logical_id
                   && Snapshot.Snapshot.equal_id snapshot
                        (Scratch.Checkpoint.snapshot entry.Scratch.checkpoint))
                 expected actual
          with Exit | Failure _ -> false))

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

let with_cleanup_fixture count run =
  let root = Filename.temp_file "yeokcham-compaction-cleanup-property-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let file = Filename.concat root "file" in
      Out_channel.with_open_bin file (fun channel ->
          Out_channel.output_string channel "base");
      let store = Store.init ~root |> Result.get_ok in
      let scratch = Scratch.open_repository store in
      let base, _ = Snapshot.scan ~root ~store |> Result.get_ok in
      let initial =
        Scratch.create_initial scratch ~snapshot:base ~created_at:0L
        |> Result.get_ok
      in
      let head = ref initial in
      for index = 1 to count do
        Out_channel.with_open_bin file (fun channel ->
            Out_channel.output_string channel (Printf.sprintf "edit-%d" index));
        let snapshot, _ = Snapshot.scan ~root ~store |> Result.get_ok in
        match
          Scratch.checkpoint scratch ~snapshot ~source:Scratch.Explicit
            ~observed_at:(Int64.of_int index) ~created_at:(Int64.of_int index)
          |> Result.get_ok
        with
        | Scratch.Created checkpoint -> head := checkpoint
        | Scratch.Unchanged _ -> raise Exit
      done;
      Scratch.pin scratch
        (Scratch.Checkpoint.id initial)
        ~changed_at:(Int64.of_int (count + 1))
      |> Result.get_ok;
      let policy =
        Compaction.Policy.create ~recent_window_seconds:1L
          ~periodic_interval_seconds:0L ~storage_budget_bytes:None
        |> Result.get_ok
      in
      run root store scratch initial !head policy)

let active_generation_id scratch =
  Scratch.active_generation scratch
  |> Result.get_ok |> Option.get |> Scratch.Generation.id

let all_candidates_in_quarantine store root generation planned =
  let trash =
    Filename.concat
      (Filename.concat root ".yeokcham/trash")
      (Store.Stored_object_id.to_hex
         (Scratch.Generation_id.stored_object_id generation))
  in
  List.for_all
    (fun metric ->
      let name =
        Store.Stored_object_id.to_hex metric.Compaction.metric_object_id
      in
      (not
         (Sys.file_exists
            (Store.object_path store metric.Compaction.metric_object_id)))
      && Sys.file_exists (Filename.concat trash name))
    planned

let all_candidates_pruned store root generation planned =
  let trash =
    Filename.concat
      (Filename.concat root ".yeokcham/trash")
      (Store.Stored_object_id.to_hex
         (Scratch.Generation_id.stored_object_id generation))
  in
  List.for_all
    (fun metric ->
      let name =
        Store.Stored_object_id.to_hex metric.Compaction.metric_object_id
      in
      (not
         (Sys.file_exists
            (Store.object_path store metric.Compaction.metric_object_id)))
      && not (Sys.file_exists (Filename.concat trash name)))
    planned

let retained_resolution_is_stable scratch initial head =
  List.for_all
    (fun checkpoint ->
      match
        Scratch.resolve_checkpoint scratch (Scratch.Checkpoint.id checkpoint)
      with
      | Ok resolved ->
          Snapshot.Snapshot.equal_id
            (Scratch.Checkpoint.snapshot checkpoint)
            (Scratch.Checkpoint.snapshot (Scratch.resolved_checkpoint resolved))
      | Error _ -> false)
    [ initial; head ]

let planned_cleanup_matches_actual_quarantine =
  QCheck2.Test.make ~count:10
    ~name:"dry-run cleanup IDs types counts and stored bytes match quarantine"
    QCheck2.Gen.(int_range 2 5)
    (fun count ->
      try
        with_cleanup_fixture count
          (fun _root store scratch _initial _head policy ->
            let plan =
              Compaction.analyze ~store scratch ~policy
                ~now:(Int64.of_int (count + 1))
              |> Result.get_ok
            in
            let execution =
              Compaction.activate ~cleanup:false ~store scratch ~policy
                ~now:(Int64.of_int (count + 1))
              |> Result.get_ok
            in
            let actual =
              Compaction.resume_cleanup ~store scratch |> Result.get_ok
            in
            metrics_equal
              (Compaction.planned_cleanup plan)
              actual.Compaction.quarantined_candidates
            && Int64.equal
                 (Compaction.planned_cleanup_bytes plan)
                 actual.Compaction.quarantined_bytes
            && Compaction.planned_cleanup_count plan
               = actual.Compaction.quarantined_objects
            && Scratch.Generation_id.equal
                 (Compaction.execution_generation execution)
                 (active_generation_id scratch))
      with Exit | Failure _ | Invalid_argument _ -> false)

let quarantine_resume_is_independent_of_interruption =
  QCheck2.Test.make ~count:10
    ~name:
      "quarantine resume reaches one exact active quarantine for every boundary"
    QCheck2.Gen.(pair (int_range 2 5) (pair (int_range 0 31) bool))
    (fun (count, (raw_index, after)) ->
      try
        with_cleanup_fixture count
          (fun root store scratch initial head policy ->
            let plan =
              Compaction.analyze ~store scratch ~policy
                ~now:(Int64.of_int (count + 1))
              |> Result.get_ok
            in
            let planned = Compaction.planned_cleanup plan in
            let candidate_count = List.length planned in
            let index = raw_index mod candidate_count in
            let fault =
              if after then Compaction.Fault.after_candidate index
              else Compaction.Fault.before_candidate index
            in
            let execution =
              Compaction.activate ~cleanup:false ~store scratch ~policy
                ~now:(Int64.of_int (count + 1))
              |> Result.get_ok
            in
            let interrupted = Compaction.resume_cleanup ~fault ~store scratch in
            let reopened_store = Store.open_repository ~root |> Result.get_ok in
            let reopened = Scratch.open_repository reopened_store in
            let resumed =
              Compaction.resume_cleanup ~store:reopened_store reopened
              |> Result.get_ok
            in
            let repeated =
              Compaction.resume_cleanup ~store:reopened_store reopened
              |> Result.get_ok
            in
            Result.is_error interrupted
            && all_candidates_in_quarantine reopened_store root
                 (Compaction.execution_generation execution)
                 planned
            && resumed.Compaction.quarantined_objects
               + resumed.Compaction.already_quarantined_objects
               = candidate_count
            && repeated.Compaction.already_quarantined_objects = candidate_count
            && Scratch.Generation_id.equal
                 (Compaction.execution_generation execution)
                 (active_generation_id reopened)
            && retained_resolution_is_stable reopened initial head
            && Sys.file_exists
                 (Store.object_path reopened_store
                    (Snapshot.Snapshot.stored_object_id
                       (Scratch.Checkpoint.snapshot head))))
      with Exit | Failure _ | Invalid_argument _ -> false)

let prune_resume_is_independent_of_interruption =
  QCheck2.Test.make ~count:10
    ~name:"prune resume reaches one exact pruned state for every boundary"
    QCheck2.Gen.(pair (int_range 2 5) (pair (int_range 0 31) bool))
    (fun (count, (raw_index, after)) ->
      try
        with_cleanup_fixture count
          (fun root store scratch initial head policy ->
            let plan =
              Compaction.analyze ~store scratch ~policy
                ~now:(Int64.of_int (count + 1))
              |> Result.get_ok
            in
            let planned = Compaction.planned_cleanup plan in
            let candidate_count = List.length planned in
            let index = raw_index mod candidate_count in
            let fault =
              if after then Compaction.Fault.after_candidate index
              else Compaction.Fault.before_candidate index
            in
            let execution =
              Compaction.activate ~cleanup:false ~store scratch ~policy
                ~now:(Int64.of_int (count + 1))
              |> Result.get_ok
            in
            ignore (Compaction.resume_cleanup ~store scratch |> Result.get_ok);
            let interrupted = Compaction.prune ~fault ~store scratch in
            let reopened_store = Store.open_repository ~root |> Result.get_ok in
            let reopened = Scratch.open_repository reopened_store in
            let resumed =
              Compaction.prune ~store:reopened_store reopened |> Result.get_ok
            in
            let repeated =
              Compaction.prune ~store:reopened_store reopened |> Result.get_ok
            in
            Result.is_error interrupted
            && all_candidates_pruned reopened_store root
                 (Compaction.execution_generation execution)
                 planned
            && resumed.Compaction.pruned_objects
               + resumed.Compaction.already_pruned_objects
               = candidate_count
            && repeated.Compaction.already_pruned_objects = candidate_count
            && Scratch.Generation_id.equal
                 (Compaction.execution_generation execution)
                 (active_generation_id reopened)
            && retained_resolution_is_stable reopened initial head
            && Sys.file_exists
                 (Store.object_path reopened_store
                    (Snapshot.Snapshot.stored_object_id
                       (Scratch.Checkpoint.snapshot head))))
      with Exit | Failure _ | Invalid_argument _ -> false)

let exact_inverse_content_pairs_reduce_to_empty =
  QCheck2.Test.make ~count:100
    ~name:
      "exact inverse content pairs reduce without changing the pair boundary"
    QCheck2.Gen.(pair (int_range 0 255) (int_range 0 255))
    (fun (left, right) ->
      let expected = content_id left in
      let replacement = content_id right in
      let reduced, eliminated =
        Compaction.eliminate_exact_inverse_pairs
          [
            Scratch.Modify_content { path = [ "file" ]; expected; replacement };
            Scratch.Modify_content
              {
                path = [ "file" ];
                expected = replacement;
                replacement = expected;
              };
          ]
      in
      eliminated = 1 && reduced = [])

let () =
  Alcotest.run "compaction properties"
    [
      ( "property",
        [
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "permutation")
            permutation_does_not_change_selection;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "budget-permutation")
            budget_permutation_does_not_change_selection;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "exact-inverse-pairs")
            exact_inverse_content_pairs_reduce_to_empty;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "pins") pinned_checkpoints_never_expire;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "compacted-logical-snapshots")
            compacted_logical_checkpoints_preserve_snapshots;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "planned-cleanup-metrics")
            planned_cleanup_matches_actual_quarantine;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "quarantine-interruptions")
            quarantine_resume_is_independent_of_interruption;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "prune-interruptions")
            prune_resume_is_independent_of_interruption;
        ] );
    ]
