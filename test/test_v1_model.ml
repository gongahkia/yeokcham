module V1 = Yeokcham_v1_model

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (V1.error_to_string error)

let snapshot value = V1.Snapshot_id.of_string value |> require_ok
let draft value = V1.Draft_id.of_string value |> require_ok
let change value = V1.Change_id.of_string value |> require_ok
let revision value = V1.Revision_id.of_string value |> require_ok
let delivery value = V1.Delivery_id.of_string value |> require_ok
let device value = V1.Device_id.of_string value |> require_ok
let username value = V1.Username.of_string value |> require_ok
let path components = V1.Path.of_components components |> require_ok

let text_edit components start_byte end_byte =
  let span = V1.make_span ~start_byte ~end_byte |> require_ok in
  V1.{ edit_path = path components; edit_kind = Text span }

let revision_record ?parent ~change_id ~revision_id ~author ~base ~result edits
    =
  V1.make_change_revision ~change:change_id ~revision:revision_id ~parent
    ~author ~base ~result ~edits
  |> require_ok

let initial_project () =
  let creator = device "device-alice" in
  let base = snapshot "snapshot-base" in
  V1.init ~creator ~username:(username "alice") ~initial_snapshot:base
    ~initial_draft:(draft "draft-one") ~title:"first task"

let one_active_draft_and_checkpoints () =
  let project = initial_project () in
  let project = V1.checkpoint project ~snapshot:(snapshot "snapshot-edit") in
  Alcotest.(check string)
    "checkpoint belongs to active draft" "snapshot-edit"
    ( V1.active_draft project |> fun active ->
      V1.Snapshot_id.to_string active.V1.latest_checkpoint );
  Alcotest.(check (list string))
    "saved checkpoints retain newest-first recovery history"
    [ "snapshot-edit"; "snapshot-base" ]
    (V1.checkpoints project
    |> List.map (fun checkpoint ->
        V1.Snapshot_id.to_string checkpoint.V1.checkpoint_snapshot));
  let project =
    V1.new_draft project ~id:(draft "draft-two") ~title:"second task"
    |> require_ok
  in
  Alcotest.(check string)
    "new draft is active" "draft-two"
    ( V1.active_draft project |> fun active ->
      V1.Draft_id.to_string active.V1.draft_id );
  let previous =
    V1.drafts project
    |> List.find (fun candidate ->
        V1.Draft_id.equal candidate.V1.draft_id (draft "draft-one"))
  in
  Alcotest.(check bool)
    "previous draft is closed" true
    (match previous.V1.state with V1.Closed -> true | V1.Active -> false)

let sharing_requires_a_linear_revision_chain () =
  let base = snapshot "snapshot-base" in
  let project = initial_project () in
  let first =
    revision_record ~change_id:(change "change-a")
      ~revision_id:(revision "revision-a1") ~author:(device "device-alice")
      ~base ~result:(snapshot "snapshot-a1")
      [ text_edit [ "main.ml" ] 0 4 ]
  in
  let project = V1.share_active project first |> require_ok in
  let wrong_parent =
    revision_record
      ~parent:(revision "revision-other")
      ~change_id:(change "change-a") ~revision_id:(revision "revision-a2")
      ~author:(device "device-alice") ~base ~result:(snapshot "snapshot-a2")
      [ text_edit [ "main.ml" ] 8 12 ]
  in
  (match V1.amend_active project wrong_parent with
  | Error error ->
      Alcotest.(check string)
        "non-linear active revision is rejected"
        "revision parent is not the current revision" (V1.error_to_string error)
  | Ok _ -> Alcotest.fail "accepted a non-linear active revision");
  let second =
    revision_record ~parent:(revision "revision-a1")
      ~change_id:(change "change-a") ~revision_id:(revision "revision-a2")
      ~author:(device "device-alice") ~base ~result:(snapshot "snapshot-a2")
      [ text_edit [ "main.ml" ] 8 12 ]
  in
  let project = V1.amend_active project second |> require_ok in
  let shared = List.hd (V1.shared_changes project) in
  Alcotest.(check int)
    "two immutable revisions retained" 2
    (List.length shared.V1.revisions)

