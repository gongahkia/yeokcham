module C = Yeokcham_v1_composition
module G = C.Graph
module Core = Yeokcham_v1_model.Core
module S = Yeokcham_snapshot
module Raw = Yeokcham_store

let ok render = function
  | Ok value -> value
  | Error e -> Alcotest.fail (render e)

let model r = ok Core.error_to_string r
let composed r = ok C.error_to_string r
let graph r = ok G.error_to_string r
let rejected label = function Error _ -> () | Ok _ -> Alcotest.fail label

let rec remove path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun n -> remove (Filename.concat path n)) (Sys.readdir path);
      Unix.rmdir path
  | Unix.S_REG | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK | Unix.S_CHR
  | Unix.S_BLK ->
      Unix.unlink path

let with_store f =
  let root = Filename.temp_file "yeokcham-graph-" "" in
  Unix.unlink root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove root)
    (fun () -> f (Raw.init ~root |> ok Raw.error_to_string))

let repository = Core.Repository_id.of_raw (String.make 32 'r') |> model
let branch = Core.Branch_id.of_raw (String.make 16 'b') |> model
let id label = Core.Record_id.of_raw (String.make 32 label) |> model
let change label = Core.Change_id.of_raw (String.make 16 label) |> model

let context =
  Core.make_context ~repository
    ~author_certificate:(Core.Digest.of_raw (String.make 32 'c') |> model)
    ~authority_heads:[ Core.Digest.of_raw (String.make 32 'a') |> model ]
    ~display_time:None
  |> model

(* pure pool tests use explicit symbolic IDs; signed store tests cover the trust boundary *)
let retain pool label payload =
  Core.retain pool ~id:(id label) (Core.make_body ~context ~payload)
  |> model |> fst

let body_accepted ?(parents = []) ?(chosen = []) ?(resolutions = []) result =
  Core.make_accepted_version ~branch ~accepted_parents:parents
    ~chosen_revisions:chosen ~resolutions ~result_snapshot:result
    ~composition_profile:"line-hunks-v1" ~policy_heads:[] ~review_evidence:[]
  |> model
  |> fun value -> Core.Accepted_version value

let event ?(previous = []) ~action targets name =
  Core.make_branch_event ~branch ~previous_events:previous ~action ~targets
    ~display_name:name
  |> model
  |> fun value -> Core.Branch_event value

let tree store entries =
  C.tree
    (List.map
       (fun (name, bytes) ->
         ( [ name ],
           C.File
             {
               mode = S.Regular;
               content = S.Content.store store bytes |> ok S.error_to_string;
             } ))
       entries)
  |> composed

let publish store pool label ?(previous = []) ?(dependencies = [])
    ~change:change_id ~base result =
  let base_tree = C.load store base |> composed in
  let result_id = C.store store result |> composed in
  let scope =
    C.Scope.store store (C.differences base_tree result) |> composed
  in
  let value =
    Core.make_shared_revision ~change:change_id ~previous_revisions:previous
      ~base_snapshot:base ~result_snapshot:result_id ~edit_scope_root:scope
      ~dependencies
    |> model
  in
  (retain pool label (Core.Shared_revision value), result_id)

let fixture store =
  let empty = C.store store (tree store []) |> composed in
  let pool = retain (Core.empty_pool ~repository) 'g' (body_accepted empty) in
  let pool =
    retain pool 'e' (event ~action:Core.Create [ id 'g' ] (Some "main"))
  in
  (pool, empty)

let snapshot_equals store expected actual =
  let actual_id = C.store store actual |> composed in
  Alcotest.(check bool)
    "exact composed snapshot" true
    (Core.Object_id.equal expected actual_id)

