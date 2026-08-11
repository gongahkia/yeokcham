module Capsule = Yeokcham_v2_capsule
module Model = Yeokcham_model
module V2_model = Yeokcham_v2_model
module Workspace = Yeokcham_v2_workspace

let default_seed = 20_260_812

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
let () = Printf.printf "v2 workspace property base seed: %d\n%!" base_seed

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let path components =
  Model.Path.of_components components |> require_ok Model.Path.error_to_string

let file components content =
  Model.File_path (path components, { Model.mode = Model.Regular; content })

let snapshot entries =
  Model.Snapshot.of_entries entries
  |> require_ok Model.construction_error_to_string

let opaque character =
  V2_model.Opaque_object_ref.of_bytes (String.make 32 character)
  |> require_ok V2_model.identity_error_to_string

let capsule_id character =
  V2_model.Capsule_id.of_bytes (String.make 32 character)
  |> require_ok V2_model.identity_error_to_string

let snapshot_link snapshot character : Capsule.snapshot_link =
  {
    Capsule.snapshot_id = Model.Snapshot.id snapshot;
    snapshot_ref = opaque character;
  }

let selected_revision ~capsule_character ~revision_ref_character ~source ~target
    =
  let capsule =
    Capsule.make_capsule
      ~id:(capsule_id capsule_character)
      ~title:"workspace" ~description:"exact selected revision" ~created_at:1L
    |> require_ok Capsule.error_to_string
  in
  let proposal =
    Capsule.propose ~from:source ~to_:target
    |> require_ok Capsule.proposal_error_to_string
  in
  let selection =
    Capsule.select proposal
      ~indices:
        (Capsule.proposal_operations proposal
        |> List.mapi (fun index _ -> index))
    |> require_ok Capsule.selection_error_to_string
  in
  let source_link = snapshot_link source 's' in
  let target_link = snapshot_link target 't' in
  let revision =
    Capsule.make_initial_revision ~capsule
      ~capsule_ref:(opaque capsule_character) ~declared_base:source_link
      ~declared_base_snapshot:source ~expected_result:target_link
      ~selected:selection
      ~source_boundary:
        { Capsule.source_snapshot = source_link; target_snapshot = target_link }
    |> require_ok Capsule.error_to_string
  in
  let link =
    Capsule.make_revision_link
      ~capsule_id:(Capsule.capsule_id capsule)
      ~revision_id:(Capsule.revision_id revision)
      ~revision_ref:(opaque revision_ref_character)
  in
  { Workspace.link; capsule_revision = revision }

let ordered_ids order =
  Workspace.ordered_revisions order
  |> List.map (fun selected ->
      Capsule.revision_link_revision_id selected.Workspace.link)

let deterministic_selection_ignores_input_order () =
  let base = snapshot [] in
  let left =
    selected_revision ~capsule_character:'a' ~revision_ref_character:'1'
      ~source:base
      ~target:(snapshot [ file [ "left" ] "left" ])
  in
  let right =
    selected_revision ~capsule_character:'b' ~revision_ref_character:'2'
      ~source:base
      ~target:(snapshot [ file [ "right" ] "right" ])
  in
  let first =
    Workspace.derive_order ~selected:[ left; right ] ~precedence:[]
    |> require_ok Workspace.error_to_string
  in
  let second =
    Workspace.derive_order ~selected:[ right; left ] ~precedence:[]
    |> require_ok Workspace.error_to_string
  in
  Alcotest.(check (list string))
    "input permutation retains deterministic revision order"
    (List.map V2_model.Capsule_revision_id.to_hex (ordered_ids first))
    (List.map V2_model.Capsule_revision_id.to_hex (ordered_ids second));
  let first_application = Workspace.apply ~base ~order:first ~resolutions:[] in
  let second_application =
    Workspace.apply ~base ~order:second ~resolutions:[]
  in
  Alcotest.(check bool)
    "input permutation retains result snapshot" true
    (Model.Snapshot.equal first_application.Workspace.resulting_snapshot
       second_application.Workspace.resulting_snapshot);
  Alcotest.(check int)
    "independent exact operations have no conflicts" 0
    (List.length first_application.Workspace.conflicts)

