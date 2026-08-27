module V4 = Yeokcham_v4_model

let require_ok = Result.get_ok
let snapshot value = V4.Snapshot_id.of_string value |> require_ok
let draft value = V4.Draft_id.of_string value |> require_ok
let change value = V4.Change_id.of_string value |> require_ok
let revision value = V4.Revision_id.of_string value |> require_ok
let device value = V4.Device_id.of_string value |> require_ok
let path value = V4.Path.of_components [ value ] |> require_ok

let revision_with_span ~change_id ~revision_id ~author ~start_byte ~end_byte =
  let span = V4.make_span ~start_byte ~end_byte |> require_ok in
  V4.make_change_revision ~change:(change change_id)
    ~revision:(revision revision_id) ~parent:None ~author:(device author)
    ~base:(snapshot "snapshot-base")
    ~result:(snapshot ("snapshot-" ^ revision_id))
    ~edits:[ V4.{ edit_path = path "same.ml"; edit_kind = Text span } ]
  |> require_ok

let project () =
  V4.init ~creator:(device "device-alice")
    ~initial_snapshot:(snapshot "snapshot-base")
    ~initial_draft:(draft "draft-one") ~title:"property"

let disjoint_text_spans_are_order_independent =
  QCheck2.Test.make ~count:200
    ~name:"V4 proven-disjoint text spans compose independently of arrival order"
    QCheck2.Gen.(pair (int_range 0 1_000) (int_range 1 100))
    (fun (start_byte, width) ->
      let first_end = start_byte + width in
      let second_start = first_end + 1 in
      let second_end = second_start + width in
      let first =
        revision_with_span ~change_id:"change-alpha"
          ~revision_id:"revision-alpha" ~author:"device-bob" ~start_byte
          ~end_byte:first_end
      in
      let second =
        revision_with_span ~change_id:"change-beta" ~revision_id:"revision-beta"
          ~author:"device-carol" ~start_byte:second_start ~end_byte:second_end
      in
      let compose incoming =
        List.fold_left
          (fun state candidate -> V4.receive state candidate |> require_ok)
          (project ()) incoming
        |> V4.projection
      in
      let left = compose [ first; second ] in
      let right = compose [ second; first ] in
      List.length left.V4.decisions = 0
      && List.length left.V4.applied = 2
      && List.map
           (fun revision -> V4.Revision_id.to_string revision.V4.revision)
           left.V4.applied
         = List.map
             (fun revision -> V4.Revision_id.to_string revision.V4.revision)
             right.V4.applied)

let checkpoint_history_is_unique_and_newest_first =
  QCheck2.Test.make ~count:200
    ~name:"V4 checkpoint history retains unique snapshots newest-first"
    QCheck2.Gen.(list_size (int_range 0 80) (int_range 0 20))
    (fun values ->
      let snapshots =
        List.map
          (fun value -> snapshot ("snapshot-" ^ string_of_int value))
          values
      in
      let state =
        List.fold_left
          (fun state snapshot -> V4.checkpoint state ~snapshot)
          (project ()) snapshots
      in
      let expected =
        List.fold_left
          (fun history snapshot ->
            if
              List.exists
                (fun existing -> V4.Snapshot_id.equal existing snapshot)
                history
            then history
            else snapshot :: history)
          [ snapshot "snapshot-base" ]
          snapshots
      in
      let actual =
        V4.checkpoints state
        |> List.map (fun checkpoint -> checkpoint.V4.checkpoint_snapshot)
      in
      let active = V4.active_draft state in
      let expected_active =
        match List.rev snapshots with
        | [] -> snapshot "snapshot-base"
        | latest :: _ -> latest
      in
      List.length expected = List.length actual
      && List.for_all2 V4.Snapshot_id.equal expected actual
      && V4.Snapshot_id.equal active.V4.latest_checkpoint expected_active)

let compact_never_drops_named_roots =
  QCheck2.Test.make ~count:200
    ~name:"V4 compaction never drops named or pinned checkpoints"
    QCheck2.Gen.(pair (int_range 0 40) (int_range 0 8))
    (fun (extra, keep_recent) ->
      let project =
        List.init extra (fun index ->
            snapshot ("snapshot-extra-" ^ string_of_int index))
        |> List.fold_left
             (fun project snapshot -> V4.checkpoint project ~snapshot)
             (project ())
      in
      match V4.compact project ~keep_recent ~journal_snapshots:[] with
      | Error _ -> false
      | Ok compacted ->
          let retained =
            compacted.V4.project |> V4.checkpoints
            |> List.map (fun checkpoint -> checkpoint.V4.checkpoint_snapshot)
          in
          let active = V4.active_draft compacted.V4.project in
          List.exists
            (V4.Snapshot_id.equal active.V4.latest_checkpoint)
            retained
          && List.exists
               (V4.Snapshot_id.equal
                  (V4.export compacted.V4.project).V4.state_baseline)
               retained
          && List.length compacted.V4.dropped
             = List.length (V4.checkpoints project) - List.length retained)

let () =
  Alcotest.run "V4 model properties"
    [
      ( "composition",
        [
          QCheck_alcotest.to_alcotest disjoint_text_spans_are_order_independent;
          QCheck_alcotest.to_alcotest
            checkpoint_history_is_unique_and_newest_first;
          QCheck_alcotest.to_alcotest compact_never_drops_named_roots;
        ] );
    ]