let valid_results_and_updates () =
  with_store (fun store ->
      let pool, empty = fixture store in
      let pool, a =
        publish store pool '1' ~change:(change 'a') ~base:empty
          (tree store [ ("a", "A\n") ])
      in
      let pool, c =
        publish store pool '2' ~change:(change 'c') ~base:empty
          (tree store [ ("c", "C\n") ])
      in
      let target =
        C.merge store ~base:(tree store [])
          ~variants:[ C.load store a |> composed; C.load store c |> composed ]
        |> composed |> C.store store |> composed
      in
      let pool =
        retain pool 'h'
          (body_accepted ~parents:[ id 'g' ] ~chosen:[ id '1'; id '2' ] target)
      in
      let pool =
        retain pool 'f'
          (event ~previous:[ id 'e' ] ~action:Core.Advance [ id 'h' ] None)
      in
      G.validate store pool |> graph;
      let pool, updated =
        publish store pool '3'
          ~previous:[ id '1' ]
          ~change:(change 'a') ~base:empty
          (tree store [ ("a", "updated\n") ])
      in
      let result =
        G.compose store pool ~parents:[ id 'h' ] ~revisions:[ id '3' ] |> graph
      in
      let expected =
        C.store store (tree store [ ("a", "updated\n"); ("c", "C\n") ])
        |> composed
      in
      snapshot_equals store expected result;
      Alcotest.(check bool)
        "update result itself does not smuggle another change" false
        (Core.Object_id.equal expected updated);
      let pool =
        retain pool 'i'
          (body_accepted ~parents:[ id 'h' ] ~chosen:[ id '3' ] expected)
      in
      G.validate store pool |> graph;
      let again =
        G.compose store pool ~parents:[ id 'i' ] ~revisions:[ id '1'; id '3' ]
        |> graph
      in
      snapshot_equals store expected again)

let dependency_order () =
  with_store (fun store ->
      let pool, empty = fixture store in
      let pool, a =
        publish store pool '1' ~change:(change 'a') ~base:empty
          (tree store [ ("a", "A") ])
      in
      let pool, ab =
        publish store pool '2'
          ~dependencies:[ id '1' ]
          ~change:(change 'b') ~base:a
          (tree store [ ("a", "A"); ("b", "B") ])
      in
      snapshot_equals store ab
        (G.compose store pool ~parents:[ id 'g' ] ~revisions:[ id '2' ] |> graph);
      let pool =
        retain pool 'h'
          (body_accepted ~parents:[ id 'g' ] ~chosen:[ id '2' ] ab)
      in
      G.validate store pool |> graph;
      let ids = G.represented pool [ id 'h' ] |> graph in
      Alcotest.(check bool)
        "accepted dependency retained as represented" true
        (List.mem (id '1') ids))

let concurrent_heads_and_same_contents () =
  with_store (fun store ->
      let pool, empty = fixture store in
      let pool, a =
        publish store pool '1' ~change:(change 'a') ~base:empty
          (tree store [ ("a", "A") ])
      in
      let pool, b =
        publish store pool '2' ~change:(change 'b') ~base:empty
          (tree store [ ("b", "B") ])
      in
      let pool =
        retain pool 'h' (body_accepted ~parents:[ id 'g' ] ~chosen:[ id '1' ] a)
      in
      let pool =
        retain pool 'i' (body_accepted ~parents:[ id 'g' ] ~chosen:[ id '2' ] b)
      in
      let pool =
        retain pool 'f'
          (event ~previous:[ id 'e' ] ~action:Core.Advance [ id 'h' ] None)
      in
      let pool =
        retain pool 'j'
          (event ~previous:[ id 'e' ] ~action:Core.Advance [ id 'i' ] None)
      in
      G.validate store pool |> graph;
      let expected =
        C.store store (tree store [ ("a", "A"); ("b", "B") ]) |> composed
      in
      List.iter
        (fun parents ->
          snapshot_equals store expected
            (G.compose store pool ~parents ~revisions:[] |> graph))
        [ [ id 'h'; id 'i' ]; [ id 'i'; id 'h' ] ];
      let pool =
        retain pool 'k' (body_accepted ~parents:[ id 'h'; id 'i' ] expected)
      in
      let pool =
        retain pool 'l'
          (event
             ~previous:[ id 'f'; id 'j' ]
             ~action:Core.Reconcile
             [ id 'k' ]
             None)
      in
      G.validate store pool |> graph;
      let pool =
        retain pool 'm' (body_accepted ~parents:[ id 'h'; id 'i' ] expected)
      in
      rejected "equal contents concealed incomparable bases"
        (G.common_base pool [ id 'k'; id 'm' ]))

