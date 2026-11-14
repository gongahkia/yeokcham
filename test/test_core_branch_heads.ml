module M = Yeokcham_v1_model.Core
module R = Yeokcham_v1_record.Core
module T = Yeokcham_v1_trust

[@@@warning "-42"]

let ok render = function Ok v -> v | Error e -> Alcotest.fail (render e)
let model r = ok M.error_to_string r
let trust r = ok T.error_to_string r
let record r = ok R.error_to_string r
let checked r = ok T.Core.error_to_string r
let repository = M.Repository_id.of_raw (String.make 32 'r') |> model
let branch = M.Branch_id.of_raw (String.make 16 'b') |> model
let other = M.Branch_id.of_raw (String.make 16 'c') |> model
let object_ = M.Object_id.of_raw (String.make 32 's') |> model

let fixture () =
  let repository_trust =
    T.Repository_id.of_string (M.Repository_id.to_hex repository) |> ok Fun.id
  in
  let cap = T.signing_capability_of_private_key (String.make 32 'a') |> trust in
  let device = T.device_of_public_key (T.signing_public_key cap) |> trust in
  let root =
    T.root_certificate ~repository:repository_trust ~device cap |> trust
  in
  let membership =
    T.verify_membership ~repository:repository_trust [ root ] |> trust
  in
  let recovery_cap =
    T.signing_capability_of_private_key (String.make 32 'z') |> trust
  in
  let recovery_device =
    T.device_of_public_key (T.signing_public_key recovery_cap) |> trust
  in
  let epoch =
    T.root_epoch ~membership ~root_certificate:(T.certificate_id root)
      ~recovery_device cap
    |> trust
  in
  let authority = T.verify_authority ~membership [ epoch ] |> trust in
  let signed ?(time = 0L) payload =
    let context =
      M.make_context ~repository
        ~author_certificate:(M.Digest.of_hex (T.certificate_id root) |> model)
        ~authority_heads:[ M.Digest.of_hex (T.epoch_id epoch) |> model ]
        ~display_time:(Some time)
      |> model
    in
    let signed =
      T.Core.sign authority cap (M.make_body ~context ~payload) |> checked
    in
    (R.id signed |> record, R.encode signed |> record)
  in
  let receive pool (_, bytes) =
    T.Core.receive authority pool bytes |> checked |> fst
  in
  (signed, receive)

let accepted ?(branch = branch) parents =
  M.make_accepted_version ~branch ~accepted_parents:parents ~chosen_revisions:[]
    ~resolutions:[] ~result_snapshot:object_
    ~composition_profile:"line-hunks-v1" ~policy_heads:[] ~review_evidence:[]
  |> model
  |> fun v -> M.Accepted_version v

let event ?(branch = branch) ~previous ~action ~targets ~name () =
  M.make_branch_event ~branch ~previous_events:previous ~action ~targets
    ~display_name:name
  |> model
  |> fun e -> M.Branch_event e

let state pool id =
  M.branch_states pool
  |> List.find (fun state -> M.Branch_id.equal state.M.branch_id id)

let ids values = List.map M.Record_id.to_hex values

let check_ids name expected actual =
  Alcotest.(check (list string))
    name
    (List.sort String.compare (ids expected))
    (ids actual)

let rename_inherits_targets () =
  let signed, receive = fixture () in
  let version = signed (accepted []) in
  let create =
    signed
      (event ~previous:[] ~action:M.Create
         ~targets:[ fst version ]
         ~name:(Some "main") ())
  in
  let renamed =
    signed
      (event
         ~previous:[ fst create ]
         ~action:M.Rename ~targets:[] ~name:(Some "renamed") ())
  in
  let pool =
    List.fold_left receive (M.empty_pool ~repository)
      [ version; create; renamed ]
  in
  let state = state pool branch in
  check_ids "causally latest event" [ fst renamed ] state.M.event_heads;
  check_ids "rename preserves accepted contents"
    [ fst version ]
    state.M.accepted_heads;
  Alcotest.(check (list string))
    "latest causal name" [ "renamed" ] state.M.display_names

