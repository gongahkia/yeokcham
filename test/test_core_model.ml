module M = Yeokcham_v1_model.Core

let ok = function
  | Ok value -> value
  | Error e -> Alcotest.fail (M.error_to_string e)

let rejects label = function Error _ -> () | Ok _ -> Alcotest.fail label

let error_is expected = function
  | Error actual -> actual = expected
  | Ok _ -> false

let w c = M.Workspace_id.of_raw (String.make 16 c) |> ok
let b c = M.Branch_id.of_raw (String.make 16 c) |> ok
let change c = M.Change_id.of_raw (String.make 16 c) |> ok
let r c = M.Record_id.of_raw (String.make 32 c) |> ok
let o c = M.Object_id.of_raw (String.make 32 c) |> ok
let d c = M.Digest.of_raw (String.make 32 c) |> ok
let repo c = M.Repository_id.of_raw (String.make 32 c) |> ok
let hid c n = M.History_id.make ~workspace:(w c) ~sequence:n |> ok

let context ?(repository = repo 'r') () =
  M.make_context ~repository ~author_certificate:(d 'c')
    ~authority_heads:[ d 'h' ]
    ~display_time:None
  |> ok

let body payload = M.make_body ~context:(context ()) ~payload

let shared ?(previous = []) ?(dependencies = []) c =
  M.make_shared_revision ~change:(change c) ~previous_revisions:previous
    ~base_snapshot:(o 'a') ~result_snapshot:(o 'z') ~edit_scope_root:(o 'e')
    ~dependencies
  |> ok

let accepted ?(parents = []) ?(chosen = []) ?(resolutions = []) ?(policy = [])
    ?(reviews = []) () =
  M.make_accepted_version ~branch:(b 'm') ~accepted_parents:parents
    ~chosen_revisions:chosen ~resolutions ~result_snapshot:(o 'z')
    ~composition_profile:"line-hunks-v1" ~policy_heads:policy
    ~review_evidence:reviews
  |> ok

let retain pool id value = M.retain pool ~id value |> ok |> fst

let node ?parent ?(snapshot = o 'x') workspace sequence =
  M.make_history_node ~id:(hid workspace sequence) ~parent ~snapshot
    ~working_basis:None ~published_revisions:[]
  |> ok

let identifiers () =
  let raw = String.init 16 Char.chr in
  let id = M.Workspace_id.of_raw raw |> ok in
  Alcotest.(check string)
    "exact lowercase encoding" "000102030405060708090a0b0c0d0e0f"
    (M.Workspace_id.to_hex id);
  Alcotest.(check bool)
    "hex round trip" true
    (M.Workspace_id.equal id
       (M.Workspace_id.of_hex (M.Workspace_id.to_hex id) |> ok));
  rejects "short workspace" (M.Workspace_id.of_raw "short");
  rejects "uppercase is not canonical"
    (M.Workspace_id.of_hex (String.make 32 'A'));
  rejects "odd-length hash" (M.Record_id.of_hex (String.make 63 'a'));
  rejects "non-hex hash" (M.Record_id.of_hex (String.make 64 'g'));
  rejects "random source cannot return short bytes"
    (M.Change_id.generate ~random_bytes:(fun _ -> Ok "short") ());
  rejects "operation entropy cannot return short bytes"
    (M.Operation_id.generate ~random_bytes:(fun _ -> Ok "short") ());
  let operation =
    M.Operation_id.generate
      ~random_bytes:(fun n ->
        Alcotest.(check int) "128-bit operation allocation" 16 n;
        Ok raw)
      ()
    |> ok
  in
  Alcotest.(check bool)
    "operation round trip" true
    (M.Operation_id.equal operation
       (M.Operation_id.of_hex (M.Operation_id.to_hex operation) |> ok));
  rejects "entropy errors remain errors"
    (M.Branch_id.generate ~random_bytes:(fun _ -> Error "unavailable") ());
  let requested = ref 0 in
  let generated =
    M.Workspace_id.generate
      ~random_bytes:(fun n ->
        requested := n;
        Ok raw)
      ()
    |> ok
  in
  Alcotest.(check int) "exactly 128 bits requested" 16 !requested;
  Alcotest.(check string)
    "entropy bytes preserved" raw
    (M.Workspace_id.to_raw generated)

let sequence_bounds () =
  rejects "negative sequence"
    (M.History_id.make ~workspace:(w 'w') ~sequence:(-1L));
  let first, next =
    M.History_id.allocate ~workspace:(w 'w') ~next:(Some 0L) |> ok
  in
  Alcotest.(check int64) "first node" 0L (M.History_id.sequence first);
  Alcotest.(check (option int64)) "next node" (Some 1L) next;
  let last, exhausted =
    M.History_id.allocate ~workspace:(w 'w') ~next:(Some Int64.max_int) |> ok
  in
  Alcotest.(check int64)
    "last legal node" Int64.max_int
    (M.History_id.sequence last);
  Alcotest.(check (option int64))
    "exhaustion persisted without wrapping" None exhausted;
  Alcotest.(check bool)
    "sequence cannot wrap" true
    (error_is M.Sequence_exhausted
       (M.History_id.allocate ~workspace:(w 'w') ~next:exhausted))

