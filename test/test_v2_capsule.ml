module Capsule = Yeokcham_v2_capsule
module Model = Yeokcham_model
module V2_model = Yeokcham_v2_model

let default_seed = 20_260_810

let base_seed =
  match Sys.getenv_opt "PROPERTY_TEST_SEED" with
  | None -> default_seed
  | Some value -> Option.value (int_of_string_opt value) ~default:default_seed

let stable_seed name =
  let value = ref base_seed in
  String.iter
    (fun character ->
      value := !value * 65599 lxor Char.code character land max_int)
    name;
  !value

let state_for name = Random.State.make [| stable_seed name |]
let () = Printf.printf "v2 capsule property base seed: %d\n%!" base_seed

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let path components =
  Model.Path.of_components components |> require_ok Model.Path.error_to_string

let file ?(mode = Model.Regular) components content =
  Model.File_path (path components, { Model.mode; content })

let directory components = Model.Directory_path (path components)
let empty_directory_path = path [ "empty" ]
let new_child_path = path [ "new"; "child" ]

let snapshot entries =
  Model.Snapshot.of_entries entries
  |> require_ok Model.construction_error_to_string

let source_snapshot () =
  snapshot
    [
      file [ "change" ] "before";
      file [ "removed" ] "remove me";
      file [ "turn" ] "file becomes directory";
      directory [ "stable" ];
      file [ "stable"; "same" ] "unchanged";
    ]

let target_snapshot ?(content = "after") ?(mode = Model.Executable) () =
  snapshot
    [
      file ~mode [ "change" ] content;
      directory [ "empty" ];
      directory [ "new" ];
      file [ "new"; "child" ] "created";
      directory [ "turn" ];
      file [ "turn"; "child" ] "now nested";
      directory [ "stable" ];
      file [ "stable"; "same" ] "unchanged";
    ]

let opaque character =
  V2_model.Opaque_object_ref.of_bytes (String.make 32 character)
  |> require_ok V2_model.identity_error_to_string

let capsule_id character =
  V2_model.Capsule_id.of_bytes (String.make 32 character)
  |> require_ok V2_model.identity_error_to_string

let link snapshot character =
  {
    Capsule.snapshot_id = Model.Snapshot.id snapshot;
    snapshot_ref = opaque character;
  }

let exact_proposal_replays_without_intent_claims () =
  let source = source_snapshot () in
  let target = target_snapshot () in
  let proposal =
    Capsule.propose ~from:source ~to_:target
    |> require_ok Capsule.proposal_error_to_string
  in
  let operations = Capsule.proposal_operations proposal in
  Alcotest.(check bool)
    "proposal includes explicit empty-directory creation" true
    (List.exists
       (function
         | Model.Create_directory { path } ->
             Model.Path.equal path empty_directory_path
         | Model.Create_file _ | Model.Modify_file _ | Model.Delete_path _
         | Model.Move_path _ | Model.Change_mode _ ->
             false)
       operations);
  Alcotest.(check bool)
    "proposal does not infer moves" false
    (List.exists
       (function
         | Model.Move_path _ -> true
         | Model.Create_file _ | Model.Create_directory _ | Model.Modify_file _
         | Model.Delete_path _ | Model.Change_mode _ ->
             false)
       operations);
  Model.Snapshot.apply_operations source operations
  |> require_ok Model.replay_error_to_string
  |> fun actual ->
  Alcotest.(check bool)
    "proposal replays exact bytes, modes, and directories" true
    (Model.Snapshot.equal target actual)

let dependent_subset_is_an_explicit_conflict () =
  let source = source_snapshot () in
  let target = target_snapshot () in
  let proposal =
    Capsule.propose ~from:source ~to_:target
    |> require_ok Capsule.proposal_error_to_string
  in
  let child_index =
    Capsule.proposal_operations proposal
    |> List.find_index (function
      | Model.Create_file { path; _ } -> Model.Path.equal path new_child_path
      | Model.Create_directory _ | Model.Modify_file _ | Model.Delete_path _
      | Model.Move_path _ | Model.Change_mode _ ->
          false)
    |> Option.get
  in
  (match Capsule.select proposal ~indices:[ child_index ] with
  | Error (Capsule.Selected_operation_rejected { proposal_index; _ }) ->
      Alcotest.(check int)
        "conflict names original proposal operation" child_index proposal_index
  | Error Capsule.Empty_selection
  | Error (Capsule.Unsorted_selection _)
  | Error (Capsule.Selection_index_out_of_bounds _) ->
      Alcotest.fail "dependent selection returned a selection-shape error"
  | Ok _ -> Alcotest.fail "dependent subset unexpectedly replayed")
  [@warning "-4"]

