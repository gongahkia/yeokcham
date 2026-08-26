module V4 = Yeokcham_v4_model

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (V4.error_to_string error)

let snapshot value = V4.Snapshot_id.of_string value |> require_ok
let draft value = V4.Draft_id.of_string value |> require_ok
let change value = V4.Change_id.of_string value |> require_ok
let revision value = V4.Revision_id.of_string value |> require_ok
let delivery value = V4.Delivery_id.of_string value |> require_ok
let device value = V4.Device_id.of_string value |> require_ok
let path components = V4.Path.of_components components |> require_ok

let text_edit components start_byte end_byte =
  let span = V4.make_span ~start_byte ~end_byte |> require_ok in
  V4.{ path = path components; kind = Text span }

let revision_record ?parent ~change_id ~revision_id ~author ~base ~result edits =
  V4.make_change_revision ~change:change_id ~revision:revision_id ~parent ~author
    ~base ~result ~edits
  |> require_ok

let initial_project () =
  let creator = device "device-alice" in
  let base = snapshot "snapshot-base" in
  V4.init ~creator ~initial_snapshot:base ~initial_draft:(draft "draft-one")
    ~title:"first task"

let one_active_draft_and_checkpoints () =
  let project = initial_project () in
  let project = V4.checkpoint project ~snapshot:(snapshot "snapshot-edit") in
  Alcotest.(check string)
    "checkpoint belongs to active draft" "snapshot-edit"
    (V4.active_draft project |> fun active ->
     V4.Snapshot_id.to_string active.V4.latest_checkpoint);
  let project = V4.new_draft project ~id:(draft "draft-two") ~title:"second task" |> require_ok in
  Alcotest.(check string)
    "new draft is active" "draft-two"
    (V4.active_draft project |> fun active -> V4.Draft_id.to_string active.V4.id);
  let previous =
    V4.drafts project
    |> List.find (fun candidate -> V4.Draft_id.equal candidate.V4.id (draft "draft-one"))
  in
  Alcotest.(check bool) "previous draft is closed" true
    (match previous.V4.state with V4.Closed -> true | V4.Active -> false)

let sharing_requires_a_linear_revision_chain () =
  let base = snapshot "snapshot-base" in
  let project = initial_project () in
  let first =
    revision_record ~change_id:(change "change-a") ~revision_id:(revision "revision-a1")
      ~author:(device "device-alice") ~base ~result:(snapshot "snapshot-a1")
      [ text_edit [ "main.ml" ] 0 4 ]
  in
  let project = V4.share_active project first |> require_ok in
  let wrong_parent =
    revision_record ~parent:(revision "revision-other") ~change_id:(change "change-a")
      ~revision_id:(revision "revision-a2") ~author:(device "device-alice")
      ~base ~result:(snapshot "snapshot-a2") [ text_edit [ "main.ml" ] 8 12 ]
  in
  (match V4.amend_active project wrong_parent with
  | Error V4.Revision_parent_mismatch -> ()
  | Error error -> Alcotest.fail (V4.error_to_string error)
  | Ok _ -> Alcotest.fail "accepted a non-linear active revision");
  let second =
    revision_record ~parent:(revision "revision-a1") ~change_id:(change "change-a")
      ~revision_id:(revision "revision-a2") ~author:(device "device-alice")
      ~base ~result:(snapshot "snapshot-a2") [ text_edit [ "main.ml" ] 8 12 ]
  in
  let project = V4.amend_active project second |> require_ok in
  let shared = List.hd (V4.shared_changes project) in
  Alcotest.(check int) "two immutable revisions retained" 2
    (List.length shared.V4.revisions)

let disjoint_revisions_compose_in_a_stable_order () =
  let base = snapshot "snapshot-base" in
  let remote change_id revision_id file =
    revision_record ~change_id:(change change_id) ~revision_id:(revision revision_id)
      ~author:(device "device-bob") ~base ~result:(snapshot ("snapshot-" ^ revision_id))
      [ text_edit [ file ] 0 2 ]
  in
  let alpha = remote "change-alpha" "revision-alpha" "alpha.ml" in
  let beta = remote "change-beta" "revision-beta" "beta.ml" in
  let apply revisions =
    List.fold_left
      (fun project incoming -> V4.receive project incoming |> require_ok)
      (initial_project ()) revisions
    |> V4.projection
  in
  let left = apply [ alpha; beta ] in
  let right = apply [ beta; alpha ] in
  let ids projection =
    List.map (fun revision -> V4.Revision_id.to_string revision.V4.revision) projection.V4.applied
  in
  Alcotest.(check (list string)) "canonical change order" (ids left) (ids right);
  Alcotest.(check int) "no decision for disjoint paths" 0 (List.length left.V4.decisions)