let invalid_accepted_and_branch_drop () =
  with_store (fun store ->
      let pool, empty = fixture store in
      let pool, a =
        publish store pool '1' ~change:(change 'a') ~base:empty
          (tree store [ ("a", "A") ])
      in
      let false_result =
        C.store store (tree store [ ("a", "UNSELECTED PRIVATE BYTES") ])
        |> composed
      in
      let false_pool =
        retain pool 'h'
          (body_accepted ~parents:[ id 'g' ] ~chosen:[ id '1' ] false_result)
      in
      rejected "claimed accepted snapshot passed without composition proof"
        (G.validate store false_pool);
      let genesis = retain pool 'z' (body_accepted false_result) in
      rejected "nonempty genesis accepted" (G.validate store genesis);
      let pool =
        retain pool 'h' (body_accepted ~parents:[ id 'g' ] ~chosen:[ id '1' ] a)
      in
      let pool =
        retain pool 'f'
          (event ~previous:[ id 'e' ] ~action:Core.Advance [ id 'h' ] None)
      in
      let pool = retain pool 'z' (body_accepted empty) in
      let bad =
        retain pool 'x'
          (event ~previous:[ id 'f' ] ~action:Core.Advance [ id 'z' ] None)
      in
      rejected "branch advancement discarded inherited accepted history"
        (G.validate store bad);
      let renamed =
        retain pool 'y'
          (event ~previous:[ id 'f' ] ~action:Core.Rename [] (Some "renamed"))
      in
      G.validate store renamed |> graph)

let competing_updates_and_conflicts () =
  with_store (fun store ->
      let pool, empty = fixture store in
      let pool, a =
        publish store pool '1' ~change:(change 'a') ~base:empty
          (tree store [ ("a", "initial\n") ])
      in
      let pool, _ =
        publish store pool '2'
          ~previous:[ id '1' ]
          ~change:(change 'a') ~base:empty
          (tree store [ ("a", "left\n") ])
      in
      let pool, _ =
        publish store pool '3'
          ~previous:[ id '1' ]
          ~change:(change 'a') ~base:empty
          (tree store [ ("a", "right\n") ])
      in
      let pool =
        retain pool 'h' (body_accepted ~parents:[ id 'g' ] ~chosen:[ id '1' ] a)
      in
      rejected "concurrent change versions silently combined"
        (G.compose store pool ~parents:[ id 'h' ] ~revisions:[ id '2'; id '3' ]);
      let pool, _ =
        publish store pool '4' ~change:(change 'b') ~base:empty
          (tree store [ ("a", "other addition\n") ])
      in
      rejected "competing path additions selected a winner"
        (G.compose store pool ~parents:[ id 'g' ] ~revisions:[ id '1'; id '4' ]))

let unrelated_base () =
  with_store (fun store ->
      let pool, _ = fixture store in
      let private_base =
        C.store store (tree store [ ("private", "SENTINEL") ]) |> composed
      in
      let pool, _ =
        publish store pool '1' ~change:(change 'a') ~base:private_base
          (tree store [ ("private", "SENTINEL"); ("a", "shared") ])
      in
      rejected "unrecorded private base accepted as public provenance"
        (G.validate store pool))