let branch_history () =
  let a = node 'w' 0L in
  let history, _ = M.retain_history M.empty_history a |> ok in
  let b = node ~parent:(hid 'w' 0L) 'w' 1L in
  let history, _ = M.retain_history history b |> ok in
  let c = node ~parent:(hid 'w' 1L) 'w' 2L in
  let history, _ = M.retain_history history c |> ok in
  let alternate = node ~parent:(hid 'w' 1L) 'w' 3L in
  let history, _ = M.retain_history history alternate |> ok in
  Alcotest.(check int)
    "equal snapshots retain four history positions" 4
    (List.length (M.history_nodes history));
  let repeated, insertion = M.retain_history history c |> ok in
  Alcotest.(check bool)
    "identical retry" true
    (insertion = M.Unchanged && repeated = history);
  rejects "same ID with different contents"
    (M.retain_history history
       (node ~snapshot:(o 'y') ~parent:(hid 'w' 1L) 'w' 2L));
  rejects "missing ancestry" (M.retain_history M.empty_history c);
  rejects "cyclic ancestry"
    (M.make_history_node ~id:(hid 'w' 2L)
       ~parent:(Some (hid 'w' 2L))
       ~snapshot:(o 'x') ~working_basis:None ~published_revisions:[]);
  let fork = node ~parent:(hid 'w' 2L) 'n' 0L in
  let forked, _ = M.retain_history history fork |> ok in
  Alcotest.(check int)
    "copied workspace gets its own identity and ancestry" 5
    (List.length (M.history_nodes forked))

let core_pool () =
  let pool = M.empty_pool ~repository:(repo 'r') in
  let first = body (M.Shared_revision (shared 'a')) in
  let pool = retain pool (r '1') first in
  let pool2, result = M.retain pool ~id:(r '1') first |> ok in
  Alcotest.(check bool)
    "repeat is unchanged" true
    (result = M.Unchanged && pool = pool2);
  rejects "collision cannot replace immutable record"
    (M.retain pool ~id:(r '1') (body (M.Shared_revision (shared 'b'))));
  rejects "change identity cannot be independently re-created"
    (M.retain pool ~id:(r '2') first);
  let foreign =
    M.make_body
      ~context:(context ~repository:(repo 's') ())
      ~payload:(M.Shared_revision (shared 'a'))
  in
  Alcotest.(check bool)
    "foreign scope rejected" true
    (error_is M.Wrong_scope (M.retain pool ~id:(r '2') foreign));
  rejects "previous revision must have the same logical change"
    (M.retain pool ~id:(r '2')
       (body (M.Shared_revision (shared ~previous:[ r '1' ] 'b'))));
  rejects "missing dependency"
    (M.retain pool ~id:(r '2')
       (body (M.Shared_revision (shared ~dependencies:[ r '?' ] 'b'))));
  let pool = retain pool (r 'g') (body (M.Accepted_version (accepted ()))) in
  rejects "an accepted record is not a revision dependency"
    (M.retain pool ~id:(r '2')
       (body (M.Shared_revision (shared ~dependencies:[ r 'g' ] 'b'))));
  let event =
    M.make_branch_event ~branch:(b 'm') ~previous_events:[] ~action:M.Create
      ~targets:[ r 'g' ]
      ~display_name:(Some "main")
    |> ok
  in
  let pool = retain pool (r 'e') (body (M.Branch_event event)) in
  rejects "branch identity cannot be re-created by another record"
    (M.retain pool ~id:(r 'f') (body (M.Branch_event event)));
  Alcotest.(check int)
    "failed transitions preserve pool" 3
    (List.length (M.records pool))