let disjoint_revisions_compose_in_a_stable_order () =
  let base = snapshot "snapshot-base" in
  let remote change_id revision_id file =
    revision_record ~change_id:(change change_id)
      ~revision_id:(revision revision_id) ~author:(device "device-bob") ~base
      ~result:(snapshot ("snapshot-" ^ revision_id))
      [ text_edit [ file ] 0 2 ]
  in
  let alpha = remote "change-alpha" "revision-alpha" "alpha.ml" in
  let beta = remote "change-beta" "revision-beta" "beta.ml" in
  let apply revisions =
    List.fold_left
      (fun project incoming -> V1.receive project incoming |> require_ok)
      (initial_project ()) revisions
    |> V1.projection
  in
  let left = apply [ alpha; beta ] in
  let right = apply [ beta; alpha ] in
  let ids projection =
    List.map
      (fun revision -> V1.Revision_id.to_string revision.V1.revision)
      projection.V1.applied
  in
  Alcotest.(check (list string)) "canonical change order" (ids left) (ids right);
  Alcotest.(check int)
    "no decision for disjoint paths" 0
    (List.length left.V1.decisions)

let overlap_is_a_decision_without_mutating_the_active_draft () =
  let base = snapshot "snapshot-base" in
  let local =
    revision_record ~change_id:(change "change-alpha")
      ~revision_id:(revision "revision-alpha")
      ~author:(device "device-bob") ~base
      ~result:(snapshot "snapshot-alpha")
      [ text_edit [ "same.ml" ] 0 4 ]
  in
  let conflicting =
    revision_record ~change_id:(change "change-beta")
      ~revision_id:(revision "revision-beta") ~author:(device "device-carol")
      ~base ~result:(snapshot "snapshot-beta")
      [ text_edit [ "same.ml" ] 2 6 ]
  in
  let independent =
    revision_record ~change_id:(change "change-gamma")
      ~revision_id:(revision "revision-gamma")
      ~author:(device "device-dan") ~base
      ~result:(snapshot "snapshot-gamma")
      [ text_edit [ "other.ml" ] 0 3 ]
  in
  let project =
    initial_project () |> fun project ->
    V1.receive project local |> require_ok |> fun project ->
    V1.receive project conflicting |> require_ok |> fun project ->
    V1.receive project independent |> require_ok
  in
  let projection = V1.projection project in
  Alcotest.(check int)
    "one durable decision" 1
    (List.length projection.V1.decisions);
  Alcotest.(check int)
    "only independent work composes without choosing a conflict" 1
    (List.length projection.V1.applied);
  Alcotest.(check string)
    "active draft remains on its local checkpoint" "snapshot-base"
    ( V1.active_draft project |> fun active ->
      V1.Snapshot_id.to_string active.V1.latest_checkpoint )

let an_independent_edit_inside_a_conflicting_revision_still_composes () =
  let base = snapshot "snapshot-base" in
  let mixed =
    revision_record ~change_id:(change "change-alpha")
      ~revision_id:(revision "revision-alpha")
      ~author:(device "device-bob") ~base
      ~result:(snapshot "snapshot-alpha")
      [ text_edit [ "same.ml" ] 0 4; text_edit [ "other.ml" ] 0 4 ]
  in
  let conflicting =
    revision_record ~change_id:(change "change-beta")
      ~revision_id:(revision "revision-beta") ~author:(device "device-carol")
      ~base ~result:(snapshot "snapshot-beta")
      [ text_edit [ "same.ml" ] 2 6 ]
  in
  let project =
    initial_project () |> fun project ->
    V1.receive project mixed |> require_ok |> fun project ->
    V1.receive project conflicting |> require_ok
  in
  let projection = V1.projection project in
  Alcotest.(check int)
    "the overlapping edit is a decision" 1
    (List.length projection.V1.decisions);
  Alcotest.(check int)
    "the disjoint edit remains available" 1
    (List.length projection.V1.applied_edits);
  Alcotest.(check (list string))
    "the contributing revision remains inspectable" [ "revision-alpha" ]
    (List.map
       (fun revision -> V1.Revision_id.to_string revision.V1.revision)
       projection.V1.applied)