let resolution store pool label ~parents ~chosen ~path ~comparison replacement =
  let decision_scope_root = C.Scope.store store [ path ] |> composed in
  let replacement_snapshot = C.store store replacement |> composed in
  let value =
    Core.make_resolution_revision ~branch ~accepted_heads:parents
      ~chosen_revisions:chosen
      ~superseded_variants:
        (Core.resolution_variants pool ~accepted_heads:parents
           ~chosen_revisions:chosen
        |> model)
      ~decision_scope_root ~comparison_snapshot:comparison ~replacement_snapshot
    |> model
  in
  retain pool label (Core.Resolution_revision value)

let resolved_inputs store =
  let pool, empty = fixture store in
  let pool, left =
    publish store pool '1' ~change:(change 'a') ~base:empty
      (tree store [ ("x", "left\r\n"); ("left", "independent left\n") ])
  in
  let pool, right =
    publish store pool '2' ~change:(change 'b') ~base:empty
      (tree store [ ("x", "right\r\n"); ("right", "independent right\n") ])
  in
  (pool, empty, left, right)

let resolution_preserves_automatic_paths_and_validates_acceptance () =
  with_store (fun store ->
      let pool, empty, _, _ = resolved_inputs store in
      let parents = [ id 'g' ] and chosen = [ id '1'; id '2' ] in
      let replacement = tree store [ ("x", "explicit replacement\r\n") ] in
      let pool =
        resolution store pool 's' ~parents ~chosen ~path:[ "x" ]
          ~comparison:empty replacement
      in
      let expected =
        tree store
          [
            ("x", "explicit replacement\r\n");
            ("left", "independent left\n");
            ("right", "independent right\n");
          ]
        |> C.store store |> composed
      in
      List.iter
        (fun revisions ->
          snapshot_equals store expected
            (G.compose ~resolutions:[ id 's' ] store pool ~parents ~revisions
            |> graph))
        [ chosen; List.rev chosen ];
      let accepted =
        retain pool 'a'
          (body_accepted ~parents ~chosen ~resolutions:[ id 's' ] expected)
      in
      G.validate store accepted |> graph;
      Alcotest.(check (list string))
        "resolution is not misclassified as another shared revision"
        (List.map Core.Record_id.to_hex chosen)
        (G.represented accepted [ id 'a' ]
        |> graph
        |> List.map Core.Record_id.to_hex);
      let false_result =
        retain pool 'f'
          (body_accepted ~parents ~chosen ~resolutions:[ id 's' ] empty)
      in
      rejected
        "resolution signature/metadata cannot authorize a false accepted result"
        (G.validate store false_result))

let resolution_rejects_private_leak_stale_and_unused_decisions () =
  with_store (fun store ->
      let pool, empty, _, _ = resolved_inputs store in
      let parents = [ id 'g' ] and chosen = [ id '1'; id '2' ] in
      let private_extra =
        tree store [ ("x", "chosen"); ("private", "PRIVATE SENTINEL") ]
      in
      let leaked =
        resolution store pool 'l' ~parents ~chosen ~path:[ "x" ]
          ~comparison:empty private_extra
      in
      rejected "resolution leaks unrelated private bytes"
        (G.validate store leaked);
      let pool =
        resolution store pool 's' ~parents ~chosen ~path:[ "x" ]
          ~comparison:empty
          (tree store [ ("x", "chosen") ])
      in
      rejected "resolution reused after exact selection changed"
        (G.compose
           ~resolutions:[ id 's' ]
           store pool ~parents
           ~revisions:[ id '1' ]);
      rejected "resolution accepted with a different chosen set"
        (Core.retain pool ~id:(id 'a')
           (Core.make_body ~context
              ~payload:
                (body_accepted ~parents
                   ~chosen:[ id '1' ]
                   ~resolutions:[ id 's' ]
                   empty)));
      let unused =
        resolution store pool 'u' ~parents ~chosen ~path:[ "left" ]
          ~comparison:empty
          (tree store [ ("left", "override") ])
      in
      rejected "unrelated decision bypassed an unresolved conflict"
        (G.compose
           ~resolutions:[ id 'u' ]
           store unused ~parents ~revisions:chosen);
      let irrelevant =
        resolution store pool 'i' ~parents
          ~chosen:[ id '1' ]
          ~path:[ "left" ] ~comparison:empty
          (tree store [ ("left", "override") ])
      in
      rejected "a resolution overrode nonconflicting shared work"
        (G.compose
           ~resolutions:[ id 'i' ]
           store irrelevant ~parents
           ~revisions:[ id '1' ]);
      let duplicate =
        resolution store pool 'd' ~parents ~chosen ~path:[ "x" ]
          ~comparison:empty
          (tree store [ ("x", "other") ])
      in
      rejected "overlapping decisions picked an ID-order winner"
        (G.compose
           ~resolutions:[ id 's'; id 'd' ]
           store duplicate ~parents ~revisions:chosen))