let canonical_initial_records_round_trip () =
  let source = source_snapshot () in
  let target = target_snapshot () in
  let proposal =
    Capsule.propose ~from:source ~to_:target
    |> require_ok Capsule.proposal_error_to_string
  in
  let indices =
    Capsule.proposal_operations proposal |> List.mapi (fun index _ -> index)
  in
  let selected =
    Capsule.select proposal ~indices
    |> require_ok Capsule.selection_error_to_string
  in
  let capsule =
    Capsule.make_capsule ~id:(capsule_id 'c') ~title:"exact curation"
      ~description:"bytes only" ~created_at:17L
    |> require_ok Capsule.error_to_string
  in
  let source_link = link source 's' in
  let target_link = link target 't' in
  let boundary =
    { Capsule.source_snapshot = source_link; target_snapshot = target_link }
  in
  let revision =
    Capsule.make_initial_revision ~capsule ~capsule_ref:(opaque 'c')
      ~declared_base:source_link ~declared_base_snapshot:source
      ~expected_result:target_link ~selected ~source_boundary:boundary
    |> require_ok Capsule.error_to_string
  in
  let decoded_capsule =
    Capsule.decode_capsule (Capsule.encode_capsule capsule)
    |> require_ok Capsule.error_to_string
  in
  let decoded_revision =
    Capsule.decode_revision (Capsule.encode_revision revision)
    |> require_ok Capsule.error_to_string
  in
  Alcotest.(check string)
    "capsule canonical round trip"
    (Capsule.encode_capsule capsule)
    (Capsule.encode_capsule decoded_capsule);
  Alcotest.(check string)
    "revision canonical round trip"
    (Capsule.encode_revision revision)
    (Capsule.encode_revision decoded_revision);
  Capsule.apply_revision ~base:source decoded_revision
  |> require_ok Model.replay_error_to_string
  |> fun actual ->
  Alcotest.(check bool)
    "initial revision reaches declared exact result" true
    (Model.Snapshot.equal target actual)

