module Model = Yeokcham_v1_model
module Proposal = Yeokcham_v1_proposal
module Snapshot = Yeokcham_snapshot

let require_ok = Result.get_ok
let id parse value = parse value |> require_ok
let snapshot value = id Model.Snapshot_id.of_string value
let decision value = id Model.Decision_id.of_string value
let revision value = id Model.Revision_id.of_string value
let change value = id Model.Change_id.of_string value
let device value = id Model.Device_id.of_string value
let path value = id Model.Path.of_components [ value ]

let revision_record ~revision_id ~base ~result =
  Model.make_change_revision
    ~change:(change ("change-" ^ revision_id))
    ~revision:(revision revision_id) ~parent:None
    ~author:(device "device-alice") ~base:(snapshot base)
    ~result:(snapshot result)
    ~edits:[ Model.{ edit_path = path "change"; edit_kind = Whole_path } ]
  |> require_ok

let file ?(mode = Snapshot.Regular) content = Proposal.File { mode; content }
let tree entries = Proposal.tree_of_entries entries |> require_ok

let classify ?(current = "snapshot-base") ~left ~right ~base left_tree
    right_tree =
  Proposal.classify
    ~decision:(decision "decision-proposal")
    ~current_baseline:(snapshot current) ~left ~right ~base ~left_tree
    ~right_tree

let exact_proposal_selects_only_named_entries () =
  let base =
    tree
      [
        (path "left.txt", file "base-left");
        (path "right.txt", file "base-right");
      ]
  in
  let left_tree =
    tree
      [ (path "left.txt", file "left"); (path "right.txt", file "base-right") ]
  in
  let right_tree =
    tree
      [ (path "left.txt", file "base-left"); (path "right.txt", file "right") ]
  in
  let left =
    revision_record ~revision_id:"revision-left" ~base:"snapshot-base"
      ~result:"snapshot-left"
  in
  let right =
    revision_record ~revision_id:"revision-right" ~base:"snapshot-base"
      ~result:"snapshot-right"
  in
  let proposal = classify ~left ~right ~base left_tree right_tree in
  Alcotest.(check bool)
    "proposal is ready" true
    (match proposal.Proposal.readiness with
    | Proposal.Ready -> true
    | Proposal.Refused _ -> false);
  Alcotest.(check string)
    "confidence is exact source" "exact-source"
    (match proposal.Proposal.confidence with
    | Proposal.Exact_source -> "exact-source"
    | Proposal.No_confidence -> "none");
  let selected = Proposal.selected proposal |> Option.get in
  Alcotest.(check (list string))
    "each disjoint path has an exact source"
    [ "left.txt:left"; "right.txt:right" ]
    (List.map
       (fun (path, source, _) ->
         Model.Path.to_string path ^ ":" ^ Proposal.source_to_string source)
       selected)

let conflicting_entries_are_granular_and_non_authoritative () =
  let base =
    tree
      [
        (path "delete.txt", file "base");
        (path "kind", file "base");
        (path "mode.txt", file "base");
        (path "content.txt", file "base");
      ]
  in
  let left_tree =
    tree
      [
        (path "create.txt", file "left");
        (path "kind", Proposal.Directory);
        (path "mode.txt", file ~mode:Snapshot.Executable "base");
        (path "content.txt", file "left");
      ]
  in
  let right_tree =
    tree
      [
        (path "create.txt", file "right");
        (path "delete.txt", file "right");
        (path "kind", file "right");
        (path "mode.txt", file "right");
        (path "content.txt", file "right");
      ]
  in
  let left =
    revision_record ~revision_id:"revision-left" ~base:"snapshot-base"
      ~result:"snapshot-left"
  in
  let right =
    revision_record ~revision_id:"revision-right" ~base:"snapshot-base"
      ~result:"snapshot-right"
  in
  let proposal = classify ~left ~right ~base left_tree right_tree in
  Alcotest.(check bool)
    "proposal is refused" true
    (match proposal.Proposal.readiness with
    | Proposal.Ready -> false
    | Proposal.Refused _ -> true);
  Alcotest.(check string)
    "refused proposals have no confidence" "none"
    (match proposal.Proposal.confidence with
    | Proposal.Exact_source -> "exact-source"
    | Proposal.No_confidence -> "none");
  Alcotest.(check (list string))
    "each unsupported shape is named"
    [
      "content.txt:content-mismatch";
      "create.txt:competing-creation";
      "delete.txt:delete-modify";
      "kind:file-directory";
      "mode.txt:mode-and-content-mismatch";
    ]
    (proposal.Proposal.paths
    |> List.filter_map (fun path ->
        match path.Proposal.outcome with
        | Proposal.Conflict conflict ->
            Some
              (Model.Path.to_string path.Proposal.path
              ^ ":"
              ^ Proposal.conflict_to_string conflict)
        | Proposal.Select _ | Proposal.Unassessed_without_common_base -> None));
  Alcotest.(check bool)
    "no selected output is exposed" true
    (Option.is_none (Proposal.selected proposal))