let resolution_replaces_only_the_decided_alternatives () =
  let base = snapshot "snapshot-base" in
  let local =
    revision_record ~change_id:(change "change-alpha")
      ~revision_id:(revision "revision-alpha")
      ~author:(device "device-bob") ~base
      ~result:(snapshot "snapshot-alpha")
      [ text_edit [ "same.ml" ] 0 4 ]
  in
  let conflicting =
    revision_record ~change_id:(change "change-beta")
      ~revision_id:(revision "revision-beta") ~author:(device "device-carol")
      ~base ~result:(snapshot "snapshot-beta")
      [ text_edit [ "same.ml" ] 2 6 ]
  in
  let project =
    initial_project () |> fun project ->
    V1.receive project local |> require_ok |> fun project ->
    V1.receive project conflicting |> require_ok
  in
  let decision = List.hd (V1.projection project).V1.decisions in
  let replacement =
    revision_record
      ~change_id:(change "change-resolution")
      ~revision_id:(revision "revision-resolution")
      ~author:(device "device-alice") ~base
      ~result:(snapshot "snapshot-resolution")
      [ text_edit [ "same.ml" ] 0 6 ]
  in
  let project =
    V1.resolve project ~decision:decision.V1.decision_id ~replacement
    |> require_ok
  in
  let projection = V1.projection project in
  Alcotest.(check int)
    "resolution removes the open decision" 0
    (List.length projection.V1.decisions);
  Alcotest.(check (list string))
    "resolution is the visible replacement" [ "revision-resolution" ]
    (List.map
       (fun revision -> V1.Revision_id.to_string revision.V1.revision)
       projection.V1.applied);
  Alcotest.(check int)
    "resolution remains inspectable" 1
    (List.length (V1.resolutions project))

let withdrawal_never_erases_the_active_shared_change () =
  let base = snapshot "snapshot-base" in
  let project = initial_project () in
  let shared =
    revision_record ~change_id:(change "change-a")
      ~revision_id:(revision "revision-a") ~author:(device "device-alice") ~base
      ~result:(snapshot "snapshot-a")
      [ text_edit [ "a.ml" ] 0 1 ]
  in
  let project = V1.share_active project shared |> require_ok in
  (match V1.withdraw project ~change:(change "change-a") with
  | Error error ->
      Alcotest.(check string)
        "active shared change cannot be withdrawn"
        "close the active draft before withdrawing its shared change"
        (V1.error_to_string error)
  | Ok _ -> Alcotest.fail "withdrew the active shared change");
  let project =
    V1.new_draft project ~id:(draft "draft-two") ~title:"follow-up"
    |> require_ok
  in
  let project = V1.withdraw project ~change:(change "change-a") |> require_ok in
  Alcotest.(check int)
    "withdrawn change leaves the projection" 0
    ( V1.projection project |> fun projection ->
      List.length projection.V1.applied )

let manual_delivery_requires_a_decision_free_shared_active_draft () =
  let base = snapshot "snapshot-base" in
  let project = initial_project () in
  let shared =
    revision_record ~change_id:(change "change-a")
      ~revision_id:(revision "revision-a") ~author:(device "device-alice") ~base
      ~result:(snapshot "snapshot-a")
      [ text_edit [ "a.ml" ] 0 1 ]
  in
  let project = V1.share_active project shared |> require_ok in
  let project =
    V1.deliver project ~id:(delivery "delivery-one")
      ~author:(device "device-alice")
      ~snapshot:(snapshot "snapshot-delivered")
      ~included:[ revision "revision-a" ]
      ~next_draft:(draft "draft-after-delivery")
      ~next_title:"after delivery" ~created_at:1L
    |> require_ok
  in
  Alcotest.(check string)
    "delivery becomes the new baseline" "snapshot-delivered"
    ( V1.projection project |> fun projection ->
      V1.Snapshot_id.to_string projection.V1.projection_baseline );
  Alcotest.(check int)
    "delivery is inspectable" 1
    (List.length (V1.deliveries project));
  Alcotest.(check string)
    "delivery starts a new active draft" "draft-after-delivery"
    ( V1.active_draft project |> fun active ->
      V1.Draft_id.to_string active.V1.draft_id )