let partial_resolution_exposes_remaining_conflict () =
  with_store (fun store ->
      let pool, empty = fixture store in
      let pool, _ =
        publish store pool '1' ~change:(change 'a') ~base:empty
          (tree store [ ("x", "left"); ("y", "left") ])
      in
      let pool, _ =
        publish store pool '2' ~change:(change 'b') ~base:empty
          (tree store [ ("x", "right"); ("y", "right") ])
      in
      let parents = [ id 'g' ] and chosen = [ id '1'; id '2' ] in
      let pool =
        resolution store pool 's' ~parents ~chosen ~path:[ "x" ]
          ~comparison:empty
          (tree store [ ("x", "chosen") ])
      in
      (match
         G.compose ~resolutions:[ id 's' ] store pool ~parents ~revisions:chosen
       with
      | Error (G.Content_error (C.Conflicts paths)) ->
          Alcotest.(check (list (list string)))
            "remaining path stays unresolved" [ [ "y" ] ] paths
      | Ok _
      | Error
          ( G.Invalid_graph _ | G.Decision _
          | G.Content_error (C.Invalid_input _ | C.Unavailable _ | C.Integrity _)
            ) ->
          Alcotest.fail "partial decision became acceptance");
      let pool =
        resolution store pool 't' ~parents ~chosen ~path:[ "y" ]
          ~comparison:empty
          (tree store [ ("y", "chosen y") ])
      in
      let expected =
        tree store [ ("x", "chosen"); ("y", "chosen y") ]
        |> C.store store |> composed
      in
      List.iter
        (fun resolutions ->
          snapshot_equals store expected
            (G.compose ~resolutions store pool ~parents ~revisions:chosen
            |> graph))
        [ [ id 's'; id 't' ]; [ id 't'; id 's' ] ])

let accepted_heads_and_opaque_resolutions () =
  with_store (fun store ->
      let pool, empty = fixture store in
      let pool, left =
        publish store pool '1' ~change:(change 'a') ~base:empty
          (tree store [ ("asset", "\000left\255") ])
      in
      let pool, right =
        publish store pool '2' ~change:(change 'b') ~base:empty
          (tree store [ ("asset", "\000right\255") ])
      in
      let pool =
        retain pool 'l'
          (body_accepted ~parents:[ id 'g' ] ~chosen:[ id '1' ] left)
      in
      let pool =
        retain pool 'r'
          (body_accepted ~parents:[ id 'g' ] ~chosen:[ id '2' ] right)
      in
      let parents = [ id 'l'; id 'r' ] in
      let replacement = tree store [ ("asset", "\000explicit\255") ] in
      let expected = C.store store replacement |> composed in
      let pool =
        resolution store pool 's' ~parents ~chosen:[] ~path:[ "asset" ]
          ~comparison:empty replacement
      in
      List.iter
        (fun parents ->
          snapshot_equals store expected
            (G.compose ~resolutions:[ id 's' ] store pool ~parents ~revisions:[]
            |> graph))
        [ parents; List.rev parents ];
      G.validate store
        (retain pool 'a'
           (body_accepted ~parents ~resolutions:[ id 's' ] expected))
      |> graph;
      rejected "resolution omitted an offline accepted head"
        (G.compose
           ~resolutions:[ id 's' ]
           store pool
           ~parents:[ id 'l' ]
           ~revisions:[]))