let shape_and_sets () =
  let revision = shared ~dependencies:[ r 'z'; r 'a' ] 'c' in
  Alcotest.(check (list string))
    "sets use raw-byte order"
    [ M.Record_id.to_hex (r 'a'); M.Record_id.to_hex (r 'z') ]
    (List.map M.Record_id.to_hex revision.M.dependencies);
  rejects "duplicate references"
    (M.make_shared_revision ~change:(change 'a') ~previous_revisions:[]
       ~base_snapshot:(o 'a') ~result_snapshot:(o 'b') ~edit_scope_root:(o 'e')
       ~dependencies:[ r 'x'; r 'x' ]);
  rejects "bounded collections"
    (M.make_context ~repository:(repo 'r') ~author_certificate:(d 'c')
       ~authority_heads:(List.init (M.max_references + 1) (fun _ -> d 'x'))
       ~display_time:None);
  rejects "missing authority context"
    (M.make_context ~repository:(repo 'r') ~author_certificate:(d 'c')
       ~authority_heads:[] ~display_time:None);
  rejects "malformed branch action"
    (M.make_branch_event ~branch:(b 'm') ~previous_events:[] ~action:M.Rename
       ~targets:[] ~display_name:(Some "main"));
  rejects "overlong branch name"
    (M.make_branch_event ~branch:(b 'm') ~previous_events:[] ~action:M.Create
       ~targets:[ r 'g' ]
       ~display_name:(Some (String.make (M.max_name_bytes + 1) 'n')));
  rejects "invalid UTF-8"
    (M.make_branch_event ~branch:(b 'm') ~previous_events:[] ~action:M.Create
       ~targets:[ r 'g' ]
       ~display_name:(Some "\255"))

let resolution_context_and_reference_kinds () =
  let pool =
    M.empty_pool ~repository:(repo 'r') |> fun pool ->
    retain pool (r 'g') (body (M.Accepted_version (accepted ()))) |> fun pool ->
    retain pool (r 's') (body (M.Shared_revision (shared 'c')))
  in
  let resolution ?(branch = b 'm') ?(heads = [ r 'g' ]) ?(chosen = [ r 's' ]) ()
      =
    M.make_resolution_revision ~branch ~accepted_heads:heads
      ~chosen_revisions:chosen
      ~superseded_variants:(List.sort_uniq M.Record_id.compare (heads @ chosen))
      ~decision_scope_root:(o 'p') ~comparison_snapshot:(o 'a')
      ~replacement_snapshot:(o 'z')
  in
  rejects "resolution has no accepted context" (resolution ~heads:[] ());
  rejects "duplicate accepted variants" (resolution ~heads:[ r 'g'; r 'g' ] ());
  rejects "accepted/revision variants reuse the same record identity"
    (resolution ~chosen:[ r 'g' ] ());
  rejects "resolution accepts wrong reference kind"
    (M.retain pool ~id:(r 'r')
       (body
          (M.Resolution_revision
             (resolution ~heads:[ r 's' ] ~chosen:[] () |> ok))));
  let pool =
    retain pool (r 'r') (body (M.Resolution_revision (resolution () |> ok)))
  in
  ignore
    (M.retain pool ~id:(r 'a')
       (body
          (M.Accepted_version
             (accepted
                ~parents:[ r 'g' ]
                ~chosen:[ r 's' ]
                ~resolutions:[ r 'r' ]
                ())))
    |> ok);
  rejects "acceptance changed resolution chosen revisions"
    (M.retain pool ~id:(r 'a')
       (body
          (M.Accepted_version
             (accepted ~parents:[ r 'g' ] ~resolutions:[ r 'r' ] ()))));
  let pool =
    retain pool (r 'w')
      (body (M.Resolution_revision (resolution ~branch:(b 'x') () |> ok)))
  in
  rejects "acceptance retargeted a resolution to another branch"
    (M.retain pool ~id:(r 'a')
       (body
          (M.Accepted_version
             (accepted
                ~parents:[ r 'g' ]
                ~chosen:[ r 's' ]
                ~resolutions:[ r 'w' ]
                ()))));
  rejects "a shared revision masquerades as a resolution"
    (M.retain pool ~id:(r 'a')
       (body
          (M.Accepted_version
             (accepted
                ~parents:[ r 'g' ]
                ~chosen:[ r 's' ]
                ~resolutions:[ r 's' ]
                ()))));
  let pool =
    retain pool (r 'n')
      (body (M.Shared_revision (shared ~dependencies:[ r 's' ] 'd')))
  in
  let complete =
    M.resolution_variants pool
      ~accepted_heads:[ r 'g' ]
      ~chosen_revisions:[ r 'n' ]
    |> ok
  in
  Alcotest.(check (list string))
    "all dependency variants are explicitly named"
    (List.map M.Record_id.to_hex [ r 'g'; r 'n'; r 's' ])
    (List.map M.Record_id.to_hex complete);
  let incomplete =
    M.make_resolution_revision ~branch:(b 'm')
      ~accepted_heads:[ r 'g' ]
      ~chosen_revisions:[ r 'n' ]
      ~superseded_variants:[ r 'g'; r 'n' ]
      ~decision_scope_root:(o 'p') ~comparison_snapshot:(o 'a')
      ~replacement_snapshot:(o 'z')
    |> ok
  in
  rejects "resolution omits a dependency variant"
    (M.retain pool ~id:(r 'q') (body (M.Resolution_revision incomplete)))