let delivery_consumes_resolved_changes_and_advances_the_baseline () =
  let base = snapshot "snapshot-base" in
  let local =
    revision_record ~change_id:(change "change-alpha")
      ~revision_id:(revision "revision-alpha")
      ~author:(device "device-alice") ~base
      ~result:(snapshot "snapshot-alpha")
      [ text_edit [ "same.ml" ] 0 4 ]
  in
  let conflicting =
    revision_record ~change_id:(change "change-beta")
      ~revision_id:(revision "revision-beta") ~author:(device "device-carol")
      ~base ~result:(snapshot "snapshot-beta")
      [ text_edit [ "same.ml" ] 2 6 ]
  in
  let project =
    initial_project () |> fun project ->
    V1.share_active project local |> require_ok |> fun project ->
    V1.receive project conflicting |> require_ok
  in
  let decision = List.hd (V1.projection project).V1.decisions in
  let replacement =
    revision_record
      ~change_id:(change "change-resolution")
      ~revision_id:(revision "revision-resolution")
      ~author:(device "device-alice") ~base
      ~result:(snapshot "snapshot-resolution")
      [ text_edit [ "same.ml" ] 0 6 ]
  in
  let project =
    V1.resolve project ~decision:decision.V1.decision_id ~replacement
    |> require_ok
  in
  let project =
    V1.deliver project
      ~id:(delivery "delivery-resolved")
      ~author:(device "device-alice")
      ~snapshot:(snapshot "snapshot-delivered")
      ~included:[ revision "revision-resolution" ]
      ~next_draft:(draft "draft-after-resolution")
      ~next_title:"after resolution" ~created_at:2L
    |> require_ok
  in
  Alcotest.(check int)
    "delivery drops consumed shared changes" 0
    (List.length (V1.shared_changes project));
  Alcotest.(check int)
    "delivery drops resolutions bound to the previous baseline" 0
    (List.length (V1.resolutions project));
  Alcotest.(check int)
    "new baseline is decision-free" 0
    (List.length (V1.projection project).V1.decisions)

let compact_drops_unprotected_checkpoints_and_keeps_named_roots () =
  let project = initial_project () in
  let first =
    revision_record ~change_id:(change "change-a")
      ~revision_id:(revision "revision-a1") ~author:(device "device-alice")
      ~base:(snapshot "snapshot-base") ~result:(snapshot "snapshot-a1")
      [ text_edit [ "main.ml" ] 0 4 ]
  in
  let project = V1.share_active project first |> require_ok in
  let project =
    V1.checkpoint project ~snapshot:(snapshot "snapshot-scratch-1")
  in
  let project =
    V1.checkpoint project ~snapshot:(snapshot "snapshot-scratch-2")
  in
  let project =
    V1.checkpoint project ~snapshot:(snapshot "snapshot-scratch-3")
  in
  let project =
    V1.pin project ~snapshot:(snapshot "snapshot-scratch-2") |> require_ok
  in
  let compacted =
    V1.compact project ~keep_recent:0 ~journal_snapshots:[] ~proof_snapshots:[]
    |> require_ok
  in
  let retained =
    compacted.V1.project |> V1.checkpoints
    |> List.map (fun checkpoint ->
        V1.Snapshot_id.to_string checkpoint.V1.checkpoint_snapshot)
  in
  Alcotest.(check (list string))
    "named roots stay and extra scratch drops"
    [
      "snapshot-scratch-3"; "snapshot-scratch-2"; "snapshot-a1"; "snapshot-base";
    ]
    retained;
  Alcotest.(check (list string))
    "only unprotected scratch is dropped" [ "snapshot-scratch-1" ]
    (List.map V1.Snapshot_id.to_string compacted.V1.dropped);
  let protected_journal =
    V1.compact project ~keep_recent:0
      ~journal_snapshots:[ snapshot "snapshot-scratch-1" ]
      ~proof_snapshots:[]
    |> require_ok
  in
  Alcotest.(check int)
    "pending restore-safety is not dropped" 0
    (List.length protected_journal.V1.dropped);
  let protected_proof =
    V1.compact project ~keep_recent:0 ~journal_snapshots:[]
      ~proof_snapshots:[ snapshot "snapshot-scratch-1" ]
    |> require_ok
  in
  Alcotest.(check int)
    "durable restore-proof is not dropped" 0
    (List.length protected_proof.V1.dropped)

