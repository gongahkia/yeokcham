module Capsule = Yeokcham_capsule
module Id = Yeokcham_id
module Scratch = Yeokcham_scratch
module Snapshot = Yeokcham_snapshot
module Store = Yeokcham_store
module Workspace = Yeokcham_workspace

[@@@warning "-4"]

let raw_id seed =
  Bytes.init 32 (fun index -> Char.chr ((seed + index) land 0xff))
  |> Bytes.unsafe_to_string

let capsule_id seed = Id.Capsule_id.of_bytes (raw_id seed) |> Result.get_ok

let revision_id seed =
  Id.Capsule_revision_id.of_bytes (raw_id seed) |> Result.get_ok

let release_id seed = Id.Release_id.of_bytes (raw_id seed) |> Result.get_ok

let content_id seed =
  Store.Stored_object_id.of_raw_bytes (raw_id seed)
  |> Option.get |> Snapshot.Content.of_stored_object_id

let selection ?(dependencies = []) capsule revision =
  Workspace.{ capsule; revision; dependencies }

let require_ok render = function
  | Ok value -> value
  | Error error -> Alcotest.fail (render error)

let ordered_revisions order =
  Workspace.revisions order
  |> List.map (fun selection -> selection.Workspace.revision)

let required_dependencies_and_declared_order_are_applied () =
  let capsule_a = capsule_id 10 in
  let capsule_b = capsule_id 20 in
  let capsule_c = capsule_id 30 in
  let revision_a = revision_id 10 in
  let revision_b = revision_id 20 in
  let revision_c = revision_id 30 in
  let selected =
    [
      selection capsule_c revision_c
        ~dependencies:
          [
            Capsule.Requires_capsule
              { capsule = capsule_a; revision = Some revision_a };
          ];
      selection capsule_b revision_b
        ~dependencies:[ Capsule.Ordered_after capsule_a ];
      selection capsule_a revision_a;
    ]
  in
  let order =
    Workspace.derive_order ~selected ~explicit_order:None
    |> require_ok Workspace.error_to_string
  in
  Alcotest.(check (list string))
    "required and declared edges order revisions"
    (List.map Id.Capsule_revision_id.to_hex
       [ revision_a; revision_b; revision_c ])
    (List.map Id.Capsule_revision_id.to_hex (ordered_revisions order));
  Alcotest.(check int)
    "all graph edges are inspectable" 2
    (List.length (Workspace.edges order))

let explicit_precedence_covers_the_exact_selection () =
  let selections =
    [
      selection (capsule_id 40) (revision_id 40);
      selection (capsule_id 41) (revision_id 41);
      selection (capsule_id 42) (revision_id 42);
    ]
  in
  let explicit_order =
    List.rev
      (List.map (fun selection -> selection.Workspace.revision) selections)
  in
  let order =
    Workspace.derive_order ~selected:selections
      ~explicit_order:(Some explicit_order)
    |> require_ok Workspace.error_to_string
  in
  Alcotest.(check (list string))
    "explicit precedence wins over tie-break"
    (List.map Id.Capsule_revision_id.to_hex explicit_order)
    (List.map Id.Capsule_revision_id.to_hex (ordered_revisions order));
  Alcotest.(check int)
    "explicit order creates two edges" 2
    (List.length (Workspace.edges order))

let incomplete_or_conflicting_selections_reject () =
  let capsule_a = capsule_id 50 in
  let capsule_b = capsule_id 51 in
  let revision_a = revision_id 50 in
  let revision_b = revision_id 51 in
  let selected =
    [
      selection capsule_a revision_a
        ~dependencies:[ Capsule.Conflicts_with_capsule capsule_b ];
      selection capsule_b revision_b;
    ]
  in
  (match Workspace.derive_order ~selected ~explicit_order:None with
  | Error (Workspace.Conflicting_capsules _) -> ()
  | Error error -> Alcotest.fail (Workspace.error_to_string error)
  | Ok _ -> Alcotest.fail "conflicting selected capsules were accepted");
  match
    Workspace.derive_order
      ~selected:[ selection capsule_a revision_a ]
      ~explicit_order:(Some [])
  with
  | Error (Workspace.Explicit_order_missing actual) ->
      Alcotest.(check bool)
        "missing revision is identified" true
        (Id.Capsule_revision_id.equal revision_a actual)
  | Error error -> Alcotest.fail (Workspace.error_to_string error)
  | Ok _ -> Alcotest.fail "incomplete explicit order was accepted"

