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

let body_accepted ?(parents = []) ?(chosen = []) result =
  Core.make_accepted_version ~branch ~accepted_parents:parents
    ~chosen_revisions:chosen ~resolutions:[] ~result_snapshot:result
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
        ] );
    ]