let immutable_child_revision_replays_and_round_trips () =
  let source = source_snapshot () in
  let target = target_snapshot () in
  let later = target_snapshot ~content:"later" ~mode:Model.Regular () in
  let initial_proposal =
    Capsule.propose ~from:source ~to_:target
    |> require_ok Capsule.proposal_error_to_string
  in
  let initial_selection =
    Capsule.select initial_proposal
      ~indices:
        (Capsule.proposal_operations initial_proposal
        |> List.mapi (fun i _ -> i))
    |> require_ok Capsule.selection_error_to_string
  in
  let capsule =
    Capsule.make_capsule ~id:(capsule_id 'i') ~title:"exact curation"
      ~description:"bytes only" ~created_at:17L
    |> require_ok Capsule.error_to_string
  in
  let source_link = link source 's' in
  let target_link = link target 't' in
  let initial_boundary =
    { Capsule.source_snapshot = source_link; target_snapshot = target_link }
  in
  let initial =
    Capsule.make_initial_revision ~capsule ~capsule_ref:(opaque 'i')
      ~declared_base:source_link ~declared_base_snapshot:source
      ~expected_result:target_link ~selected:initial_selection
      ~source_boundary:initial_boundary
    |> require_ok Capsule.error_to_string
  in
  let complete =
    Capsule.propose ~from:source ~to_:later
    |> require_ok Capsule.proposal_error_to_string
  in
  let later_link = link later 'l' in
  let parent =
    Capsule.make_revision_link
      ~capsule_id:(Capsule.capsule_id capsule)
      ~revision_id:(Capsule.revision_id initial)
      ~revision_ref:(opaque 'r')
  in
  let child =
    Capsule.make_revision ~capsule ~capsule_ref:(opaque 'i')
      ~parent:(Some parent) ~declared_base:source_link
      ~declared_base_snapshot:source ~expected_result:later_link
      ~operations:(Capsule.proposal_operations complete)
      ~source_boundaries:
        [
          initial_boundary;
          {
            Capsule.source_snapshot = target_link;
            target_snapshot = later_link;
          };
        ]
      ~provenance:(Capsule.Folded parent) ~created_at:18L
    |> require_ok Capsule.error_to_string
  in
  let plan =
    Capsule.plan_split ~base:source child ~left_indices:[ 0 ]
    |> require_ok Capsule.split_error_to_string
  in
  Capsule.split_plan_right_operations plan
  |> Model.Snapshot.apply_operations (Capsule.split_plan_left_result plan)
  |> require_ok Model.replay_error_to_string
  |> fun actual ->
  Alcotest.(check bool)
    "read-only split partition composes to the original result" true
    (Model.Snapshot.equal later actual);
  let adjacent_delta =
    Capsule.propose ~from:target ~to_:later
    |> require_ok Capsule.proposal_error_to_string
  in
  let adjacent =
    Capsule.make_revision ~capsule ~capsule_ref:(opaque 'i')
      ~parent:(Some parent) ~declared_base:target_link
      ~declared_base_snapshot:target ~expected_result:later_link
      ~operations:(Capsule.proposal_operations adjacent_delta)
      ~source_boundaries:
        [
          {
            Capsule.source_snapshot = target_link;
            target_snapshot = later_link;
          };
        ]
      ~provenance:(Capsule.Folded parent) ~created_at:18L
    |> require_ok Capsule.error_to_string
  in
  let combined =
    Capsule.plan_combine ~base:source [ initial; adjacent ]
    |> require_ok Capsule.combine_error_to_string
  in
  Alcotest.(check bool)
    "read-only combine preserves caller source order" true
    (Model.Snapshot.equal later (Capsule.combine_plan_result combined));
  let decoded =
    Capsule.decode_revision (Capsule.encode_revision child)
    |> require_ok Capsule.error_to_string
  in
  Alcotest.(check string)
    "child revision v2 canonical round trip"
    (Capsule.encode_revision child)
    (Capsule.encode_revision decoded);
  Alcotest.(check bool)
    "child retains its immutable parent" true
    (match Capsule.revision_parent decoded with
    | Some link ->
        V2_model.Capsule_revision_id.equal
          (Capsule.revision_link_revision_id link)
          (Capsule.revision_id initial)
    | None -> false);
  Capsule.apply_revision ~base:source decoded
  |> require_ok Model.replay_error_to_string
  |> fun actual ->
  Alcotest.(check bool)
    "child directly reaches its declared exact result" true
    (Model.Snapshot.equal later actual)

let generated_exact_proposals_replay =
  QCheck2.Test.make ~count:120
    ~name:"V2 structural capsule proposals replay generated bytes and modes"
    QCheck2.Gen.(pair (string_size (int_range 0 4096)) bool)
    (fun (content, executable) ->
      let source = source_snapshot () in
      let mode = if executable then Model.Executable else Model.Regular in
      let target = target_snapshot ~content ~mode () in
      match Capsule.propose ~from:source ~to_:target with
      | Error _ -> false
      | Ok proposal -> (
          match
            Model.Snapshot.apply_operations source
              (Capsule.proposal_operations proposal)
          with
          | Ok actual -> Model.Snapshot.equal target actual
          | Error _ -> false))

let () =
  Alcotest.run "V2 exact capsule curation"
    [
      ( "unit",
        [
          Alcotest.test_case "exact proposal replays without inferred intent"
            `Quick exact_proposal_replays_without_intent_claims;
          Alcotest.test_case "dependent subset is explicit conflict" `Quick
            dependent_subset_is_an_explicit_conflict;
          Alcotest.test_case "canonical initial records round trip" `Quick
            canonical_initial_records_round_trip;
          Alcotest.test_case "immutable child revision replays and round trips"
            `Quick immutable_child_revision_replays_and_round_trips;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "exact-proposal-replay")
            generated_exact_proposals_replay;
        ] );
    ]