let choosing_absence_and_large_exact_contents () =
  with_store (fun store ->
      let pool, empty, left, _ = resolved_inputs store in
      let parents = [ id 'g' ] and chosen = [ id '1'; id '2' ] in
      let pool =
        resolution store pool 's' ~parents ~chosen ~path:[ "x" ]
          ~comparison:empty (tree store [])
      in
      let expected =
        tree store
          [ ("left", "independent left\n"); ("right", "independent right\n") ]
        |> C.store store |> composed
      in
      snapshot_equals store expected
        (G.compose ~resolutions:[ id 's' ] store pool ~parents ~revisions:chosen
        |> graph);
      let large = "\000" ^ String.make ((2 * 1024 * 1024) + 17) 'b' in
      let pool =
        resolution store pool 'b' ~parents ~chosen ~path:[ "x" ]
          ~comparison:empty
          (tree store [ ("x", large) ])
      in
      let expected =
        tree store
          [
            ("x", large);
            ("left", "independent left\n");
            ("right", "independent right\n");
          ]
        |> C.store store |> composed
      in
      snapshot_equals store expected
        (G.compose ~resolutions:[ id 'b' ] store pool ~parents ~revisions:chosen
        |> graph);
      let wrong_base =
        resolution store pool 'w' ~parents ~chosen ~path:[ "x" ]
          ~comparison:left
          (tree store [ ("x", "chosen") ])
      in
      rejected "a resolution invented a comparison base"
        (G.validate store wrong_base))

let directory_type_mode_and_symlink_decisions () =
  with_store (fun store ->
      let pool, empty = fixture store in
      let pool, _ =
        publish store pool '1' ~change:(change 'a') ~base:empty
          (tree store [ ("node", "file") ])
      in
      let directory =
        C.tree
          [
            ([ "node" ], C.Directory);
            ( [ "node"; "child" ],
              C.File
                {
                  mode = S.Executable;
                  content =
                    S.Content.store store "executable\n" |> ok S.error_to_string;
                } );
          ]
        |> composed
      in
      let pool, _ =
        publish store pool '2' ~change:(change 'b') ~base:empty directory
      in
      let parents = [ id 'g' ] and chosen = [ id '1'; id '2' ] in
      let pool =
        resolution store pool 's' ~parents ~chosen ~path:[ "node" ]
          ~comparison:empty directory
      in
      snapshot_equals store
        (C.store store directory |> composed)
        (G.compose ~resolutions:[ id 's' ] store pool ~parents ~revisions:chosen
        |> graph);
      let symlink =
        C.tree
          [
            ( [ "node" ],
              C.File
                {
                  mode = S.Symlink;
                  content =
                    S.Content.store store "missing-target"
                    |> ok S.error_to_string;
                } );
          ]
        |> composed
      in
      let pool =
        resolution store pool 't' ~parents ~chosen ~path:[ "node" ]
          ~comparison:empty symlink
      in
      snapshot_equals store
        (C.store store symlink |> composed)
        (G.compose ~resolutions:[ id 't' ] store pool ~parents ~revisions:chosen
        |> graph))

