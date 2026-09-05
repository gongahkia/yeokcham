module V1 = Yeokcham_v1_model

let require_ok = Result.get_ok
let snapshot value = V1.Snapshot_id.of_string value |> require_ok
let draft value = V1.Draft_id.of_string value |> require_ok
let change value = V1.Change_id.of_string value |> require_ok
let revision value = V1.Revision_id.of_string value |> require_ok
let device value = V1.Device_id.of_string value |> require_ok
let username value = V1.Username.of_string value |> require_ok
let path value = V1.Path.of_components [ value ] |> require_ok

let revision_with_span ~change_id ~revision_id ~author ~start_byte ~end_byte =
  let span = V1.make_span ~start_byte ~end_byte |> require_ok in
  V1.make_change_revision ~change:(change change_id)
    ~revision:(revision revision_id) ~parent:None ~author:(device author)
    ~base:(snapshot "snapshot-base")
    ~result:(snapshot ("snapshot-" ^ revision_id))
    ~edits:[ V1.{ edit_path = path "same.ml"; edit_kind = Text span } ]
  |> require_ok

let project () =
  V1.init ~creator:(device "device-alice") ~username:(username "alice")
    ~initial_snapshot:(snapshot "snapshot-base")
    ~initial_draft:(draft "draft-one") ~title:"property"

let disjoint_text_spans_are_order_independent =
  QCheck2.Test.make ~count:200
    ~name:"V1 proven-disjoint text spans compose independently of arrival order"
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
          (fun state candidate -> V1.receive state candidate |> require_ok)
          (project ()) incoming
        |> V1.projection
      in
      let left = compose [ first; second ] in
      let right = compose [ second; first ] in
      List.length left.V1.decisions = 0
      && List.length left.V1.applied = 2
      && List.map
           (fun revision -> V1.Revision_id.to_string revision.V1.revision)
           left.V1.applied
         = List.map
             (fun revision -> V1.Revision_id.to_string revision.V1.revision)
             right.V1.applied)

let checkpoint_history_is_unique_and_newest_first =
  QCheck2.Test.make ~count:200
    ~name:"V1 checkpoint history retains unique snapshots newest-first"
    QCheck2.Gen.(list_size (int_range 0 80) (int_range 0 20))
    (fun values ->
      let snapshots =
        List.map
          (fun value -> snapshot ("snapshot-" ^ string_of_int value))
          values
      in
      let state =
        List.fold_left
          (fun state snapshot -> V1.checkpoint state ~snapshot)
          (project ()) snapshots
      in
      let expected =
        List.fold_left
          (fun history snapshot ->
            if
              List.exists
                (fun existing -> V1.Snapshot_id.equal existing snapshot)
                history
            then history
            else snapshot :: history)
          [ snapshot "snapshot-base" ]
          snapshots
      in
      let actual =
        V1.checkpoints state
        |> List.map (fun checkpoint -> checkpoint.V1.checkpoint_snapshot)
      in
      let active = V1.active_draft state in
      let expected_active =
        match List.rev snapshots with
        | [] -> snapshot "snapshot-base"
        | latest :: _ -> latest
      in
      List.length expected = List.length actual
      && List.for_all2 V1.Snapshot_id.equal expected actual
      && V1.Snapshot_id.equal active.V1.latest_checkpoint expected_active)

let compact_never_drops_named_roots =
  QCheck2.Test.make ~count:200
    ~name:"V1 compaction never drops named, pinned, or restore-proof roots"
    QCheck2.Gen.(triple (int_range 1 40) (int_range 0 8) bool)
    (fun (extra, keep_recent, retain_proof) ->
      let extras =
        List.init extra (fun index ->
            snapshot ("snapshot-extra-" ^ string_of_int index))
      in
      let project =
        extras
        |> List.fold_left
             (fun project snapshot -> V1.checkpoint project ~snapshot)
             (project ())
      in
      let proof_snapshots = if retain_proof then [ List.hd extras ] else [] in
      match
        V1.compact project ~keep_recent ~journal_snapshots:[] ~proof_snapshots
      with
      | Error _ -> false
      | Ok compacted ->
          let retained =
            compacted.V1.project |> V1.checkpoints
            |> List.map (fun checkpoint -> checkpoint.V1.checkpoint_snapshot)
          in
          let active = V1.active_draft compacted.V1.project in
          List.exists
            (V1.Snapshot_id.equal active.V1.latest_checkpoint)
            retained
          && List.exists
               (V1.Snapshot_id.equal
                  (V1.export compacted.V1.project).V1.state_baseline)
               retained
          && List.for_all
               (fun proof -> List.exists (V1.Snapshot_id.equal proof) retained)
               proof_snapshots
          && List.length compacted.V1.dropped
             = List.length (V1.checkpoints project) - List.length retained)

let username_registrations_remain_a_unique_local_bijection =
  QCheck2.Test.make ~count:200
    ~name:"V1 username registration keeps one safe display handle per device"
    QCheck2.Gen.(list_size (int_range 0 80) (int_range 0 20))
    (fun values ->
      let project =
        List.fold_left
          (fun project value ->
            V1.register_username project
              ~device:(device ("device-user-" ^ string_of_int value))
              ~username:(username ("user-" ^ string_of_int value))
            |> require_ok)
          (project ()) values
      in
      let registrations = V1.usernames project in
      let devices =
        List.map
          (fun registration ->
            V1.Device_id.to_string registration.V1.username_device)
          registrations
      in
      let usernames =
        List.map
          (fun registration -> V1.Username.to_string registration.V1.username)
          registrations
      in
      let unique values = List.sort_uniq String.compare values in
      List.length devices = List.length (unique devices)
      && List.length usernames = List.length (unique usernames)
      && Result.is_ok (V1.import (V1.export project)))

let () =
  Alcotest.run "V1 model properties"
    [
      ( "composition",
        [
          QCheck_alcotest.to_alcotest disjoint_text_spans_are_order_independent;
          QCheck_alcotest.to_alcotest
            checkpoint_history_is_unique_and_newest_first;
          QCheck_alcotest.to_alcotest compact_never_drops_named_roots;
          QCheck_alcotest.to_alcotest
            username_registrations_remain_a_unique_local_bijection;
        ] );
    ]
