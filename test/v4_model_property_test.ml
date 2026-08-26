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
  V4.make_change_revision ~change:(change change_id) ~revision:(revision revision_id)
    ~parent:None ~author:(device author) ~base:(snapshot "snapshot-base")
    ~result:(snapshot ("snapshot-" ^ revision_id))
    ~edits:[ V4.{ path = path "same.ml"; kind = Text span } ]
  |> require_ok

let project () =
  V4.init ~creator:(device "device-alice") ~initial_snapshot:(snapshot "snapshot-base")
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
        revision_with_span ~change_id:"change-alpha" ~revision_id:"revision-alpha"
          ~author:"device-bob" ~start_byte ~end_byte:first_end
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
      && List.map (fun revision -> V4.Revision_id.to_string revision.V4.revision) left.V4.applied
         = List.map (fun revision -> V4.Revision_id.to_string revision.V4.revision) right.V4.applied)

let () =
  Alcotest.run "V4 model properties"
    [
      ( "composition",
        [ QCheck_alcotest.to_alcotest disjoint_text_spans_are_order_independent ] );
    ]