let pin_rejects_unknown_checkpoints () =
  match V1.pin (initial_project ()) ~snapshot:(snapshot "snapshot-missing") with
  | Ok _ -> Alcotest.fail "pinned a checkpoint that is not retained"
  | Error error ->
      Alcotest.(check string)
        "unknown checkpoint"
        (V1.error_to_string V1.Unknown_checkpoint)
        (V1.error_to_string error)

let username_registrations_are_unique_local_display_metadata () =
  let project = initial_project () in
  Alcotest.(check string)
    "the creator receives the requested local display handle" "alice"
    (V1.username_for_device project ~device:(device "device-alice")
    |> Option.map V1.Username.to_string
    |> Option.value ~default:"missing");
  let project =
    V1.register_username project ~device:(device "device-bob")
      ~username:(username "bob")
    |> require_ok
  in
  (match
     V1.register_username project ~device:(device "device-carol")
       ~username:(username "bob")
   with
  | Error error ->
      Alcotest.(check string)
        "a username cannot name two devices"
        "username is already registered to a device" (V1.error_to_string error)
  | Ok _ -> Alcotest.fail "registered one local username to two devices");
  let project =
    V1.register_username project ~device:(device "device-bob")
      ~username:(username "robert")
    |> require_ok
  in
  Alcotest.(check string)
    "a device can correct its local display handle" "robert"
    (V1.username_for_device project ~device:(device "device-bob")
    |> Option.map V1.Username.to_string
    |> Option.value ~default:"missing");
  match V1.Username.of_string "Alice" with
  | Error error ->
      Alcotest.(check string)
        "unsafe username is rejected" "invalid username: Alice"
        (V1.error_to_string error)
  | Ok _ -> Alcotest.fail "accepted an unsafe username"

let () =
  Alcotest.run "V1 model"
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
          Alcotest.test_case "overlap creates a decision without local mutation"
            `Quick overlap_is_a_decision_without_mutating_the_active_draft;
          Alcotest.test_case
            "an independent edit survives another edit's conflict" `Quick
            an_independent_edit_inside_a_conflicting_revision_still_composes;
          Alcotest.test_case "resolution replaces decided alternatives" `Quick
            resolution_replaces_only_the_decided_alternatives;
          Alcotest.test_case "withdrawal protects the active shared change"
            `Quick withdrawal_never_erases_the_active_shared_change;
        ] );
      ( "delivery",
        [
          Alcotest.test_case "manual delivery has a shared decision-free input"
            `Quick manual_delivery_requires_a_decision_free_shared_active_draft;
          Alcotest.test_case "delivery consumes resolved overlapping changes"
            `Quick delivery_consumes_resolved_changes_and_advances_the_baseline;
        ] );
      ( "compaction",
        [
          Alcotest.test_case "named roots stay and extra scratch drops" `Quick
            compact_drops_unprotected_checkpoints_and_keeps_named_roots;
          Alcotest.test_case "pin rejects unknown checkpoints" `Quick
            pin_rejects_unknown_checkpoints;
        ] );
      ( "local display metadata",
        [
          Alcotest.test_case "username registrations are unique and editable"
            `Quick username_registrations_are_unique_local_display_metadata;
        ] );
    ]