let missing_requirements_and_cycles_reject () =
  let capsule_a = capsule_id 60 in
  let capsule_b = capsule_id 61 in
  let revision_a = revision_id 60 in
  let revision_b = revision_id 61 in
  let missing =
    [
      selection capsule_a revision_a
        ~dependencies:
          [
            Capsule.Requires_capsule
              { capsule = capsule_b; revision = Some revision_b };
          ];
    ]
  in
  (match Workspace.derive_order ~selected:missing ~explicit_order:None with
  | Error (Workspace.Required_capsule_missing _) -> ()
  | Error error -> Alcotest.fail (Workspace.error_to_string error)
  | Ok _ -> Alcotest.fail "missing required capsule was accepted");
  let wrong_revision = revision_id 63 in
  let mismatched =
    [
      selection capsule_a revision_a
        ~dependencies:
          [
            Capsule.Requires_capsule
              { capsule = capsule_b; revision = Some wrong_revision };
          ];
      selection capsule_b revision_b;
    ]
  in
  (match Workspace.derive_order ~selected:mismatched ~explicit_order:None with
  | Error (Workspace.Required_revision_missing { required_revision; _ }) ->
      Alcotest.(check bool)
        "required revision is identified" true
        (Id.Capsule_revision_id.equal wrong_revision required_revision)
  | Error error -> Alcotest.fail (Workspace.error_to_string error)
  | Ok _ -> Alcotest.fail "mismatched required revision was accepted");
  let release = release_id 62 in
  let release_requirement =
    [
      selection capsule_a revision_a
        ~dependencies:[ Capsule.Requires_release release ];
    ]
  in
  (match
     Workspace.derive_order ~selected:release_requirement ~explicit_order:None
   with
  | Error (Workspace.Required_release_unavailable _) -> ()
  | Error error -> Alcotest.fail (Workspace.error_to_string error)
  | Ok _ -> Alcotest.fail "unavailable release requirement was accepted");
  let cyclic =
    [
      selection capsule_a revision_a
        ~dependencies:
          [ Capsule.Requires_capsule { capsule = capsule_b; revision = None } ];
      selection capsule_b revision_b
        ~dependencies:
          [ Capsule.Requires_capsule { capsule = capsule_a; revision = None } ];
    ]
  in
  match Workspace.derive_order ~selected:cyclic ~explicit_order:None with
  | Error (Workspace.Dependency_cycle revisions) ->
      Alcotest.(check int)
        "cycle lists both unresolved revisions" 2 (List.length revisions)
  | Error error -> Alcotest.fail (Workspace.error_to_string error)
  | Ok _ -> Alcotest.fail "dependency cycle was accepted"

let duplicate_selection_rejects () =
  let capsule_a = capsule_id 70 in
  let capsule_b = capsule_id 71 in
  let revision_a = revision_id 70 in
  let revision_b = revision_id 71 in
  (match
     Workspace.derive_order
       ~selected:
         [ selection capsule_a revision_a; selection capsule_a revision_b ]
       ~explicit_order:None
   with
  | Error (Workspace.Duplicate_capsule actual) ->
      Alcotest.(check bool)
        "duplicate capsule is identified" true
        (Id.Capsule_id.equal capsule_a actual)
  | Error error -> Alcotest.fail (Workspace.error_to_string error)
  | Ok _ -> Alcotest.fail "duplicate capsule selection was accepted");
  match
    Workspace.derive_order
      ~selected:
        [ selection capsule_a revision_a; selection capsule_b revision_a ]
      ~explicit_order:None
  with
  | Error (Workspace.Duplicate_revision actual) ->
      Alcotest.(check bool)
        "duplicate revision is identified" true
        (Id.Capsule_revision_id.equal revision_a actual)
  | Error error -> Alcotest.fail (Workspace.error_to_string error)
  | Ok _ -> Alcotest.fail "duplicate revision selection was accepted"

let independent_operations_continue_after_a_conflict () =
  let capsule_a = capsule_id 81 in
  let capsule_c = capsule_id 82 in
  let capsule_b = capsule_id 83 in
  let revision_a = revision_id 81 in
  let revision_c = revision_id 82 in
  let revision_b = revision_id 83 in
  let base_a = content_id 90 in
  let changed_a = content_id 91 in
  let base_b = content_id 92 in
  let changed_b = content_id 93 in
  let state =
    Scratch.State.create
      [
        ([ "dir" ], Scratch.Directory);
        ( [ "dir"; "a" ],
          Scratch.File { mode = Snapshot.Regular; content = base_a } );
        ( [ "dir"; "b" ],
          Scratch.File { mode = Snapshot.Regular; content = base_b } );
      ]
    |> require_ok Scratch.error_to_string
  in
  let transition path expected replacement : Capsule.exact_file_transition =
    {
      Capsule.transition_path = path;
      expected_entry =
        Some (Scratch.File { mode = Snapshot.Regular; content = expected });
      replacement_entry =
        Some (Scratch.File { mode = Snapshot.Regular; content = replacement });
    }
  in
  let application_revision capsule revision operations :
      Workspace.application_revision =
    { Workspace.selected = selection capsule revision; Workspace.operations }
  in
  let result =
    Workspace.apply ~state
      ~ordered:
        [
          application_revision capsule_a revision_a
            [
              Capsule.Exact_file_transition
                (transition [ "dir"; "a" ] base_a changed_a);
            ];
          application_revision capsule_c revision_c
            [
              Capsule.Exact_file_transition
                (transition [ "dir"; "a" ] base_a (content_id 94));
            ];
          application_revision capsule_b revision_b
            [
              Capsule.Exact_file_transition
                (transition [ "dir"; "b" ] base_b changed_b);
            ];
        ]
      ~resolutions:[]
  in
  Alcotest.(check int)
    "one local conflict" 1
    (List.length result.Workspace.conflicts);
  Alcotest.(check bool)
    "independent operation applies" true
    (match Scratch.State.find result.Workspace.state [ "dir"; "b" ] with
    | Some (Scratch.File file) ->
        Snapshot.Content.equal_id file.content changed_b
    | Some Scratch.Directory | None -> false)

let () =
  Alcotest.run "workspace"
    [
      ( "dependency graph",
        [
          Alcotest.test_case "required dependencies and declared order" `Quick
            required_dependencies_and_declared_order_are_applied;
          Alcotest.test_case "explicit precedence exact selection" `Quick
            explicit_precedence_covers_the_exact_selection;
          Alcotest.test_case "conflicts and incomplete precedence reject" `Quick
            incomplete_or_conflicting_selections_reject;
          Alcotest.test_case "requirements and cycles reject" `Quick
            missing_requirements_and_cycles_reject;
          Alcotest.test_case "duplicate selections reject" `Quick
            duplicate_selection_rejects;
          Alcotest.test_case "independent operations continue after conflict"
            `Quick independent_operations_continue_after_a_conflict;
        ] );
    ]