let dependency_conflicts_bind_every_superseded_variant () =
  with_store (fun store ->
      let pool, empty, left, _ = resolved_inputs store in
      let base = C.load store left |> composed in
      let content =
        S.Content.store store "dependent addition" |> ok S.error_to_string
      in
      let result =
        C.overlay ~base
          [ ([ "dependent" ], Some (C.File { mode = S.Regular; content })) ]
        |> composed
      in
      let pool, _ =
        publish store pool '3'
          ~dependencies:[ id '1'; id '2' ]
          ~change:(change 'c') ~base:left result
      in
      let parents = [ id 'g' ] and chosen = [ id '3' ] in
      let pool =
        resolution store pool 's' ~parents ~chosen ~path:[ "x" ]
          ~comparison:empty
          (tree store [ ("x", "chosen") ])
      in
      let expected =
        tree store
          [
            ("x", "chosen");
            ("left", "independent left\n");
            ("right", "independent right\n");
            ("dependent", "dependent addition");
          ]
        |> C.store store |> composed
      in
      snapshot_equals store expected
        (G.compose ~resolutions:[ id 's' ] store pool ~parents ~revisions:chosen
        |> graph);
      G.validate store
        (retain pool 'a'
           (body_accepted ~parents ~chosen ~resolutions:[ id 's' ] expected))
      |> graph)

let nested_decision_keeps_only_necessary_parent_structure () =
  with_store (fun store ->
      let pool, empty = fixture store in
      let nested bytes =
        C.tree
          [
            ([ "folder" ], C.Directory);
            ( [ "folder"; "note" ],
              C.File
                {
                  mode = S.Regular;
                  content = S.Content.store store bytes |> ok S.error_to_string;
                } );
          ]
        |> composed
      in
      let pool, _ =
        publish store pool '1' ~change:(change 'a') ~base:empty (nested "left")
      in
      let pool, _ =
        publish store pool '2' ~change:(change 'b') ~base:empty (nested "right")
      in
      let parents = [ id 'g' ] and chosen = [ id '1'; id '2' ] in
      let replacement = nested "chosen" in
      let expected = C.store store replacement |> composed in
      let pool =
        resolution store pool 's' ~parents ~chosen ~path:[ "folder"; "note" ]
          ~comparison:empty replacement
      in
      G.validate store pool |> graph;
      snapshot_equals store expected
        (G.compose ~resolutions:[ id 's' ] store pool ~parents ~revisions:chosen
        |> graph))

let () =
  Alcotest.run "Core accepted composition graph"
    [
      ( "proof",
        [
          Alcotest.test_case
            "actual accepted results, updates and represented retries" `Quick
            valid_results_and_updates;
          Alcotest.test_case "declared dependency bases compose in causal order"
            `Quick dependency_order;
          Alcotest.test_case
            "concurrent heads and ambiguous equal-content bases" `Quick
            concurrent_heads_and_same_contents;
          Alcotest.test_case
            "false accepted result, genesis and branch dropping refuse" `Quick
            invalid_accepted_and_branch_drop;
          Alcotest.test_case
            "concurrent updates and shared conflicts need decisions" `Quick
            competing_updates_and_conflicts;
          Alcotest.test_case "private snapshot is not a recorded public base"
            `Quick unrelated_base;
          Alcotest.test_case
            "exact resolution preserves automatic work and proves acceptance"
            `Quick resolution_preserves_automatic_paths_and_validates_acceptance;
          Alcotest.test_case
            "private leaks, stale contexts, unused and overlapping choices \
             refuse"
            `Quick resolution_rejects_private_leak_stale_and_unused_decisions;
          Alcotest.test_case "partial resolution keeps other conflicts explicit"
            `Quick partial_resolution_exposes_remaining_conflict;
          Alcotest.test_case
            "opaque offline accepted heads require all exact variants" `Quick
            accepted_heads_and_opaque_resolutions;
          Alcotest.test_case
            "absence and large opaque choices preserve exact bytes" `Quick
            choosing_absence_and_large_exact_contents;
          Alcotest.test_case
            "directory, executable and symlink decisions are exact" `Quick
            directory_type_mode_and_symlink_decisions;
          Alcotest.test_case
            "resolution names conflicts inside the selected dependency closure"
            `Quick dependency_conflicts_bind_every_superseded_variant;
          Alcotest.test_case
            "nested decisions allow only their necessary parent structure"
            `Quick nested_decision_keeps_only_necessary_parent_structure;
        ] );
    ]