let overlap_is_a_decision_without_mutating_the_active_draft () =
  let base = snapshot "snapshot-base" in
  let local =
    revision_record ~change_id:(change "change-alpha") ~revision_id:(revision "revision-alpha")
      ~author:(device "device-bob") ~base ~result:(snapshot "snapshot-alpha")
      [ text_edit [ "same.ml" ] 0 4 ]
  in
  let conflicting =
    revision_record ~change_id:(change "change-beta") ~revision_id:(revision "revision-beta")
      ~author:(device "device-carol") ~base ~result:(snapshot "snapshot-beta")
      [ text_edit [ "same.ml" ] 2 6 ]
  in
  let independent =
    revision_record ~change_id:(change "change-gamma") ~revision_id:(revision "revision-gamma")
      ~author:(device "device-dan") ~base ~result:(snapshot "snapshot-gamma")
      [ text_edit [ "other.ml" ] 0 3 ]
  in
  let project =
    initial_project ()
    |> fun project -> V4.receive project local |> require_ok
    |> fun project -> V4.receive project conflicting |> require_ok
    |> fun project -> V4.receive project independent |> require_ok
  in
  let projection = V4.projection project in
  Alcotest.(check int) "one durable decision" 1 (List.length projection.V4.decisions);
  Alcotest.(check int) "independent work still composes" 2 (List.length projection.V4.applied);
  Alcotest.(check string)
    "active draft remains on its local checkpoint" "snapshot-base"
    (V4.active_draft project |> fun active ->
     V4.Snapshot_id.to_string active.V4.latest_checkpoint)

let withdrawal_never_erases_the_active_shared_change () =
  let base = snapshot "snapshot-base" in
  let project = initial_project () in
  let shared =
    revision_record ~change_id:(change "change-a") ~revision_id:(revision "revision-a")
      ~author:(device "device-alice") ~base ~result:(snapshot "snapshot-a")
      [ text_edit [ "a.ml" ] 0 1 ]
  in
  let project = V4.share_active project shared |> require_ok in
  (match V4.withdraw project ~change:(change "change-a") with
  | Error V4.Active_change_withdrawal -> ()
  | Error error -> Alcotest.fail (V4.error_to_string error)
  | Ok _ -> Alcotest.fail "withdrew the active shared change");
  let project = V4.new_draft project ~id:(draft "draft-two") ~title:"follow-up" |> require_ok in
  let project = V4.withdraw project ~change:(change "change-a") |> require_ok in
  Alcotest.(check int) "withdrawn change leaves the projection" 0
    (V4.projection project |> fun projection -> List.length projection.V4.applied)

let manual_delivery_requires_a_decision_free_shared_active_draft () =
  let base = snapshot "snapshot-base" in
  let project = initial_project () in
  let shared =
    revision_record ~change_id:(change "change-a") ~revision_id:(revision "revision-a")
      ~author:(device "device-alice") ~base ~result:(snapshot "snapshot-a")
      [ text_edit [ "a.ml" ] 0 1 ]
  in
  let project = V4.share_active project shared |> require_ok in
  let project =
    V4.deliver project ~id:(delivery "delivery-one") ~author:(device "device-alice")
      ~snapshot:(snapshot "snapshot-delivered") ~included:[ revision "revision-a" ]
      ~next_draft:(draft "draft-after-delivery") ~next_title:"after delivery"
      ~created_at:1L
    |> require_ok
  in
  Alcotest.(check string) "delivery becomes the new baseline" "snapshot-delivered"
    (V4.projection project |> fun projection -> V4.Snapshot_id.to_string projection.V4.baseline);
  Alcotest.(check int) "delivery is inspectable" 1 (List.length (V4.deliveries project));
  Alcotest.(check string) "delivery starts a new active draft" "draft-after-delivery"
    (V4.active_draft project |> fun active -> V4.Draft_id.to_string active.V4.id)

let () =
  Alcotest.run "V4 model"
    [
      ( "drafts",
        [
          Alcotest.test_case "one active draft and checkpoints" `Quick
            one_active_draft_and_checkpoints;
          Alcotest.test_case "sharing requires linear revisions" `Quick
            sharing_requires_a_linear_revision_chain;
        ] );
      ( "projection",
        [
          Alcotest.test_case "disjoint revisions compose in stable order" `Quick
            disjoint_revisions_compose_in_a_stable_order;
          Alcotest.test_case "overlap creates a decision without local mutation" `Quick
            overlap_is_a_decision_without_mutating_the_active_draft;
          Alcotest.test_case "withdrawal protects the active shared change" `Quick
            withdrawal_never_erases_the_active_shared_change;
        ] );
      ( "delivery",
        [
          Alcotest.test_case "manual delivery has a shared decision-free input" `Quick
            manual_delivery_requires_a_decision_free_shared_active_draft;
        ] );
    ]