let localized_conflict_does_not_block_independent_operation () =
  let base = snapshot [ file [ "shared" ] "before" ] in
  let left =
    selected_revision ~capsule_character:'a' ~revision_ref_character:'1'
      ~source:base
      ~target:(snapshot [ file [ "shared" ] "left" ])
  in
  let right_target =
    snapshot
      [ file [ "independent" ] "still applies"; file [ "shared" ] "right" ]
  in
  let right =
    selected_revision ~capsule_character:'b' ~revision_ref_character:'2'
      ~source:base ~target:right_target
  in
  let before = Capsule.revision_link_revision_id left.Workspace.link in
  let after = Capsule.revision_link_revision_id right.Workspace.link in
  let order =
    Workspace.derive_order ~selected:[ right; left ]
      ~precedence:[ { Workspace.before; after } ]
    |> require_ok Workspace.error_to_string
  in
  let application = Workspace.apply ~base ~order ~resolutions:[] in
  Alcotest.(check int)
    "one stale competing edit is a persistent conflict" 1
    (List.length application.Workspace.conflicts);
  let expected =
    snapshot
      [ file [ "independent" ] "still applies"; file [ "shared" ] "left" ]
  in
  Alcotest.(check bool)
    "independent operation continues after the localized conflict" true
    (Model.Snapshot.equal expected application.Workspace.resulting_snapshot);
  let conflicting_index =
    Capsule.revision_operations right.Workspace.capsule_revision
    |> List.find_index (function
      | Model.Modify_file { path = operation_path; _ } ->
          Model.Path.equal operation_path (path [ "shared" ])
      | Model.Create_file _ | Model.Create_directory _ | Model.Delete_path _
      | Model.Move_path _ | Model.Change_mode _ ->
          false)
    |> Option.get
  in
  let resolved =
    Workspace.apply ~base ~order
      ~resolutions:
        [
          Workspace.Skip_operation
            {
              revision = right.Workspace.link;
              operation_index = conflicting_index;
            };
        ]
  in
  Alcotest.(check int)
    "skip-only resolution removes only its conflict" 0
    (List.length resolved.Workspace.conflicts);
  Alcotest.(check bool)
    "skip-only resolution retains unrelated exact application" true
    (Model.Snapshot.equal expected resolved.Workspace.resulting_snapshot)

let malformed_selection_link_rejects () =
  let base = snapshot [] in
  let selected =
    selected_revision ~capsule_character:'a' ~revision_ref_character:'1'
      ~source:base
      ~target:(snapshot [ file [ "a" ] "a" ])
  in
  let invalid =
    {
      selected with
      Workspace.link =
        Capsule.make_revision_link ~capsule_id:(capsule_id 'z')
          ~revision_id:
            (Capsule.revision_link_revision_id selected.Workspace.link)
          ~revision_ref:(opaque '1');
    }
  in
  (match Workspace.derive_order ~selected:[ invalid ] ~precedence:[] with
  | Error (Workspace.Selection_link_mismatch _) -> ()
  | Error error ->
      Alcotest.fail
        ("malformed selection returned the wrong error: "
        ^ Workspace.error_to_string error)
  | Ok _ ->
      Alcotest.fail "malformed selected revision link unexpectedly ordered")
  [@warning "-4"]

let generated_permuted_selection_is_deterministic =
  QCheck2.Test.make ~count:80
    ~name:
      "V2 workspace order and exact result ignore selected-input permutations"
    QCheck2.Gen.(
      pair (string_size (int_range 0 4096)) (string_size (int_range 0 4096)))
    (fun (left_content, right_content) ->
      let base = snapshot [] in
      let left =
        selected_revision ~capsule_character:'a' ~revision_ref_character:'1'
          ~source:base
          ~target:(snapshot [ file [ "left" ] left_content ])
      in
      let right =
        selected_revision ~capsule_character:'b' ~revision_ref_character:'2'
          ~source:base
          ~target:(snapshot [ file [ "right" ] right_content ])
      in
      match
        ( Workspace.derive_order ~selected:[ left; right ] ~precedence:[],
          Workspace.derive_order ~selected:[ right; left ] ~precedence:[] )
      with
      | Ok first, Ok second ->
          let first_application =
            Workspace.apply ~base ~order:first ~resolutions:[]
          in
          let second_application =
            Workspace.apply ~base ~order:second ~resolutions:[]
          in
          List.equal V2_model.Capsule_revision_id.equal (ordered_ids first)
            (ordered_ids second)
          && Model.Snapshot.equal first_application.Workspace.resulting_snapshot
               second_application.Workspace.resulting_snapshot
          && first_application.Workspace.conflicts = []
          && second_application.Workspace.conflicts = []
      | Error _, Ok _ | Ok _, Error _ | Error _, Error _ -> false)

let () =
  Alcotest.run "V2 workspace composition"
    [
      ( "unit",
        [
          Alcotest.test_case "selection order is deterministic" `Quick
            deterministic_selection_ignores_input_order;
          Alcotest.test_case
            "localized conflict permits independent application" `Quick
            localized_conflict_does_not_block_independent_operation;
          Alcotest.test_case "malformed selection link rejects" `Quick
            malformed_selection_link_rejects;
          QCheck_alcotest.to_alcotest ~speed_level:`Quick
            ~rand:(state_for "workspace-permutation")
            generated_permuted_selection_is_deterministic;
        ] );
    ]