let concurrent_heads_and_names () =
  let signed, receive = fixture () in
  let base = signed (accepted []) in
  let create =
    signed
      (event ~previous:[] ~action:M.Create
         ~targets:[ fst base ]
         ~name:(Some "main") ())
  in
  let left = signed ~time:99L (accepted [ fst base ]) in
  let right = signed ~time:1L (accepted [ fst base ]) in
  let a =
    signed ~time:99L
      (event
         ~previous:[ fst create ]
         ~action:M.Advance
         ~targets:[ fst left ]
         ~name:None ())
  in
  let b =
    signed ~time:1L
      (event
         ~previous:[ fst create ]
         ~action:M.Advance
         ~targets:[ fst right ]
         ~name:None ())
  in
  let rename =
    signed
      (event
         ~previous:[ fst create ]
         ~action:M.Rename ~targets:[] ~name:(Some "parallel-name") ())
  in
  let initial =
    List.fold_left receive (M.empty_pool ~repository)
      [ base; create; left; right ]
  in
  let first = List.fold_left receive initial [ a; b; rename ] in
  let expected = state first branch in
  List.iter
    (fun order ->
      let other_order = List.fold_left receive initial order in
      Alcotest.(check bool)
        "receipt order never chooses a head" true
        (M.branch_states first = M.branch_states other_order))
    [
      [ a; b; rename ];
      [ a; rename; b ];
      [ b; a; rename ];
      [ b; rename; a ];
      [ rename; a; b ];
      [ rename; b; a ];
    ];
  check_ids "all causal event alternatives"
    [ fst a; fst b; fst rename ]
    expected.M.event_heads;
  check_ids "accepted ancestors reduced, alternatives retained"
    [ fst left; fst right ]
    expected.M.accepted_heads;
  Alcotest.(check (list string))
    "concurrent names retained"
    [ "main"; "parallel-name" ]
    expected.M.display_names;
  let joined = signed (accepted [ fst left; fst right ]) in
  let reconcile =
    signed
      (event
         ~previous:[ fst a; fst b; fst rename ]
         ~action:M.Reconcile
         ~targets:[ fst joined ]
         ~name:None ())
  in
  let final =
    List.fold_left receive first [ joined; reconcile ] |> fun pool ->
    state pool branch
  in
  check_ids "explicit reconciliation replaces event alternatives"
    [ fst reconcile ]
    final.M.event_heads;
  check_ids "explicit reconciliation replaces accepted alternatives"
    [ fst joined ]
    final.M.accepted_heads;
  Alcotest.(check (list string))
    "target reconciliation does not invent a name winner"
    [ "main"; "parallel-name" ]
    final.M.display_names

let branch_isolation_and_equivalent_contents () =
  let signed, receive = fixture () in
  let base = signed (accepted []) in
  let first =
    signed
      (event ~previous:[] ~action:M.Create
         ~targets:[ fst base ]
         ~name:(Some "one") ())
  in
  let fork = signed (accepted ~branch:other [ fst base ]) in
  let second =
    signed
      (event ~branch:other ~previous:[] ~action:M.Create
         ~targets:[ fst fork ]
         ~name:(Some "two") ())
  in
  let pool =
    List.fold_left receive (M.empty_pool ~repository)
      [ base; first; fork; second ]
  in
  let one = state pool branch and two = state pool other in
  check_ids "original branch stable" [ fst base ] one.M.accepted_heads;
  check_ids "new identity selects fork record" [ fst fork ] two.M.accepted_heads;
  Alcotest.(check bool)
    "equal snapshot is not accepted-version identity" false
    (M.Record_id.equal (fst base) (fst fork));
  Alcotest.(check int)
    "two shared branches, independent of local history" 2
    (List.length (M.branch_states pool))

let () =
  Alcotest.run "Core branch heads"
    [
      ( "causality",
        [
          Alcotest.test_case "rename inherits accepted heads" `Quick
            rename_inherits_targets;
          Alcotest.test_case
            "concurrent heads, receipt order and explicit reconciliation" `Quick
            concurrent_heads_and_names;
          Alcotest.test_case "branch identity differs from contents" `Quick
            branch_isolation_and_equivalent_contents;
        ] );
    ]