let stale_and_incompatible_bases_are_refused () =
  let empty = tree [] in
  let left =
    revision_record ~revision_id:"revision-left" ~base:"snapshot-old"
      ~result:"snapshot-left"
  in
  let right =
    revision_record ~revision_id:"revision-right" ~base:"snapshot-old"
      ~result:"snapshot-right"
  in
  let stale =
    classify ~current:"snapshot-current" ~left ~right ~base:empty empty empty
  in
  Alcotest.(check string)
    "a shared old base is reported as stale"
    "candidate base snapshot-old is not the current baseline snapshot-current"
    (match stale.Proposal.readiness with
    | Proposal.Ready -> Alcotest.fail "stale proposal was ready"
    | Proposal.Refused [ refusal ] -> Proposal.refusal_to_string refusal
    | Proposal.Refused _ ->
        Alcotest.fail "stale proposal has unexpected refusals");
  let right =
    revision_record ~revision_id:"revision-right" ~base:"snapshot-other"
      ~result:"snapshot-right"
  in
  let incompatible =
    classify ~current:"snapshot-old" ~left ~right ~base:empty empty empty
  in
  Alcotest.(check bool)
    "different bases are not compared" true
    (List.for_all
       (fun path ->
         match path.Proposal.outcome with
         | Proposal.Unassessed_without_common_base -> true
         | Proposal.Select _ | Proposal.Conflict _ -> false)
       incompatible.Proposal.paths);
  Alcotest.(check string)
    "different bases have an explicit refusal"
    "candidates have different bases: snapshot-old and snapshot-other"
    (match incompatible.Proposal.readiness with
    | Proposal.Ready -> Alcotest.fail "incompatible proposal was ready"
    | Proposal.Refused (refusal :: _) -> Proposal.refusal_to_string refusal
    | Proposal.Refused [] ->
        Alcotest.fail "incompatible proposal had no refusal")

let duplicate_paths_are_rejected_at_the_pure_boundary () =
  match
    Proposal.tree_of_entries
      [ (path "same", file "one"); (path "same", file "two") ]
  with
  | Error (Proposal.Duplicate_path duplicate) ->
      Alcotest.(check string)
        "duplicate path remains inspectable" "same"
        (Model.Path.to_string duplicate)
  | Ok _ -> Alcotest.fail "proposal tree accepted duplicate paths"

let () =
  Alcotest.run "V1 exact proposal assistance"
    [
      ( "proposal",
        [
          Alcotest.test_case "selects exact disjoint entries" `Quick
            exact_proposal_selects_only_named_entries;
          Alcotest.test_case "refuses granular competing entries" `Quick
            conflicting_entries_are_granular_and_non_authoritative;
          Alcotest.test_case "refuses stale and incompatible bases" `Quick
            stale_and_incompatible_bases_are_refused;
          Alcotest.test_case "rejects duplicate pure-tree paths" `Quick
            duplicate_paths_are_rejected_at_the_pure_boundary;
        ] );
    ]