let policy_and_consumers () =
  let pool =
    M.empty_pool ~repository:(repo 'r') |> fun pool ->
    retain pool (r 'g') (body (M.Accepted_version (accepted ()))) |> fun pool ->
    retain pool (r 's') (body (M.Shared_revision (shared 'a')))
  in
  let observation =
    M.make_workspace_observation ~workspace:(w 'w') ~cursor:(hid 'w' 1L)
      ~working_basis:(r 'g') ~basis_snapshot:(o 'a') ~observed_snapshot:(o 'e')
      ~correspondence:[ (r 's', hid 'w' 0L) ]
    |> ok
  in
  let request ?(policy = []) ?(selected = [ r 's' ]) () =
    M.make_composition_request ~repository:(repo 'r') ~branch:(b 'm')
      ~accepted_heads:[ r 'g' ]
      ~selected_revisions:selected ~resolution_ids:[]
      ~authority_heads:[ d 'h' ]
      ~policy_heads:policy ~review_evidence:[] ~workspace:observation
      ~composition_profile:"line-hunks-v1"
    |> ok
  in
  M.validate_request_references pool (request ()) |> ok;
  rejects "consumer cannot treat accepted ID as revision"
    (M.validate_request_references pool (request ~selected:[ r 'g' ] ()));
  rejects "unknown policy cannot make plan ready"
    (M.validate_request_references pool (request ~policy:[ d 'p' ] ()));
  rejects "policy-bearing acceptance is not silently retained"
    (M.retain pool ~id:(r 'n')
       (body
          (M.Accepted_version (accepted ~parents:[ r 'g' ] ~policy:[ d 'p' ] ()))));
  rejects "review evidence cannot fabricate approval"
    (M.retain pool ~id:(r 'n')
       (body
          (M.Accepted_version
             (accepted ~parents:[ r 'g' ] ~reviews:[ d 'v' ] ()))));
  (match M.check_review_requirement ~required:true with
  | Error M.Required_review_unsupported -> ()
  | Error
      ( M.Missing_objects _ | M.Conflicts _ | M.Invalid_authority _
      | M.Policy_unavailable _ | M.Stale_inputs | M.Ambiguous_correspondence )
  | Ok () ->
      Alcotest.fail "required review bypassed");
  Alcotest.(check bool)
    "known optional review remains permitted" true
    (M.check_review_requirement ~required:false = Ok ());
  rejects "cursor must belong to selected workspace"
    (M.make_workspace_observation ~workspace:(w 'x') ~cursor:(hid 'w' 1L)
       ~working_basis:(r 'g') ~basis_snapshot:(o 'a') ~observed_snapshot:(o 'e')
       ~correspondence:[])

let properties =
  let open QCheck2 in
  [
    Test.make ~name:"workspace identity byte/hex round trip" ~count:300
      (Gen.string_size ~gen:Gen.char (Gen.return 16))
      (fun bytes ->
        let id = M.Workspace_id.of_raw bytes |> ok in
        M.Workspace_id.equal id
          (M.Workspace_id.of_hex (M.Workspace_id.to_hex id) |> ok));
    Test.make ~name:"history namespaces never alias" ~count:300
      (Gen.pair (Gen.int_range 0 255) (Gen.int_range 0 100000))
      (fun (n, sequence) ->
        let a = hid (Char.chr n) (Int64.of_int sequence) in
        let b = hid (Char.chr ((n + 1) mod 256)) (Int64.of_int sequence) in
        not (M.History_id.equal a b));
    Test.make ~name:"allocation advances once without changing workspace"
      ~count:300
      (Gen.map
         (fun n -> Int64.rem (Int64.logand n Int64.max_int) Int64.max_int)
         Gen.int64)
      (fun sequence ->
        let id, next =
          M.History_id.allocate ~workspace:(w 'w') ~next:(Some sequence) |> ok
        in
        M.Workspace_id.equal (M.History_id.workspace id) (w 'w')
        && M.History_id.sequence id = sequence
        && next = Some (Int64.succ sequence));
  ]
  |> List.map (fun test -> QCheck_alcotest.to_alcotest test)

let () =
  Alcotest.run "Core model"
    [
      ( "identity",
        [
          Alcotest.test_case "strict IDs and entropy boundary" `Quick
            identifiers;
          Alcotest.test_case "int64 exhaustion without wrap" `Quick
            sequence_bounds;
          Alcotest.test_case "branching history/retry/collision/fork" `Quick
            branch_history;
        ] );
      ( "validation",
        [
          Alcotest.test_case "scope, references and immutable identity" `Quick
            core_pool;
          Alcotest.test_case "bounded canonical fields" `Quick shape_and_sets;
          Alcotest.test_case "consumer contracts fail closed" `Quick
            policy_and_consumers;
          Alcotest.test_case "resolution exact context and typed references"
            `Quick resolution_context_and_reference_kinds;
        ] );
      ("properties", properties);
    ]
